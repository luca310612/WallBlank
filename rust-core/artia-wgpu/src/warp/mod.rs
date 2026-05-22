// Phase 4C / 4C+: パペットワープ (Mesh Deformation by Control Points)
// Why: Wallpaper Engine 互換のレイヤー変形機能として、規則格子メッシュ + 制御点 +
//      RBF で頂点変位を計算する。Phase 4A/4B 同様、CPU シミュレーションを
//      authoritative とし、GPU draw pass への組み込みは後続フェーズで行う。
//
// ## 座標系仕様 (Swift ↔ Rust 共通契約)
//
// - すべて 0..1 正規化座標を **推奨** (Swift 側 PuppetWarpBridge.normalized が変換)。
// - 原点 = **左上**、+Y は **下方向**。SwiftUI / AppKit のカーソル座標と一致。
// - GPU シェーダ側で NDC (左下原点・+Y 上) へ変換する。
// - mesh.original / handle.source / handle.target は **同じ単位** であれば
//   px / 正規化どちらでも数学的に正しい (descriptor の layer_size と一致させること)。
//
// ## ソルバの選択
//
// - 制御点 n ≥ 3 かつ TPS 行列が非特異 → **TPS** (Thin-Plate Spline)
// - 上記以外 → IDW (legacy / fallback)。

pub mod handle;
pub mod mesh;
pub mod solve;
pub mod solve_tps;

use serde::{Deserialize, Serialize};

mod shader {
    pub const WARP_WGSL: &str = include_str!("../shaders/warp/warp.wgsl");
}

pub use handle::{HandleDescriptor, HandleKind};
pub use mesh::GridMesh;
pub use shader::WARP_WGSL;
pub use solve::{apply_idw_to_mesh, solve_displacement_idw};
pub use solve_tps::{apply_tps_to_mesh, TpsSolver};

/// PuppetWarp の識別子。FFI で u32 ハンドルとして公開する。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct PuppetWarpId(pub u32);

/// PuppetWarp の生成パラメータ。Swift 側 `PuppetWarpDescriptor` と JSON 互換。
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct PuppetWarpDescriptor {
    /// 対象レイヤーの ID (engine 内 layer の `id`)。
    pub source_layer_id: String,
    /// 規則格子のセル数 (cols, rows)。
    #[serde(default = "default_grid")]
    pub grid: [u32; 2],
    /// 対象レイヤーの実寸 (px)。Swift 側で渡す。
    #[serde(default = "default_size")]
    pub layer_size: [f32; 2],
    /// 制御点。
    #[serde(default)]
    pub handles: Vec<HandleDescriptor>,
    /// IDW のべき乗 (典型値 2.0)。TPS 失敗時のみ参照される。
    #[serde(default = "default_power")]
    pub idw_power: f32,
    /// IDW のオフセット (0 除算回避; 典型値 1e-3)。TPS 失敗時のみ参照される。
    #[serde(default = "default_epsilon")]
    pub idw_epsilon: f32,
    /// TPS 平滑化係数 (0.0 = 厳密補間, >0 で曲率制約)。
    #[serde(default)]
    pub tps_lambda: f32,
    /// pin のみで anchor が無い場合に 4 隅へ自動 anchor を挿入するか。
    /// - 用途: ユーザが顔だけ pin したケースで、画像全体が translate しないように
    ///   端を固定する。Swift 側 UI のデフォルトは true。
    #[serde(default = "default_auto_anchor")]
    pub auto_anchor_corners: bool,
}

fn default_grid() -> [u32; 2] { [16, 16] }
fn default_size() -> [f32; 2] { [1.0, 1.0] }
fn default_power() -> f32 { 2.0 }
fn default_epsilon() -> f32 { 1e-3 }
fn default_auto_anchor() -> bool { false }

/// 部分更新用 (handle のみ差し替えたい時)。
#[derive(Clone, Debug, Serialize, Deserialize, Default, PartialEq)]
pub struct PuppetWarpParams {
    pub handles: Option<Vec<HandleDescriptor>>,
    pub idw_power: Option<f32>,
    pub idw_epsilon: Option<f32>,
    pub tps_lambda: Option<f32>,
    pub auto_anchor_corners: Option<bool>,
}

