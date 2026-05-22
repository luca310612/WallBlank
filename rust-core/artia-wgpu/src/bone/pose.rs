// Phase 4C: スケルトンの Pose (FK + 逆行列キャッシュ)
// Why: ローカル変換 → ワールド変換を毎フレーム計算する FK と、スキニングに必要な
//      bind pose の逆行列を一括で管理する。

use crate::types::mul_mat4;

use super::bone::{mat4_identity, BoneDescriptor, Mat4};

/// FK 結果と inverse-bind-matrix のキャッシュ。
pub struct Pose {
    pub bone_count: usize,
    /// 各ボーンの parent index (-1 = ルート)。
    pub parents: Vec<i32>,
    /// 各ボーンの現在のローカル変換 (`update_pose` で書き換える)。
    pub local_matrices: Vec<Mat4>,
    /// 各ボーンの計算済みワールド変換。
    pub world_matrices: Vec<Mat4>,
    /// bind pose 時のワールド変換の逆行列。スキニングで使用。
    pub inverse_bind_matrices: Vec<Mat4>,
}

impl Pose {
    /// `descriptors` を bind pose とみなして初期化する。
    /// - 親 -> 子の順に並んでいることを期待する (parent_id が i 以下)。
    pub fn from_descriptors(descriptors: &[BoneDescriptor]) -> Self {
        let bone_count = descriptors.len();
        let parents: Vec<i32> = descriptors.iter().map(|b| b.parent_id).collect();
        let local_matrices: Vec<Mat4> = descriptors.iter().map(|b| b.local_matrix()).collect();
        let mut world_matrices = vec![mat4_identity(); bone_count];
        compute_fk(&parents, &local_matrices, &mut world_matrices);
        let inverse_bind_matrices: Vec<Mat4> =
            world_matrices.iter().map(|m| invert_affine_2d(*m)).collect();
        Self {
            bone_count,
            parents,
            local_matrices,
            world_matrices,
            inverse_bind_matrices,
        }
    }

    /// FK を再計算してワールド行列を更新する。
    pub fn refresh_world(&mut self) {
        compute_fk(&self.parents, &self.local_matrices, &mut self.world_matrices);
    }

    /// 全ボーンのローカル変換を一括差し替えして FK を回す。
    /// - `local_matrices.len()` が `bone_count` と一致しなければ false。
    pub fn apply_local_matrices(&mut self, local_matrices: Vec<Mat4>) -> bool {
        if local_matrices.len() != self.bone_count {
            return false;
        }
        self.local_matrices = local_matrices;
        self.refresh_world();
        true
    }

    /// 単一ボーンのローカル変換を差し替える。
    pub fn set_local_matrix(&mut self, bone_index: usize, matrix: Mat4) -> bool {
        if bone_index >= self.bone_count {
            return false;
        }
        self.local_matrices[bone_index] = matrix;
        self.refresh_world();
        true
    }
}

/// FK: 親 -> 子の順で `world[i] = world[parent] * local[i]` を計算する。
pub fn compute_fk(parents: &[i32], local_matrices: &[Mat4], world_matrices: &mut [Mat4]) {
    let n = local_matrices.len();
    debug_assert_eq!(parents.len(), n);
    debug_assert_eq!(world_matrices.len(), n);
    for i in 0..n {
        let parent = parents[i];
        if parent < 0 {
            world_matrices[i] = local_matrices[i];
        } else {
            let p = parent as usize;
            // p < i を仮定 (親 -> 子順)。万一逆順なら 0 行列ではなく identity でフォールバック。
            let parent_world = if p < i { world_matrices[p] } else { mat4_identity() };
            world_matrices[i] = mul_mat4(parent_world, local_matrices[i]);
        }
    }
}

