// Emitter (出生位置 / 出生レート / 出生量 / 形状)
// Why: Wallpaper Engine 互換の particle system は emitter / initializer / operator の 3 段で記述するため、
//      最初の段である「出生」を独立モジュールに切り出す。

use serde::{Deserialize, Serialize};

/// JSON でシリアライズされる Emitter 定義。Swift 側 `EmitterDescriptor` と一致させる。
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct EmitterDescriptor {
    /// 出生原点 (canvas pixel)
    #[serde(default)]
    pub origin: [f32; 2],
    /// 1 秒あたりの出生数 (continuous emission)
    #[serde(default)]
    pub spawn_rate: f32,
    /// 生成直後に一括で出す数 (single-shot burst)
    #[serde(default)]
    pub burst: u32,
    /// 出生形状。Point / Box / Circle のいずれか。
    #[serde(default)]
    pub shape: EmitterShape,
}

/// Emitter の出生位置サンプリング形状。
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum EmitterShape {
    /// origin 1 点に固定。
    #[default]
    Point,
    /// origin を中心とする軸並行 Box。`width` / `height` は半径ではなく辺の長さ。
    Box { width: f32, height: f32 },
    /// origin を中心とする円盤。
    Circle { radius: f32 },
}

/// ランタイムの Emitter 状態。`spawn_accumulator` を継続加算してフレーム間レートを実現する。
pub struct Emitter {
    pub origin: [f32; 2],
    pub spawn_rate: f32,
    pub burst: u32,
    pub shape: EmitterShape,
    /// continuous emission 用の小数残り。Why: spawn_rate=10/s, dt=0.016 のとき 0.16 個出すのは無理なので加算する。
    pub spawn_accumulator: f32,
    /// burst が未消費なら残数を保持。`spawn_burst_pending()` を 1 度呼ぶと 0 になる。
    pub burst_pending: u32,
}

impl Emitter {
    pub fn from_descriptor(d: EmitterDescriptor) -> Self {
        Self {
            origin: d.origin,
            spawn_rate: d.spawn_rate,
            burst: d.burst,
            shape: d.shape,
            spawn_accumulator: 0.0,
            burst_pending: d.burst,
        }
    }

    /// `dt` 秒ぶんの出生数を計算する。burst 残があれば最初の呼び出しで合算する。
    /// Why: spawn_rate を float 累積する方式は最少コードでフレームレート非依存の挙動を実現する。
    pub fn pop_spawn_count(&mut self, dt: f32) -> u32 {
        self.spawn_accumulator += self.spawn_rate * dt;
        let mut n = self.spawn_accumulator.floor() as i32;
        if n < 0 {
            n = 0;
        }
        self.spawn_accumulator -= n as f32;
        let burst_now = self.burst_pending;
        self.burst_pending = 0;
        burst_now.saturating_add(n as u32)
    }

    /// 出生位置を 1 つ返す。
    /// Why: shape ごとに rng を駆動して原点周辺に分散させる。決定論性のため u64 xorshift を使う。
    pub fn sample_position(&self, rng: &mut u64) -> [f32; 2] {
        match self.shape {
            EmitterShape::Point => self.origin,
            EmitterShape::Box { width, height } => {
                let x = self.origin[0] + (super::rng::next_f32_unit(rng) - 0.5) * width;
                let y = self.origin[1] + (super::rng::next_f32_unit(rng) - 0.5) * height;
                [x, y]
            }
            EmitterShape::Circle { radius } => {
                // 円盤への一様サンプリング: r = radius * sqrt(u) で密度を均一にする
                let theta = super::rng::next_f32_unit(rng) * std::f32::consts::TAU;
                let r = radius * super::rng::next_f32_unit(rng).sqrt();
                [self.origin[0] + r * theta.cos(), self.origin[1] + r * theta.sin()]
            }
        }
    }
}