/// ランタイム側の PuppetWarp。
pub struct PuppetWarp {
    pub id: PuppetWarpId,
    pub source_layer_id: String,
    pub mesh: GridMesh,
    pub handles: Vec<HandleDescriptor>,
    pub idw_power: f32,
    pub idw_epsilon: f32,
    pub tps_lambda: f32,
    pub auto_anchor_corners: bool,
}

impl PuppetWarp {
    pub fn new(id: PuppetWarpId, descriptor: PuppetWarpDescriptor) -> Self {
        let mesh = GridMesh::new(
            descriptor.grid[0],
            descriptor.grid[1],
            descriptor.layer_size[0].max(1.0),
            descriptor.layer_size[1].max(1.0),
        );
        let mut warp = Self {
            id,
            source_layer_id: descriptor.source_layer_id,
            mesh,
            handles: descriptor.handles,
            idw_power: descriptor.idw_power,
            idw_epsilon: descriptor.idw_epsilon,
            tps_lambda: descriptor.tps_lambda,
            auto_anchor_corners: descriptor.auto_anchor_corners,
        };
        warp.recompute_deformed();
        warp
    }

    /// パラメータ部分更新を反映する。
    pub fn apply_params(&mut self, params: PuppetWarpParams) {
        if let Some(h) = params.handles {
            self.handles = h;
        }
        if let Some(p) = params.idw_power {
            self.idw_power = p;
        }
        if let Some(e) = params.idw_epsilon {
            self.idw_epsilon = e;
        }
        if let Some(l) = params.tps_lambda {
            self.tps_lambda = l;
        }
        if let Some(a) = params.auto_anchor_corners {
            self.auto_anchor_corners = a;
        }
        self.recompute_deformed();
    }

    /// 現在の handle 群から `mesh.deformed` を再計算する。
    /// 優先順: TPS (n≥3 かつ非特異) → IDW フォールバック。
    pub fn recompute_deformed(&mut self) {
        let effective = self.effective_handles();
        // TPS を試行。制御点不足 / 特異行列なら IDW に fallback。
        if !apply_tps_to_mesh(&mut self.mesh, &effective, self.tps_lambda as f64) {
            apply_idw_to_mesh(
                &mut self.mesh,
                &effective,
                self.idw_power,
                self.idw_epsilon,
            );
        }
    }