/// 2D affine 用の Mat4 逆行列 (回転 + 一様/異方スケール + 平行移動)。
/// 既存 `types::invert_mat4` と等価実装だが、bone 内で再利用するために重複定義する。
pub fn invert_affine_2d(m: Mat4) -> Mat4 {
    // 列優先: m[col][row]
    let a = m[0][0];
    let b = m[1][0];
    let c = m[0][1];
    let d = m[1][1];
    let tx = m[3][0];
    let ty = m[3][1];

    let det = a * d - b * c;
    if det.abs() < 1e-8 {
        return mat4_identity();
    }
    let inv_det = 1.0 / det;
    let ia = d * inv_det;
    let ib = -b * inv_det;
    let ic = -c * inv_det;
    let id = a * inv_det;
    let itx = -(ia * tx + ib * ty);
    let ity = -(ic * tx + id * ty);
    [
        [ia, ic, 0.0, 0.0],
        [ib, id, 0.0, 0.0],
        [0.0, 0.0, 1.0, 0.0],
        [itx, ity, 0.0, 1.0],
    ]
}

#[cfg(test)]
mod tests {
    use super::super::bone::{transform_point2d, BoneDescriptor};
    use super::*;

    fn make_bone(name: &str, parent: i32, tx: f32, ty: f32, rot: f32) -> BoneDescriptor {
        BoneDescriptor {
            name: name.into(),
            parent_id: parent,
            local_translation: [tx, ty, 0.0],
            local_rotation: rot,
            local_scale: [1.0, 1.0, 1.0],
            length: 1.0,
        }
    }

    #[test]
    fn root_world_equals_local() {
        let bones = vec![make_bone("root", -1, 5.0, 7.0, 0.0)];
        let pose = Pose::from_descriptors(&bones);
        let p = transform_point2d(pose.world_matrices[0], [0.0, 0.0]);
        assert!((p[0] - 5.0).abs() < 1e-4);
        assert!((p[1] - 7.0).abs() < 1e-4);
    }

    #[test]
    fn child_world_inherits_from_parent() {
        // root: 並行移動 (10, 0); child: ローカル並行移動 (5, 0)
        // → child world で原点は (15, 0) に移る
        let bones = vec![
            make_bone("root", -1, 10.0, 0.0, 0.0),
            make_bone("child", 0, 5.0, 0.0, 0.0),
        ];
        let pose = Pose::from_descriptors(&bones);
        let child_world = transform_point2d(pose.world_matrices[1], [0.0, 0.0]);
        assert!((child_world[0] - 15.0).abs() < 1e-4);
        assert!(child_world[1].abs() < 1e-4);
    }

    #[test]
    fn rotated_parent_propagates_to_child() {
        // root: rotation 90deg, child: ローカル並行移動 (1, 0)
        // → child world (0,0) は (0, 1)
        let bones = vec![
            make_bone("root", -1, 0.0, 0.0, std::f32::consts::FRAC_PI_2),
            make_bone("child", 0, 1.0, 0.0, 0.0),
        ];
        let pose = Pose::from_descriptors(&bones);
        let p = transform_point2d(pose.world_matrices[1], [0.0, 0.0]);
        assert!(p[0].abs() < 1e-4);
        assert!((p[1] - 1.0).abs() < 1e-4);
    }

    #[test]
    fn inverse_bind_matrices_undo_world_at_origin() {
        let bones = vec![
            make_bone("root", -1, 10.0, 5.0, 0.0),
            make_bone("child", 0, 3.0, 0.0, 0.0),
        ];
        let pose = Pose::from_descriptors(&bones);
        for i in 0..pose.bone_count {
            // bind pose では world * inverse_bind == identity
            let composed = mul_mat4(pose.world_matrices[i], pose.inverse_bind_matrices[i]);
            for (col, column) in composed.iter().enumerate() {
                for (row, value) in column.iter().enumerate() {
                    let expected = if col == row { 1.0 } else { 0.0 };
                    assert!((value - expected).abs() < 1e-3);
                }
            }
        }
    }

    #[test]
    fn apply_local_matrices_updates_world() {
        let bones = vec![make_bone("root", -1, 0.0, 0.0, 0.0)];
        let mut pose = Pose::from_descriptors(&bones);
        // 別の local 行列に差し替え
        let new_local: Mat4 = [
            [1.0, 0.0, 0.0, 0.0],
            [0.0, 1.0, 0.0, 0.0],
            [0.0, 0.0, 1.0, 0.0],
            [42.0, 0.0, 0.0, 1.0],
        ];
        assert!(pose.apply_local_matrices(vec![new_local]));
        assert_eq!(pose.world_matrices[0][3][0], 42.0);
    }
}
