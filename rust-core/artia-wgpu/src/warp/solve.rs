// Phase 4C: パペットワープの変形ソルバ (RBF 系)
// Why: 全制御点 (anchor + pin) からの逆距離重み (Inverse Distance Weighting; RBF の最も単純な
//      バリアント) で各頂点の変位を決める。Thin-Plate Spline はナイーブ実装可だが、
//      初期実装の決定論性 / 単純さを優先して IDW を採用する。
//      anchor (target == source) は変位 0 を加重平均に貢献するので、近傍では pin の影響を
//      抑制する自然な挙動になる。

use super::handle::HandleDescriptor;

/// IDW で `point` における 2D 変位を計算する。
///
/// - `power`: 距離の累乗 (典型値 2.0)。大きいほど局所的な変形になる。
/// - `epsilon`: 0 除算回避のオフセット (典型値 1e-3)。
///
/// 返り値: 変位 `[dx, dy]`。`handles` が空のときは `[0, 0]`。
pub fn solve_displacement_idw(
    point: [f32; 2],
    handles: &[HandleDescriptor],
    power: f32,
    epsilon: f32,
) -> [f32; 2] {
    if handles.is_empty() {
        return [0.0, 0.0];
    }
    let eps = epsilon.max(1e-6);
    let mut weighted_dx = 0.0_f64;
    let mut weighted_dy = 0.0_f64;
    let mut total_w = 0.0_f64;

    for h in handles {
        let dx = (point[0] - h.source[0]) as f64;
        let dy = (point[1] - h.source[1]) as f64;
        let dist = (dx * dx + dy * dy).sqrt() + eps as f64;
        let w = 1.0 / dist.powf(power as f64);
        let disp = h.displacement();
        weighted_dx += w * disp[0] as f64;
        weighted_dy += w * disp[1] as f64;
        total_w += w;
    }
    if total_w == 0.0 {
        return [0.0, 0.0];
    }
    [(weighted_dx / total_w) as f32, (weighted_dy / total_w) as f32]
}

/// `mesh` の `original` 頂点全てに `solve_displacement_idw` を適用し、
/// `deformed` に書き戻す。
pub fn apply_idw_to_mesh(
    mesh: &mut super::mesh::GridMesh,
    handles: &[HandleDescriptor],
    power: f32,
    epsilon: f32,
) {
    for (i, original) in mesh.original.iter().enumerate() {
        let d = solve_displacement_idw(*original, handles, power, epsilon);
        mesh.deformed[i] = [original[0] + d[0], original[1] + d[1]];
    }
}

#[cfg(test)]
mod tests {
    use super::super::handle::{HandleDescriptor, HandleKind};
    use super::*;

    fn pin(source: [f32; 2], target: [f32; 2]) -> HandleDescriptor {
        HandleDescriptor { kind: HandleKind::Pin, source, target }
    }

    fn anchor(point: [f32; 2]) -> HandleDescriptor {
        HandleDescriptor { kind: HandleKind::Anchor, source: point, target: point }
    }

    #[test]
    fn empty_handles_yield_zero_displacement() {
        let d = solve_displacement_idw([10.0, 10.0], &[], 2.0, 1e-3);
        assert_eq!(d, [0.0, 0.0]);
    }

    #[test]
    fn anchor_only_yields_zero_displacement() {
        let handles = vec![anchor([0.0, 0.0]), anchor([100.0, 0.0])];
        let d = solve_displacement_idw([50.0, 0.0], &handles, 2.0, 1e-3);
        assert!(d[0].abs() < 1e-3);
        assert!(d[1].abs() < 1e-3);
    }

    #[test]
    fn single_pin_drives_target_displacement_at_source() {
        // 制御点 1 つだけなら、その source 位置の変位は完全に displacement と一致する。
        let handles = vec![pin([10.0, 10.0], [20.0, 10.0])];
        let d = solve_displacement_idw([10.0, 10.0], &handles, 2.0, 1e-3);
        assert!((d[0] - 10.0).abs() < 0.5);
        assert!(d[1].abs() < 0.5);
    }

    #[test]
    fn farther_point_gets_smaller_displacement_with_anchors() {
        // anchor が 1 つ + pin が 1 つ。anchor から離れた位置は pin の影響が大きく、
        // anchor に近い位置は pin の影響が抑制される。
        let handles = vec![anchor([0.0, 0.0]), pin([100.0, 0.0], [110.0, 0.0])];
        let near_anchor = solve_displacement_idw([10.0, 0.0], &handles, 2.0, 1e-3);
        let near_pin = solve_displacement_idw([90.0, 0.0], &handles, 2.0, 1e-3);
        assert!(near_anchor[0].abs() < near_pin[0].abs());
    }

    #[test]
    fn apply_idw_to_mesh_updates_deformed_positions() {
        let mut mesh = super::super::mesh::GridMesh::new(2, 2, 100.0, 100.0);
        let handles = vec![pin([50.0, 50.0], [60.0, 50.0])];
        apply_idw_to_mesh(&mut mesh, &handles, 2.0, 1e-3);
        // 中心頂点が右に動いている
        let center_idx = (mesh.cols + 1) as usize + 1; // (1,1)
        assert!(mesh.deformed[center_idx][0] > mesh.original[center_idx][0]);
    }

    #[test]
    fn deterministic_for_same_input() {
        let handles = vec![pin([1.0, 2.0], [3.0, 4.0]), anchor([10.0, 10.0])];
        let a = solve_displacement_idw([5.0, 5.0], &handles, 2.0, 1e-3);
        let b = solve_displacement_idw([5.0, 5.0], &handles, 2.0, 1e-3);
        assert_eq!(a, b);
    }
}
