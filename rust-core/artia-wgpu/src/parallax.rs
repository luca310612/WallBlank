// Phase 4B: パララックス (マウス連動レイヤーオフセット)
// Why: Wallpaper Engine 互換のレイヤー深度演出として、マウス位置に応じて
//      各レイヤーの位置を「奥行き × 強度」で微小オフセットする。
//      実装は CPU 側で `parallax_offset` を計算してレイヤーに書き戻すだけで、
//      実際の頂点変換は既存 `uniforms_with_viewport` の position に積まれる。
//      ジャイロ (CMMotionManager) は macOS 非対応 — iPad 移植時に追加予定。

use serde::{Deserialize, Serialize};

/// レイヤーごとのパララックス設定。Swift 側 `ParallaxLayerSetting` と JSON 互換。
///
/// - `depth`: 0.0 = 最背面, 1.0 = 最前面, 0.5 = ニュートラル (オフセット 0)。
/// - `strength`: マウスオフセットを画素にスケーリングする係数 (px)。
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct ParallaxLayerSetting {
    #[serde(default = "default_depth")]
    pub depth: f32,
    #[serde(default)]
    pub strength: f32,
}

fn default_depth() -> f32 {
    0.5
}

impl ParallaxLayerSetting {
    /// `(mouse_x, mouse_y)` (画面中央=0,0 / 範囲 ±1 推奨) からピクセルオフセットを計算する。
    /// Why: depth=0.5 を中点とし、奥のレイヤー (depth<0.5) は逆方向に動く視差を作る。
    pub fn compute_offset(&self, mouse: [f32; 2]) -> [f32; 2] {
        let bias = self.depth - 0.5;
        [mouse[0] * bias * self.strength, mouse[1] * bias * self.strength]
    }
}

/// 正規化されたマウスオフセット (-1.0 .. 1.0)。0.0 = 中央。
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct NormalizedMouseOffset {
    pub x: f32,
    pub y: f32,
}

impl NormalizedMouseOffset {
    pub fn new(x: f32, y: f32) -> Self {
        Self {
            x: x.clamp(-1.0, 1.0),
            y: y.clamp(-1.0, 1.0),
        }
    }

    pub fn as_array(&self) -> [f32; 2] {
        [self.x, self.y]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn neutral_depth_yields_no_offset() {
        let s = ParallaxLayerSetting { depth: 0.5, strength: 100.0 };
        let off = s.compute_offset([1.0, -1.0]);
        // depth = 0.5 → bias 0 → 完全に静止する
        assert_eq!(off, [0.0, 0.0]);
    }

    #[test]
    fn foreground_layer_moves_with_mouse() {
        let s = ParallaxLayerSetting { depth: 1.0, strength: 50.0 };
        let off = s.compute_offset([1.0, 0.0]);
        // bias = +0.5 → x オフセット = 1 * 0.5 * 50 = 25
        assert!((off[0] - 25.0).abs() < 1e-4);
        assert!((off[1] - 0.0).abs() < 1e-4);
    }

    #[test]
    fn background_layer_moves_against_mouse() {
        let s = ParallaxLayerSetting { depth: 0.0, strength: 50.0 };
        let off = s.compute_offset([1.0, 0.0]);
        // bias = -0.5 → x オフセット = 1 * -0.5 * 50 = -25 (奥は逆方向)
        assert!((off[0] + 25.0).abs() < 1e-4);
    }

    #[test]
    fn zero_strength_disables_parallax() {
        let s = ParallaxLayerSetting { depth: 1.0, strength: 0.0 };
        let off = s.compute_offset([1.0, 1.0]);
        assert_eq!(off, [0.0, 0.0]);
    }

    #[test]
    fn descriptor_round_trips_via_json() {
        let s = ParallaxLayerSetting { depth: 0.7, strength: 12.5 };
        let json = serde_json::to_string(&s).unwrap();
        let back: ParallaxLayerSetting = serde_json::from_str(&json).unwrap();
        assert_eq!(s, back);
    }

    #[test]
    fn normalized_mouse_clamps_to_unit_range() {
        let n = NormalizedMouseOffset::new(2.5, -3.0);
        assert_eq!(n.as_array(), [1.0, -1.0]);
    }
}
