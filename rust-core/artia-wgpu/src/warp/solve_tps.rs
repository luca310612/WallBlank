// Phase 4C+: Thin-Plate Spline (TPS) ソルバ
// Why: Phase 4C 初期実装の IDW は近傍数件しか自然に補間できず、
//      pin から遠い側 (画面反対側) に高周波ノイズ的な歪みが出る現象が
//      ドッグフード中に報告された。
//      TPS は 2D で最も滑らかな (bending energy 最小) RBF として知られており、
//      sparse な制御点 (典型 4〜30) で Wallpaper Engine 互換のパペット品質を出せる。
//
// 座標系: mesh と同じ単位 (0..1 正規化 or px) で完結する。原点は左上、+Y 下方向。
//
// 数式 (各軸独立に解く):
//
//   f(p) = a0 + a1*p.x + a2*p.y + Σ_i w_i * φ(|p - q_i|)
//   φ(r) = r² log(r)   (r > 0),  φ(0) = 0
//
//   制御点 i / j について:
//     | K   P | | w |   | v |
//     | Pᵀ  0 | | a | = | 0 |
//   K_ij = φ(|q_i - q_j|),  P_i = [1, q_i.x, q_i.y]
//   未知数は (n + 3) 個、RHS も同サイズ。
//
//   解 (w, a) を保持すれば任意点で f(p) を O(n) で評価できる。

use super::handle::HandleDescriptor;

/// TPS は最低 3 点ないと affine basis (1, x, y) が縮退して解けないため、
/// 2 点以下では IDW にフォールバックする。
pub const TPS_MIN_HANDLES: usize = 3;

/// φ(r) = r² log(r) を r² 入力で評価する。0 近傍は 0 を返す。
#[inline]
fn phi(r2: f64) -> f64 {
    if r2 <= 1e-12 {
        0.0
    } else {
        // r² log(r) = 0.5 * r² * log(r²) (log(r) = 0.5 log(r²))
        0.5 * r2 * r2.ln()
    }
}

/// 正方行列 `m` (n×n) に対し `m * x = rhs` を partial-pivoting LU で解く。
/// 解は `rhs` に上書きされる。特異な場合は `None`。
fn solve_linear(m: &mut [Vec<f64>], rhs: &mut [f64]) -> Option<()> {
    let n = m.len();
    if n == 0 || rhs.len() != n {
        return None;
    }
    for k in 0..n {
        // ピボット選択
        let mut pivot = k;
        let mut pivot_abs = m[k][k].abs();
        for i in (k + 1)..n {
            let v = m[i][k].abs();
            if v > pivot_abs {
                pivot_abs = v;
                pivot = i;
            }
        }
        if pivot_abs < 1e-12 {
            return None;
        }
        if pivot != k {
            m.swap(k, pivot);
            rhs.swap(k, pivot);
        }
        let pivot_val = m[k][k];
        for i in (k + 1)..n {
            let factor = m[i][k] / pivot_val;
            if factor == 0.0 {
                continue;
            }
            m[i][k] = 0.0;
            for j in (k + 1)..n {
                m[i][j] -= factor * m[k][j];
            }
            rhs[i] -= factor * rhs[k];
        }
    }
    // 後退代入
    for i in (0..n).rev() {
        let mut s = rhs[i];
        for j in (i + 1)..n {
            s -= m[i][j] * rhs[j];
        }
        rhs[i] = s / m[i][i];
    }
    Some(())
}

/// TPS の重み (w, a) を 1 回だけ構築して保持し、任意点で eval できるソルバ。
pub struct TpsSolver {
    /// 制御点座標 (mesh と同じ単位)。
    points: Vec<[f32; 2]>,
    /// X 軸の重み + affine。長さ = n + 3。
    wx: Vec<f64>,
    /// Y 軸の重み + affine。長さ = n + 3。
    wy: Vec<f64>,
}

