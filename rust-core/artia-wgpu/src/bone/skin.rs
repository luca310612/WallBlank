// Phase 4C: Linear Blend Skinning (4 bone weights)
// Why: 各頂点が最大 4 ボーンに重み付けされる標準的な LBS。Dual Quaternion Skinning は
//      将来対応 (3D 化や IK 導入時に検討)。

use crate::types::mul_mat4;

use serde::{Deserialize, Serialize};

use super::bone::{transform_point2d, Mat4};

/// 1 頂点あたりのボーン重み (4 影響まで)。
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq)]
pub struct VertexWeights {
    /// 影響するボーン index (-1 = 未使用)。
    #[serde(default = "default_indices")]
    pub bone_indices: [i32; 4],
    /// それぞれの重み。合計 1.0 にすることを期待 (実装側で正規化)。
    #[serde(default)]
    pub weights: [f32; 4],
}

fn default_indices() -> [i32; 4] { [-1, -1, -1, -1] }

impl Default for VertexWeights {
    fn default() -> Self {
        Self {
            bone_indices: default_indices(),
            weights: [0.0; 4],
        }
    }
}

impl VertexWeights {
    pub fn single(bone_index: i32) -> Self {
        Self {
            bone_indices: [bone_index, -1, -1, -1],
            weights: [1.0, 0.0, 0.0, 0.0],
        }
    }
}

/// 単一頂点を LBS でスキニングする。
///
/// - `rest_position`: bind pose 時のレイヤー画像座標 (px)
/// - `world_matrices` / `inverse_bind_matrices`: `Pose` から取得
///
/// 重み合計が 0 の場合は rest_position をそのまま返す (無重み = 静止)。
pub fn skin_lbs(
    rest_position: [f32; 2],
    weights: &VertexWeights,
    world_matrices: &[Mat4],
    inverse_bind_matrices: &[Mat4],
) -> [f32; 2] {
    let mut acc = [0.0_f32, 0.0_f32];
    let mut total_w = 0.0_f32;
    for k in 0..4 {
        let bi = weights.bone_indices[k];
        let w = weights.weights[k];
        if bi < 0 || w <= 0.0 {
            continue;
        }
        let i = bi as usize;
        if i >= world_matrices.len() || i >= inverse_bind_matrices.len() {
            continue;
        }
        let skinning = mul_mat4(world_matrices[i], inverse_bind_matrices[i]);
        let p = transform_point2d(skinning, rest_position);
        acc[0] += w * p[0];
        acc[1] += w * p[1];
        total_w += w;
    }
    if total_w <= 0.0 {
        return rest_position;
    }
    [acc[0] / total_w, acc[1] / total_w]
}

#[cfg(test)]
mod tests {
    use super::super::bone::BoneDescriptor;
    use super::super::pose::Pose;
    use super::*;

    fn make_bone(name: &str, parent: i32, tx: f32, ty: f32) -> BoneDescriptor {
        BoneDescriptor {
            name: name.into(),
            parent_id: parent,
            local_translation: [tx, ty, 0.0],
            local_rotation: 0.0,
            local_scale: [1.0, 1.0, 1.0],
            length: 1.0,
        }
    }

    #[test]
    fn bind_pose_skinning_returns_rest_position() {
        // bind pose のままなら world * inverse_bind == identity → rest がそのまま
        let bones = vec![
            make_bone("root", -1, 10.0, 0.0),
            make_bone("child", 0, 5.0, 0.0),
        ];
        let pose = Pose::from_descriptors(&bones);
        let weights = VertexWeights {
            bone_indices: [0, 1, -1, -1],
            weights: [0.6, 0.4, 0.0, 0.0],
        };
        let rest = [50.0, 25.0];
        let skinned = skin_lbs(rest, &weights, &pose.world_matrices, &pose.inverse_bind_matrices);
        assert!((skinned[0] - rest[0]).abs() < 1e-3);
        assert!((skinned[1] - rest[1]).abs() < 1e-3);
    }

    #[test]
    fn moving_bone_translates_attached_vertex() {
        let bones = vec![make_bone("root", -1, 0.0, 0.0)];
        let mut pose = Pose::from_descriptors(&bones);
        // ボーンを (10, 0) に移動
        let new_local: Mat4 = [
            [1.0, 0.0, 0.0, 0.0],
            [0.0, 1.0, 0.0, 0.0],
            [0.0, 0.0, 1.0, 0.0],
            [10.0, 0.0, 0.0, 1.0],
        ];
        pose.set_local_matrix(0, new_local);

        let weights = VertexWeights::single(0);
        let rest = [5.0, 0.0];
        let skinned = skin_lbs(rest, &weights, &pose.world_matrices, &pose.inverse_bind_matrices);
        assert!((skinned[0] - 15.0).abs() < 1e-3);
        assert!(skinned[1].abs() < 1e-3);
    }

    #[test]
    fn four_bone_weights_blend_correctly() {
        // 4 ボーンが等間隔に並び、各ボーンに対して 1 つの頂点を 4-way ブレンド
        let bones = vec![
            make_bone("b0", -1, 0.0, 0.0),
            make_bone("b1", -1, 10.0, 0.0),
            make_bone("b2", -1, 20.0, 0.0),
            make_bone("b3", -1, 30.0, 0.0),
        ];
        let pose = Pose::from_descriptors(&bones);
        let weights = VertexWeights {
            bone_indices: [0, 1, 2, 3],
            weights: [0.25, 0.25, 0.25, 0.25],
        };
        let rest = [0.0, 0.0];
        // bind pose のままなのでスキニング後も rest 同じ
        let skinned = skin_lbs(rest, &weights, &pose.world_matrices, &pose.inverse_bind_matrices);
        assert!((skinned[0] - 0.0).abs() < 1e-3);
        assert!((skinned[1] - 0.0).abs() < 1e-3);
    }

    #[test]
    fn skinning_is_deterministic() {
        let bones = vec![make_bone("root", -1, 1.0, 2.0)];
        let pose = Pose::from_descriptors(&bones);
        let w = VertexWeights::single(0);
        let a = skin_lbs([3.0, 4.0], &w, &pose.world_matrices, &pose.inverse_bind_matrices);
        let b = skin_lbs([3.0, 4.0], &w, &pose.world_matrices, &pose.inverse_bind_matrices);
        assert_eq!(a, b);
    }

    #[test]
    fn unweighted_vertex_returns_rest() {
        let bones = vec![make_bone("root", -1, 0.0, 0.0)];
        let pose = Pose::from_descriptors(&bones);
        let w = VertexWeights::default();
        let rest = [9.0, 9.0];
        let skinned = skin_lbs(rest, &w, &pose.world_matrices, &pose.inverse_bind_matrices);
        assert_eq!(skinned, rest);
    }
}
