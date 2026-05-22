// Phase 4C: Bone (階層スケルトンの 1 ノード)
// Why: parent_id で木構造を作り、ローカルの translation / rotation / scale から
//      local affine matrix を生成する。FK は pose.rs 側で実施。

use serde::{Deserialize, Serialize};

/// 4x4 行列 (列優先格納; 既存 `types::mul_mat4` と一貫)。
pub type Mat4 = [[f32; 4]; 4];

/// Swift `BoneDescriptor` と JSON 互換のボーン定義。
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct BoneDescriptor {
    pub name: String,
    /// -1 = ルート、それ以外は親ボーンの index。
    #[serde(default = "default_parent")]
    pub parent_id: i32,
    /// 親基準のローカル並行移動 (x, y, z)。z は通常 0。
    #[serde(default)]
    pub local_translation: [f32; 3],
    /// 親基準のローカル z 軸回転 (radians)。
    #[serde(default)]
    pub local_rotation: f32,
    /// 親基準のローカルスケール (x, y, z)。z は通常 1。
    #[serde(default = "default_scale")]
    pub local_scale: [f32; 3],
    /// ボーン長 (描画 / IK 用ヒント)。スキニング自体には影響しない。
    #[serde(default = "default_length")]
    pub length: f32,
}

fn default_parent() -> i32 { -1 }
fn default_scale() -> [f32; 3] { [1.0, 1.0, 1.0] }
fn default_length() -> f32 { 1.0 }

impl BoneDescriptor {
    /// このボーンのローカル変換行列を構築する。
    /// 順序: translation * rotation_z * scale
    pub fn local_matrix(&self) -> Mat4 {
        let cos_r = self.local_rotation.cos();
        let sin_r = self.local_rotation.sin();
        let sx = self.local_scale[0];
        let sy = self.local_scale[1];
        let sz = self.local_scale[2];
        let tx = self.local_translation[0];
        let ty = self.local_translation[1];
        let tz = self.local_translation[2];
        // 列優先: 各列が基底ベクトル
        [
            [cos_r * sx, sin_r * sx, 0.0, 0.0],
            [-sin_r * sy, cos_r * sy, 0.0, 0.0],
            [0.0, 0.0, sz, 0.0],
            [tx, ty, tz, 1.0],
        ]
    }
}

/// 単位行列を返す。
pub fn mat4_identity() -> Mat4 {
    [
        [1.0, 0.0, 0.0, 0.0],
        [0.0, 1.0, 0.0, 0.0],
        [0.0, 0.0, 1.0, 0.0],
        [0.0, 0.0, 0.0, 1.0],
    ]
}

/// 2D 点 (z=0, w=1) を Mat4 で変換する。
pub fn transform_point2d(m: Mat4, p: [f32; 2]) -> [f32; 2] {
    let x = p[0];
    let y = p[1];
    let nx = m[0][0] * x + m[1][0] * y + m[3][0];
    let ny = m[0][1] * x + m[1][1] * y + m[3][1];
    [nx, ny]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_descriptor_yields_identity_matrix() {
        let bone = BoneDescriptor {
            name: "root".into(),
            parent_id: -1,
            local_translation: [0.0, 0.0, 0.0],
            local_rotation: 0.0,
            local_scale: [1.0, 1.0, 1.0],
            length: 1.0,
        };
        let m = bone.local_matrix();
        assert_eq!(m, mat4_identity());
    }

    #[test]
    fn translation_only_transforms_origin() {
        let bone = BoneDescriptor {
            name: "t".into(),
            parent_id: -1,
            local_translation: [10.0, 20.0, 0.0],
            local_rotation: 0.0,
            local_scale: [1.0, 1.0, 1.0],
            length: 1.0,
        };
        let m = bone.local_matrix();
        let p = transform_point2d(m, [0.0, 0.0]);
        assert!((p[0] - 10.0).abs() < 1e-4);
        assert!((p[1] - 20.0).abs() < 1e-4);
    }

    #[test]
    fn rotation_90_deg_rotates_unit_x_to_unit_y() {
        let bone = BoneDescriptor {
            name: "r".into(),
            parent_id: -1,
            local_translation: [0.0, 0.0, 0.0],
            local_rotation: std::f32::consts::FRAC_PI_2,
            local_scale: [1.0, 1.0, 1.0],
            length: 1.0,
        };
        let m = bone.local_matrix();
        let p = transform_point2d(m, [1.0, 0.0]);
        assert!(p[0].abs() < 1e-4);
        assert!((p[1] - 1.0).abs() < 1e-4);
    }
}