    /// auto_anchor_corners が有効で、pin のみで anchor が無い場合に
    /// 4 隅の anchor を補完したハンドル列を返す。それ以外はクローンを返す。
    fn effective_handles(&self) -> Vec<HandleDescriptor> {
        if !self.auto_anchor_corners {
            return self.handles.clone();
        }
        let has_pin = self.handles.iter().any(|h| h.kind == HandleKind::Pin);
        let has_anchor = self.handles.iter().any(|h| h.kind == HandleKind::Anchor);
        if !has_pin || has_anchor {
            return self.handles.clone();
        }
        let w = self.mesh.width;
        let h = self.mesh.height;
        let mut augmented = self.handles.clone();
        for corner in [[0.0, 0.0], [w, 0.0], [0.0, h], [w, h]] {
            augmented.push(HandleDescriptor {
                kind: HandleKind::Anchor,
                source: corner,
                target: corner,
            });
        }
        augmented
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn descriptor_with(handles: Vec<HandleDescriptor>) -> PuppetWarpDescriptor {
        PuppetWarpDescriptor {
            source_layer_id: "layer-1".into(),
            grid: [4, 4],
            layer_size: [100.0, 100.0],
            handles,
            idw_power: 2.0,
            idw_epsilon: 1e-3,
            tps_lambda: 0.0,
            auto_anchor_corners: false,
        }
    }

    #[test]
    fn new_initializes_grid_mesh() {
        let warp = PuppetWarp::new(PuppetWarpId(1), descriptor_with(vec![]));
        assert_eq!(warp.mesh.vertex_count(), 25);
        // 制御点無し → 変形は元と同じ
        for (orig, def) in warp.mesh.original.iter().zip(warp.mesh.deformed.iter()) {
            assert!((orig[0] - def[0]).abs() < 1e-3);
            assert!((orig[1] - def[1]).abs() < 1e-3);
        }
    }

    #[test]
    fn pin_handle_drags_nearby_vertices() {
        let pin = HandleDescriptor {
            kind: HandleKind::Pin,
            source: [50.0, 50.0],
            target: [70.0, 50.0],
        };
        let mut warp = PuppetWarp::new(PuppetWarpId(2), descriptor_with(vec![pin]));
        // (1,1) = 中心付近の頂点が右に動いている
        let cols = warp.mesh.cols + 1;
        let center_idx = (cols * 2 + 2) as usize;
        let original = warp.mesh.original[center_idx];
        let deformed = warp.mesh.deformed[center_idx];
        assert!(deformed[0] > original[0]);
        // 再計算しても結果が同じ (決定論)
        warp.recompute_deformed();
        let deformed_again = warp.mesh.deformed[center_idx];
        assert_eq!(deformed, deformed_again);
    }

    #[test]
    fn apply_params_replaces_handles() {
        let mut warp = PuppetWarp::new(PuppetWarpId(3), descriptor_with(vec![]));
        let new_handles = vec![HandleDescriptor {
            kind: HandleKind::Pin,
            source: [25.0, 25.0],
            target: [40.0, 25.0],
        }];
        warp.apply_params(PuppetWarpParams {
            handles: Some(new_handles.clone()),
            ..Default::default()
        });
        assert_eq!(warp.handles, new_handles);
    }

    #[test]
    fn descriptor_round_trips_via_json() {
        let d = descriptor_with(vec![HandleDescriptor {
            kind: HandleKind::Anchor,
            source: [0.0, 0.0],
            target: [0.0, 0.0],
        }]);
        let json = serde_json::to_string(&d).unwrap();
        let back: PuppetWarpDescriptor = serde_json::from_str(&json).unwrap();
        assert_eq!(d, back);
    }

    #[test]
    fn shader_is_loaded() {
        assert!(WARP_WGSL.contains("@vertex"));
    }

    #[test]
    fn right_side_pin_with_auto_anchor_leaves_left_intact() {
        // バグ再現: ユーザが右側 (顔) を pin したとき、左側の頂点が歪まないこと。
        // auto_anchor_corners=true で 4 隅 anchor を自動補完するため
        // TPS は厳密補間でき、左端は不動になる。
        let mut descriptor = descriptor_with(vec![HandleDescriptor {
            kind: HandleKind::Pin,
            source: [85.0, 50.0],
            target: [95.0, 50.0],
        }]);
        descriptor.auto_anchor_corners = true;
        let warp = PuppetWarp::new(PuppetWarpId(42), descriptor);
        // 左上 (0,0) の頂点 index = 0
        let original_lt = warp.mesh.original[0];
        let deformed_lt = warp.mesh.deformed[0];
        assert!(
            (deformed_lt[0] - original_lt[0]).abs() < 0.1,
            "左上 anchor が動いてはならない: orig={:?} def={:?}",
            original_lt, deformed_lt
        );
        assert!(
            (deformed_lt[1] - original_lt[1]).abs() < 0.1,
            "左上 anchor が動いてはならない: orig={:?} def={:?}",
            original_lt, deformed_lt
        );
        // 右側中央付近 (pin 影響域) は右に動いている。
        let cols = warp.mesh.cols + 1;
        // (3, 2): grid 4x4, x≈75, y≈50
        let right_mid_idx = (cols * 2 + 3) as usize;
        let orig_rm = warp.mesh.original[right_mid_idx];
        let def_rm = warp.mesh.deformed[right_mid_idx];
        assert!(
            def_rm[0] > orig_rm[0] + 0.5,
            "右側 mid が pin で右に動いているべき: orig={:?} def={:?}",
            orig_rm, def_rm
        );
    }
}