impl TpsSolver {
    /// `handles` から TPS 重みを構築する。
    /// - `lambda`: 平滑化項 (0.0 = 厳密補間、>0 = 平滑化)。
    /// - 制御点 < 3 / 行列特異 (例: 同一直線上に並ぶ 3 点) の場合は `None`。
    pub fn new(handles: &[HandleDescriptor], lambda: f64) -> Option<Self> {
        let n = handles.len();
        if n < TPS_MIN_HANDLES {
            return None;
        }
        let size = n + 3;
        let mut matrix: Vec<Vec<f64>> = vec![vec![0.0; size]; size];

        let pts: Vec<[f64; 2]> = handles
            .iter()
            .map(|h| [h.source[0] as f64, h.source[1] as f64])
            .collect();
        let disps: Vec<[f64; 2]> = handles
            .iter()
            .map(|h| {
                let d = h.displacement();
                [d[0] as f64, d[1] as f64]
            })
            .collect();

        // K (n×n): K_ij = φ(|q_i - q_j|), 対角に lambda を加える
        for i in 0..n {
            for j in 0..n {
                let dx = pts[i][0] - pts[j][0];
                let dy = pts[i][1] - pts[j][1];
                matrix[i][j] = phi(dx * dx + dy * dy);
            }
            matrix[i][i] += lambda;
        }
        // P (n×3) と Pᵀ
        for i in 0..n {
            matrix[i][n] = 1.0;
            matrix[i][n + 1] = pts[i][0];
            matrix[i][n + 2] = pts[i][1];
            matrix[n][i] = 1.0;
            matrix[n + 1][i] = pts[i][0];
            matrix[n + 2][i] = pts[i][1];
        }

        // X / Y それぞれ別の RHS で解く。行列が同じなので 2 回 LU が走るが
        // 制御点数が小さい (≤ 30) ためコストは無視できる。
        let mut rhs_x = vec![0.0_f64; size];
        let mut rhs_y = vec![0.0_f64; size];
        for i in 0..n {
            rhs_x[i] = disps[i][0];
            rhs_y[i] = disps[i][1];
        }
        let mut mx = matrix.clone();
        solve_linear(&mut mx, &mut rhs_x)?;
        let mut my = matrix;
        solve_linear(&mut my, &mut rhs_y)?;

        Some(Self {
            points: handles.iter().map(|h| h.source).collect(),
            wx: rhs_x,
            wy: rhs_y,
        })
    }

    /// 任意点 p における変位 [dx, dy] を評価する。
    pub fn eval(&self, p: [f32; 2]) -> [f32; 2] {
        let n = self.points.len();
        let px = p[0] as f64;
        let py = p[1] as f64;
        let mut dx = self.wx[n] + self.wx[n + 1] * px + self.wx[n + 2] * py;
        let mut dy = self.wy[n] + self.wy[n + 1] * px + self.wy[n + 2] * py;
        for i in 0..n {
            let rx = px - self.points[i][0] as f64;
            let ry = py - self.points[i][1] as f64;
            let phi_v = phi(rx * rx + ry * ry);
            dx += self.wx[i] * phi_v;
            dy += self.wy[i] * phi_v;
        }
        [dx as f32, dy as f32]
    }
}

