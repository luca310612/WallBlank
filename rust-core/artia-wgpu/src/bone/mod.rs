// Phase 4C: Skeleton (階層スケルトン + LBS スキニング)
// Why: bones / pose / skin の 3 つに役割分割し、Wallpaper Engine 互換のボーンアニメを
//      Rust 側で構築できるようにする。Phase 4A/4B 同様、CPU シミュレーションを
//      authoritative とし、GPU 経路は後続フェーズで dispatch を有効化する。

// Module structure mirrors particle/: bone/ contains a `bone` submodule whose name
// matches the parent. clippy::module_inception flags this; we keep the layout for
// pub use 公開のしやすさ。
#[allow(clippy::module_inception)]
pub mod bone;
pub mod pose;
pub mod skin;

use serde::{Deserialize, Serialize};

mod shader {
    pub const SKIN_WGSL: &str = include_str!("../shaders/bone/skin.wgsl");
}

pub use bone::{mat4_identity, transform_point2d, BoneDescriptor, Mat4};
pub use pose::{compute_fk, invert_affine_2d, Pose};
pub use shader::SKIN_WGSL;
pub use skin::{skin_lbs, VertexWeights};

/// Skeleton の識別子。FFI で u32 ハンドルとして公開する。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct SkeletonId(pub u32);

/// Swift `SkeletonDescriptor` と JSON 互換のスケルトン定義。
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct SkeletonDescriptor {
    /// 対象レイヤー ID (engine 内 layer.id)
    pub source_layer_id: String,
    /// ボーン (親 -> 子順に並ぶこと)
    pub bones: Vec<BoneDescriptor>,
    /// 頂点ごとの 4-bone weights
    #[serde(default)]
    pub weights: Vec<VertexWeights>,
    /// rest pose の頂点位置 (px)。weights と同数を期待。
    /// Why: スキニングを CPU 側で再計算する際に必要。
    #[serde(default)]
    pub rest_positions: Vec<[f32; 2]>,
}

/// `update_skeleton_pose` 用のパラメータ。
#[derive(Clone, Debug, Serialize, Deserialize, Default, PartialEq)]
pub struct SkeletonPoseParams {
    /// 全ボーンのローカル行列を一括差し替え (bone_count と一致が必要)。
    pub local_matrices: Option<Vec<Mat4>>,
}

/// ランタイム側のスケルトン。
pub struct Skeleton {
    pub id: SkeletonId,
    pub source_layer_id: String,
    pub pose: Pose,
    pub weights: Vec<VertexWeights>,
    pub rest_positions: Vec<[f32; 2]>,
    pub skinned_positions: Vec<[f32; 2]>,
}

impl Skeleton {
    pub fn new(id: SkeletonId, descriptor: SkeletonDescriptor) -> Self {
        let pose = Pose::from_descriptors(&descriptor.bones);
        let n_vertices = descriptor.rest_positions.len();
        let mut skel = Self {
            id,
            source_layer_id: descriptor.source_layer_id,
            pose,
            weights: descriptor.weights,
            rest_positions: descriptor.rest_positions,
            skinned_positions: vec![[0.0, 0.0]; n_vertices],
        };
        skel.recompute_skinning();
        skel
    }

    /// pose を全置換し FK + スキニングを再計算する。
    /// - Returns: bone_count に一致しなければ false。
    pub fn apply_pose(&mut self, params: SkeletonPoseParams) -> bool {
        if let Some(locals) = params.local_matrices {
            if !self.pose.apply_local_matrices(locals) {
                return false;
            }
        }
        self.recompute_skinning();
        true
    }

    /// 現在の pose で全 rest_positions をスキニングし `skinned_positions` に書き出す。
    pub fn recompute_skinning(&mut self) {
        let n = self.rest_positions.len();
        self.skinned_positions.resize(n, [0.0, 0.0]);
        for i in 0..n {
            let weights = self.weights.get(i).copied().unwrap_or_default();
            self.skinned_positions[i] = skin_lbs(
                self.rest_positions[i],
                &weights,
                &self.pose.world_matrices,
                &self.pose.inverse_bind_matrices,
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn root_bone(name: &str, tx: f32, ty: f32) -> BoneDescriptor {
        BoneDescriptor {
            name: name.into(),
            parent_id: -1,
            local_translation: [tx, ty, 0.0],
            local_rotation: 0.0,
            local_scale: [1.0, 1.0, 1.0],
            length: 1.0,
        }
    }

    #[test]
    fn bind_pose_skinning_yields_rest_positions() {
        let descriptor = SkeletonDescriptor {
            source_layer_id: "L".into(),
            bones: vec![root_bone("b0", 5.0, 0.0)],
            weights: vec![VertexWeights::single(0); 3],
            rest_positions: vec![[10.0, 0.0], [20.0, 0.0], [30.0, 0.0]],
        };
        let skel = Skeleton::new(SkeletonId(1), descriptor);
        for (rest, skinned) in skel.rest_positions.iter().zip(skel.skinned_positions.iter()) {
            assert!((rest[0] - skinned[0]).abs() < 1e-3);
            assert!((rest[1] - skinned[1]).abs() < 1e-3);
        }
    }

    #[test]
    fn pose_update_translates_skinned_vertices() {
        let descriptor = SkeletonDescriptor {
            source_layer_id: "L".into(),
            bones: vec![root_bone("b0", 0.0, 0.0)],
            weights: vec![VertexWeights::single(0); 1],
            rest_positions: vec![[5.0, 0.0]],
        };
        let mut skel = Skeleton::new(SkeletonId(2), descriptor);
        // ボーンを +10 移動 (bind pose は (0,0) なので、bind^-1 が identity)
        let translation: Mat4 = [
            [1.0, 0.0, 0.0, 0.0],
            [0.0, 1.0, 0.0, 0.0],
            [0.0, 0.0, 1.0, 0.0],
            [10.0, 0.0, 0.0, 1.0],
        ];
        skel.apply_pose(SkeletonPoseParams { local_matrices: Some(vec![translation]) });
        assert!((skel.skinned_positions[0][0] - 15.0).abs() < 1e-3);
        assert!(skel.skinned_positions[0][1].abs() < 1e-3);
    }

    #[test]
    fn descriptor_round_trips_via_json() {
        let descriptor = SkeletonDescriptor {
            source_layer_id: "L".into(),
            bones: vec![root_bone("b0", 1.0, 2.0)],
            weights: vec![VertexWeights::single(0)],
            rest_positions: vec![[3.0, 4.0]],
        };
        let json = serde_json::to_string(&descriptor).unwrap();
        let back: SkeletonDescriptor = serde_json::from_str(&json).unwrap();
        assert_eq!(descriptor, back);
    }

    #[test]
    fn shader_is_loaded() {
        assert!(SKIN_WGSL.contains("@vertex"));
    }

    #[test]
    fn apply_pose_with_wrong_count_returns_false() {
        let descriptor = SkeletonDescriptor {
            source_layer_id: "L".into(),
            bones: vec![root_bone("b0", 0.0, 0.0)],
            weights: vec![],
            rest_positions: vec![],
        };
        let mut skel = Skeleton::new(SkeletonId(3), descriptor);
        let bad = SkeletonPoseParams {
            local_matrices: Some(vec![mat4_identity(), mat4_identity()]), // 2 件 (bone は 1)
        };
        assert!(!skel.apply_pose(bad));
    }
}
