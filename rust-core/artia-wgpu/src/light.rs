// Phase 4B: Light レイヤー (2D 法線マップベースの簡易ライティング)
// Why: Wallpaper Engine の Light 互換として、レイヤー上に「光源」を 2D 配置できるようにする。
//      Phase 4B では descriptor 保管 + WGSL 同梱 + テストまでを範囲とし、
//      実際の draw pass 統合は後続フェーズで行う (Phase 4A の particle と同じ段階的アプローチ)。

use serde::{Deserialize, Serialize};

mod shader {
    pub const LIGHT_WGSL: &str = include_str!("shaders/light/light.wgsl");
}

pub use shader::LIGHT_WGSL;

/// LightLayer の識別子。FFI で u32 ハンドルとして公開する。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct LightLayerId(pub u32);

/// Swift 側 `LightLayerDescriptor` と JSON 互換の構造体。
/// Why: 任意の点光源 (Lambert + 簡易 Phong) を 1 つの構造体で表現する。
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct LightLayerDescriptor {
    /// 光源位置 (canvas pixel)
    #[serde(default)]
    pub position: [f32; 2],
    /// 光源色 (linear sRGB; アルファは強度ではなく合成用)
    #[serde(default = "default_color")]
    pub color: [f32; 4],
    /// 強度倍率 (1.0 = base color と同等の振幅)
    #[serde(default = "default_intensity")]
    pub intensity: f32,
    /// 距離減衰 (px) — この距離で光が約 1/e に落ちる
    #[serde(default = "default_falloff")]
    pub falloff: f32,
}

impl Default for LightLayerDescriptor {
    fn default() -> Self {
        Self {
            position: [0.0, 0.0],
            color: default_color(),
            intensity: default_intensity(),
            falloff: default_falloff(),
        }
    }
}

fn default_color() -> [f32; 4] {
    [1.0, 1.0, 1.0, 1.0]
}
fn default_intensity() -> f32 {
    1.0
}
fn default_falloff() -> f32 {
    256.0
}

/// `update_light_layer` 用の差分パラメータ。
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct LightLayerParams {
    #[serde(default)]
    pub position: Option<[f32; 2]>,
    #[serde(default)]
    pub color: Option<[f32; 4]>,
    #[serde(default)]
    pub intensity: Option<f32>,
    #[serde(default)]
    pub falloff: Option<f32>,
}

/// ランタイム側の Light レイヤー。
#[derive(Clone, Debug, PartialEq)]
pub struct LightLayer {
    pub id: LightLayerId,
    pub descriptor: LightLayerDescriptor,
}

impl LightLayer {
    pub fn new(id: LightLayerId, descriptor: LightLayerDescriptor) -> Self {
        Self { id, descriptor }
    }

    /// 部分更新を反映する。
    pub fn apply_params(&mut self, params: LightLayerParams) {
        if let Some(p) = params.position {
            self.descriptor.position = p;
        }
        if let Some(c) = params.color {
            self.descriptor.color = c;
        }
        if let Some(i) = params.intensity {
            self.descriptor.intensity = i;
        }
        if let Some(f) = params.falloff {
            self.descriptor.falloff = f;
        }
    }

    /// 指定の表面位置 (canvas pixel) における Lambert 強度を計算する (CPU 検証用)。
    /// Why: WGSL fragment と同じ係数で計算可能なので、テストで挙動をロックする。
    pub fn evaluate_intensity(&self, surface_position: [f32; 2]) -> f32 {
        let dx = surface_position[0] - self.descriptor.position[0];
        let dy = surface_position[1] - self.descriptor.position[1];
        let dist = (dx * dx + dy * dy).sqrt();
        let falloff = self.descriptor.falloff.max(1.0);
        let attenuation = (-dist / falloff).exp();
        (self.descriptor.intensity * attenuation).max(0.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn descriptor_round_trips_via_json() {
        let d = LightLayerDescriptor {
            position: [10.0, 20.0],
            color: [0.5, 0.6, 0.7, 1.0],
            intensity: 1.25,
            falloff: 128.0,
        };
        let json = serde_json::to_string(&d).unwrap();
        let back: LightLayerDescriptor = serde_json::from_str(&json).unwrap();
        assert_eq!(d, back);
    }

    #[test]
    fn apply_params_partial_update_only_changes_specified_fields() {
        let mut light = LightLayer::new(LightLayerId(1), LightLayerDescriptor::default());
        light.apply_params(LightLayerParams {
            intensity: Some(2.0),
            ..Default::default()
        });
        assert!((light.descriptor.intensity - 2.0).abs() < 1e-4);
        // 他フィールドは既定値のまま
        assert_eq!(light.descriptor.position, [0.0, 0.0]);
        assert_eq!(light.descriptor.color, [1.0, 1.0, 1.0, 1.0]);
        assert!((light.descriptor.falloff - 256.0).abs() < 1e-4);
    }

    #[test]
    fn intensity_is_max_at_source_position() {
        let light = LightLayer::new(
            LightLayerId(1),
            LightLayerDescriptor {
                position: [100.0, 100.0],
                intensity: 1.0,
                falloff: 50.0,
                ..Default::default()
            },
        );
        let at_source = light.evaluate_intensity([100.0, 100.0]);
        let far_away = light.evaluate_intensity([300.0, 100.0]);
        // 距離 0 → 強度 1.0 / 距離大きい → 急速に減衰
        assert!((at_source - 1.0).abs() < 1e-4);
        assert!(far_away < 0.05);
    }

    #[test]
    fn falloff_zero_clamps_safely() {
        let light = LightLayer::new(
            LightLayerId(1),
            LightLayerDescriptor {
                position: [0.0, 0.0],
                intensity: 1.0,
                falloff: 0.0, // ゼロ除算回避を確認
                ..Default::default()
            },
        );
        let v = light.evaluate_intensity([10.0, 0.0]);
        assert!(v.is_finite());
    }

    #[test]
    fn shader_constant_is_loaded() {
        // include_str! 経由で WGSL ソースが空でないことを保証する。
        assert!(LIGHT_WGSL.contains("@fragment"));
    }
}