/// `mesh.original` 全頂点に TPS を適用して `deformed` に書き戻す。
/// 構築に失敗した場合は `false` を返し、`mesh` は変更されない。
pub fn apply_tps_to_mesh(
    mesh: &mut super::mesh::GridMesh,
    handles: &[HandleDescriptor],
    lambda: f64,
) -> bool {
    let Some(solver) = TpsSolver::new(handles, lambda) else {
        return false;
    };
    for (i, original) in mesh.original.iter().enumerate() {
        let d = solver.eval(*original);
        mesh.deformed[i] = [original[0] + d[0], original[1] + d[1]];
    }
    true
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
    fn returns_none_for_fewer_than_three_handles() {
        assert!(TpsSolver::new(&[], 0.0).is_none());
        assert!(TpsSolver::new(&[pin([0.0, 0.0], [1.0, 0.0])], 0.0).is_none());
        assert!(TpsSolver::new(
            &[pin([0.0, 0.0], [1.0, 0.0]), anchor([0.5, 0.5])],
            0.0
        ).is_none());
    }

    #[test]
    fn returns_none_for_collinear_three_handles() {
        // 同一直線上の 3 点は P 行が rank 2 になり、TPS 系が縮退する
        let handles = vec![
            anchor([0.0, 0.5]),
            anchor([0.5, 0.5]),
            anchor([1.0, 0.5]),
        ];
        assert!(TpsSolver::new(&handles, 0.0).is_none());
    }

    #[test]
    fn exact_interpolation_at_control_points() {
        // TPS の特徴: 制御点位置では target に完全一致する (lambda=0)
        let handles = vec![
            anchor([0.0, 0.0]),
            anchor([1.0, 0.0]),
            anchor([0.0, 1.0]),
            pin([0.8, 0.5], [0.9, 0.5]),
        ];
        let solver = TpsSolver::new(&handles, 0.0).expect("4 制御点で構築できるべき");
        for h in &handles {
            let d = solver.eval(h.source);
            let expected = h.displacement();
            assert!(
                (d[0] - expected[0]).abs() < 1e-3,
                "x 軸 dx={} expected={}",
                d[0], expected[0]
            );
            assert!(
                (d[1] - expected[1]).abs() < 1e-3,
                "y 軸 dy={} expected={}",
                d[1], expected[1]
            );
        }
    }

    #[test]
    fn right_side_handle_does_not_distort_left_corners() {
        // バグ再現テスト: 4 隅 anchor + 右側 pin (x=0.85) で、
        // 左側の頂点が「pin の影響を強く受けない」ことを確認する。
        // TPS は連続関数なので左端中点は完全 0 にはならないが、
        // 右側 pin 位置に比べれば十分に小さい (>= 3 倍差) ことを保証する。
        let handles = vec![
            anchor([0.0, 0.0]),
            anchor([0.0, 1.0]),
            anchor([1.0, 0.0]),
            anchor([1.0, 1.0]),
            pin([0.85, 0.5], [0.95, 0.5]), // 右側を 0.1 だけ右に
        ];
        let solver = TpsSolver::new(&handles, 0.0).expect("TPS 構築できるべき");
        // 左上 / 左下 anchor 上: 厳密 0
        let left_top = solver.eval([0.0, 0.0]);
        assert!(left_top[0].abs() < 1e-3, "左上 anchor は不動: dx={}", left_top[0]);
        assert!(left_top[1].abs() < 1e-3, "左上 anchor は不動: dy={}", left_top[1]);
        let left_bot = solver.eval([0.0, 1.0]);
        assert!(left_bot[0].abs() < 1e-3, "左下 anchor は不動: dx={}", left_bot[0]);

        // 左側中央 (補間点): pin の影響は強くない (絶対値 < pin 変位の 50%)
        let left_mid = solver.eval([0.0, 0.5]);
        let pin_disp = 0.1_f32;
        assert!(
            left_mid[0].abs() < pin_disp * 0.5,
            "左側中央への影響が pin 変位の半分未満であるべき: dx={}",
            left_mid[0]
        );
        // 右側 pin 位置: target displacement と一致 (厳密補間)
        let right_pin = solver.eval([0.85, 0.5]);
        assert!(
            (right_pin[0] - pin_disp).abs() < 1e-3,
            "pin 位置では target displacement と一致するべき: dx={}",
            right_pin[0]
        );
        // 「左側 vs 右側」のコントラスト: 右側 pin 位置の影響は左側中央の影響の 3 倍以上
        assert!(
            right_pin[0].abs() > 3.0 * left_mid[0].abs(),
            "右側 pin への影響が左側中央への影響より十分大きいべき (right={} left={})",
            right_pin[0], left_mid[0]
        );
    }

    #[test]
    fn apply_tps_to_mesh_overwrites_deformed() {
        let mut mesh = super::super::mesh::GridMesh::new(4, 4, 1.0, 1.0);
        let handles = vec![
            anchor([0.0, 0.0]),
            anchor([0.0, 1.0]),
            anchor([1.0, 0.0]),
            pin([0.5, 0.5], [0.6, 0.5]),
        ];
        let ok = apply_tps_to_mesh(&mut mesh, &handles, 0.0);
        assert!(ok);
        // 中心頂点 (i=2, j=2) は元 [0.5, 0.5] → 約 [0.6, 0.5]
        let cols = mesh.cols + 1;
        let center_idx = (cols * 2 + 2) as usize;
        let original = mesh.original[center_idx];
        let deformed = mesh.deformed[center_idx];
        assert!(
            (deformed[0] - 0.6).abs() < 1e-2,
            "TPS 厳密補間で 0.6 付近に着地するべき (got {})",
            deformed[0]
        );
        assert!((deformed[1] - original[1]).abs() < 1e-2);
    }

    #[test]
    fn deterministic_for_same_input() {
        let handles = vec![
            anchor([0.0, 0.0]),
            anchor([1.0, 0.0]),
            anchor([0.0, 1.0]),
            pin([0.5, 0.5], [0.6, 0.5]),
        ];
        let a = TpsSolver::new(&handles, 0.0).unwrap();
        let b = TpsSolver::new(&handles, 0.0).unwrap();
        let pa = a.eval([0.3, 0.3]);
        let pb = b.eval([0.3, 0.3]);
        assert!((pa[0] - pb[0]).abs() < 1e-9);
        assert!((pa[1] - pb[1]).abs() < 1e-9);
    }
}
