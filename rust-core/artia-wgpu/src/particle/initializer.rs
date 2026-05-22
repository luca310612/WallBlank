// Initializer (出生時パラメータ: 寿命 / 初速 / サイズ / 色 / 向き)
// Why: 各 Initializer は spawn 直後の 1 つの Particle に作用する純粋関数。
//      列挙体で表現することで JSON / FFI 経由で個数可変に渡せる。

use serde::{Deserialize, Serialize};

use super::particle::Particle;
use super::rng::{next_f32_range, next_f32_unit};

/// JSON でシリアライズされる Initializer 定義。Swift 側 `InitializerDescriptor` と一致させる。
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum InitializerDescriptor {
    /// 寿命を [min, max] で乱数決定する。
    LifetimeRange { min: f32, max: f32 },
    /// 指定方向ベクトル ± angle (rad) の円錐内に向けて [speed_min, speed_max] の速度を与える。
    VelocityCone {
        direction: [f32; 2],
        angle: f32,
        speed_min: f32,
        speed_max: f32,
    },
    /// 初期サイズを [min, max] で乱数決定する。
    SizeRange { min: f32, max: f32 },
    /// 単色 RGBA。Phase 4A は固定色のみ。グラデーションは ColorOverLife で実現する。
    ColorRamp { color: [f32; 4] },
    /// 完全ランダム方向に [speed_min, speed_max] の速度を与える。
    RandomDirection { speed_min: f32, speed_max: f32 },
}

/// ランタイム上は Descriptor をそのまま使う (パラメータ計算が軽量で型変換不要)。
pub type Initializer = InitializerDescriptor;

impl InitializerDescriptor {
    /// `particle` を spawn 直後の状態として初期化する。
    /// Why: 複数の Initializer を合成適用するので、各 enum variant は他の項目には触らない。
    pub fn apply(&self, particle: &mut Particle, rng: &mut u64) {
        match self {
            Self::LifetimeRange { min, max } => {
                let life = next_f32_range(rng, *min, *max).max(0.0001);
                particle.lifetime = life;
                particle.age = 0.0;
            }
            Self::VelocityCone {
                direction,
                angle,
                speed_min,
                speed_max,
            } => {
                let base_angle = direction[1].atan2(direction[0]);
                let half_cone = *angle * 0.5;
                let theta = base_angle + (next_f32_unit(rng) - 0.5) * 2.0 * half_cone;
                let speed = next_f32_range(rng, *speed_min, *speed_max);
                particle.velocity = [theta.cos() * speed, theta.sin() * speed];
            }
            Self::SizeRange { min, max } => {
                particle.size = next_f32_range(rng, *min, *max).max(0.0);
            }
            Self::ColorRamp { color } => {
                particle.color = *color;
            }
            Self::RandomDirection { speed_min, speed_max } => {
                let theta = next_f32_unit(rng) * std::f32::consts::TAU;
                let speed = next_f32_range(rng, *speed_min, *speed_max);
                particle.velocity = [theta.cos() * speed, theta.sin() * speed];
            }
        }
    }
}
