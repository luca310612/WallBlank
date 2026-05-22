// アニメーションプリセット
// 時間ベースのプロシージャルアニメーションをレイヤーに適用する

use serde::Deserialize;

/// アニメーション設定
/// Swift側JSON: {"preset":1,"speed":1.0,"amplitude":1.0,"phase_offset":0.0,"loop_duration":4.0}
#[derive(Debug, Clone, Deserialize)]
pub struct AnimationConfig {
    pub preset: AnimationPreset,
    #[serde(default = "default_speed")]
    pub speed: f32,
    #[serde(default = "default_amplitude")]
    pub amplitude: f32,
    #[serde(default)]
    pub phase_offset: f32,
    #[serde(default = "default_loop_duration")]
    pub loop_duration: f32,
}

fn default_speed() -> f32 { 1.0 }
fn default_amplitude() -> f32 { 1.0 }
fn default_loop_duration() -> f32 { 4.0 }

/// アニメーションプリセット種別
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[repr(u32)]
pub enum AnimationPreset {
    None = 0,
    /// 深度に応じた位置パララックス
    Parallax = 1,
    /// スケールのsin波振動（呼吸のような動き）
    Breathing = 2,
    /// 回転のsin波揺れ
    Sway = 3,
    /// ゆっくり上下に漂う動き
    Float = 4,
    /// 不透明度のパルス
    Pulse = 5,
    /// 円軌道の位置移動
    Orbit = 6,
    /// 弾むような垂直移動
    Bounce = 7,
}

/// アニメーション評価結果（ベーストランスフォームへの加算/乗算デルタ）
#[derive(Debug, Clone, Copy)]
pub struct TransformDelta {
    /// 位置オフセット（ピクセル単位、加算）
    pub position: [f32; 2],
    /// スケール乗数（乗算）
    pub scale: [f32; 2],
    /// 回転オフセット（ラジアン、加算）
    pub rotation: f32,
    /// 不透明度乗数（乗算）
    pub opacity: f32,
}

impl Default for TransformDelta {
    fn default() -> Self {
        Self {
            position: [0.0, 0.0],
            scale: [1.0, 1.0],
            rotation: 0.0,
            opacity: 1.0,
        }
    }
}

impl AnimationConfig {
    /// 経過時間からアニメーションデルタを評価する
    pub fn evaluate(&self, elapsed_time: f32) -> TransformDelta {
        if self.preset == AnimationPreset::None {
            return TransformDelta::default();
        }

        let t = elapsed_time * self.speed + self.phase_offset;
        let amp = self.amplitude;

        match self.preset {
            AnimationPreset::None => TransformDelta::default(),

            AnimationPreset::Parallax => {
                // depth値に比例した水平位置のsin波オフセット
                let offset_x = (t * 0.5).sin() * amp * 20.0;
                let offset_y = (t * 0.3).cos() * amp * 10.0;
                TransformDelta {
                    position: [offset_x, offset_y],
                    ..Default::default()
                }
            }

            AnimationPreset::Breathing => {
                // ゆっくりとしたスケール拡縮（呼吸のリズム）
                let s = 1.0 + (t * std::f32::consts::TAU / self.loop_duration).sin() * amp * 0.05;
                TransformDelta {
                    scale: [s, s],
                    ..Default::default()
                }
            }

            AnimationPreset::Sway => {
                // 左右にゆっくり揺れる回転
                let r = (t * std::f32::consts::TAU / self.loop_duration).sin() * amp * 0.05;
                TransformDelta {
                    rotation: r,
                    ..Default::default()
                }
            }

            AnimationPreset::Float => {
                // 上下にゆっくり漂う
                let y = (t * std::f32::consts::TAU / self.loop_duration).sin() * amp * 15.0;
                // 水平方向にもわずかな揺れ
                let x = (t * 0.7).sin() * amp * 5.0;
                TransformDelta {
                    position: [x, y],
                    ..Default::default()
                }
            }

            AnimationPreset::Pulse => {
                // 不透明度のパルス（完全には消えない）
                let o = 0.7 + 0.3 * (t * std::f32::consts::TAU / self.loop_duration).sin() * amp;
                TransformDelta {
                    opacity: o.clamp(0.1, 1.0),
                    ..Default::default()
                }
            }

            AnimationPreset::Orbit => {
                // 円軌道で位置移動
                let angle = t * std::f32::consts::TAU / self.loop_duration;
                let radius = amp * 30.0;
                TransformDelta {
                    position: [angle.cos() * radius, angle.sin() * radius],
                    ..Default::default()
                }
            }

            AnimationPreset::Bounce => {
                // 弾むような垂直移動（abs(sin)でバウンス感）
                let phase = t * std::f32::consts::TAU / self.loop_duration;
                let y = -(phase.sin().abs()) * amp * 30.0;
                TransformDelta {
                    position: [0.0, y],
                    ..Default::default()
                }
            }
        }
    }
}
