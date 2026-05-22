// Operator (毎フレーム更新: 重力 / 摩擦 / サイズ推移 / 色推移 / 範囲外 kill)
// Why: 1 つの Particle に対して `apply(dt)` を順に呼ぶことで複数オペレータを合成できる純粋関数列挙。
//      `apply` の戻り値 `bool` は particle が生存し続けるかどうかを示す。

use serde::{Deserialize, Serialize};

use super::particle::Particle;

/// JSON でシリアライズされる Operator 定義。Swift 側 `OperatorDescriptor` と一致させる。
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum OperatorDescriptor {
    /// 加速度ベクトル (pixel/sec^2) を毎フレーム速度に加算する。雪/雨用途は重力 = (0, -G)。
    Gravity { acceleration: [f32; 2] },
    /// 抵抗。`v *= 1 - coefficient * dt` で減速する。0.0 で抵抗なし、1.0 で 1 秒で停止。
    Drag { coefficient: f32 },
    /// 寿命進捗 t に対し `size = lerp(start, end, t)` を適用する。
    SizeOverLife { start: f32, end: f32 },
    /// 寿命進捗 t に対し `color = lerp(start, end, t)` を適用する (RGBA 各成分独立)。
    ColorOverLife { start: [f32; 4], end: [f32; 4] },
    /// `min`-`max` の bounding box を超えた particle を kill する。canvas 範囲制限に使う。
    KillBeyondBounds { min: [f32; 2], max: [f32; 2] },
}

/// ランタイム上はそのまま enum を持つ (関数ポインタ等不要、軽量)。
pub type Operator = OperatorDescriptor;

impl OperatorDescriptor {
    /// 1 つの Particle に対し作用する。`age` 更新と `position` 更新は呼び出し側で行う前提。
    /// - Returns: 続けて生存させる場合 true / kill 判定が立った場合 false。
    pub fn apply(&self, particle: &mut Particle, dt: f32) -> bool {
        match self {
            Self::Gravity { acceleration } => {
                particle.velocity[0] += acceleration[0] * dt;
                particle.velocity[1] += acceleration[1] * dt;
                true
            }
            Self::Drag { coefficient } => {
                let factor = (1.0 - coefficient * dt).max(0.0);
                particle.velocity[0] *= factor;
                particle.velocity[1] *= factor;
                true
            }
            Self::SizeOverLife { start, end } => {
                let t = particle.life_progress();
                particle.size = start * (1.0 - t) + end * t;
                true
            }
            Self::ColorOverLife { start, end } => {
                let t = particle.life_progress();
                for i in 0..4 {
                    particle.color[i] = start[i] * (1.0 - t) + end[i] * t;
                }
                true
            }
            Self::KillBeyondBounds { min, max } => {
                let p = particle.position;
                if p[0] < min[0] || p[0] > max[0] || p[1] < min[1] || p[1] > max[1] {
                    return false;
                }
                true
            }
        }
    }
}
