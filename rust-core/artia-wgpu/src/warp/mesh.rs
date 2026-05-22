// Phase 4C: パペットワープ用の規則格子メッシュ
// Why: 16x16 や 32x32 程度の規則格子で全体を覆えば、Wallpaper Engine 互換の
//      パペット変形は十分実現できる。Delaunay 拡張は後続フェーズで導入する。

/// 規則格子で生成する 2D メッシュ。
pub struct GridMesh {
    /// 列数 (X 方向のセル数)。頂点数は `cols + 1`。
    pub cols: u32,
    /// 行数 (Y 方向のセル数)。頂点数は `rows + 1`。
    pub rows: u32,
    /// メッシュの実寸 (レイヤー幅, px)
    pub width: f32,
    /// メッシュの実寸 (レイヤー高, px)
    pub height: f32,
    /// 元の頂点位置 (rest pose; レイヤー画像座標 px)。
    pub original: Vec<[f32; 2]>,
    /// 変形後の頂点位置 (毎フレーム更新)。
    pub deformed: Vec<[f32; 2]>,
    /// 三角形インデックス (CCW)。
    pub indices: Vec<u32>,
}

impl GridMesh {
    /// 規則格子メッシュを構築する。
    /// - `cols`/`rows` はセル数。0 のときは 1 に丸める。
    pub fn new(cols: u32, rows: u32, width: f32, height: f32) -> Self {
        let cols = cols.max(1);
        let rows = rows.max(1);
        let vx = cols + 1;
        let vy = rows + 1;
        let mut original = Vec::with_capacity((vx * vy) as usize);
        for y in 0..vy {
            for x in 0..vx {
                let fx = (x as f32 / cols as f32) * width;
                let fy = (y as f32 / rows as f32) * height;
                original.push([fx, fy]);
            }
        }
        let deformed = original.clone();

        // 各セルを 2 つの三角形に分割する。
        let mut indices = Vec::with_capacity((cols * rows * 6) as usize);
        for y in 0..rows {
            for x in 0..cols {
                let i0 = y * vx + x;
                let i1 = i0 + 1;
                let i2 = (y + 1) * vx + x;
                let i3 = i2 + 1;
                indices.extend_from_slice(&[i0, i2, i1, i1, i2, i3]);
            }
        }

        Self {
            cols,
            rows,
            width,
            height,
            original,
            deformed,
            indices,
        }
    }

    /// 頂点総数。
    pub fn vertex_count(&self) -> usize {
        self.original.len()
    }

    /// 三角形数。
    pub fn triangle_count(&self) -> usize {
        self.indices.len() / 3
    }

    /// 変形バッファをリセットする (rest pose に戻す)。
    pub fn reset(&mut self) {
        self.deformed.copy_from_slice(&self.original);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grid_4x4_has_25_vertices_and_32_triangles() {
        let mesh = GridMesh::new(4, 4, 100.0, 100.0);
        assert_eq!(mesh.vertex_count(), 25);
        assert_eq!(mesh.triangle_count(), 32);
    }

    #[test]
    fn original_corners_match_layer_bounds() {
        let mesh = GridMesh::new(4, 4, 200.0, 100.0);
        // 左上 (0,0)
        assert_eq!(mesh.original[0], [0.0, 0.0]);
        // 右下 ((cols+1)*(rows+1)-1)
        let last = mesh.original.len() - 1;
        assert_eq!(mesh.original[last], [200.0, 100.0]);
    }

    #[test]
    fn reset_restores_original_positions() {
        let mut mesh = GridMesh::new(2, 2, 10.0, 10.0);
        mesh.deformed[0] = [99.0, 99.0];
        mesh.reset();
        assert_eq!(mesh.deformed[0], mesh.original[0]);
    }

    #[test]
    fn zero_dimensions_clamp_to_one_cell() {
        let mesh = GridMesh::new(0, 0, 1.0, 1.0);
        assert_eq!(mesh.cols, 1);
        assert_eq!(mesh.rows, 1);
        assert_eq!(mesh.vertex_count(), 4);
        assert_eq!(mesh.triangle_count(), 2);
    }
}
