//! 8bit Planar マスクのペイント／ぼかし／反転ヘルパ。
//! Swift 側 `MaskData` のホットパス（paint / paintStroke / blur / invert / fillRect）を Rust に集約。
//! Why: Swift の二重ループは描画中に毎フレーム呼ばれて CPU を食い潰すため、
//! Rust 側でクリッピング・LUT・矩形分割を含めて高速に処理する。

/// 円形ブラシでマスクに塗る。`is_erasing = true` で消しゴム動作。
pub fn paint_circle(
    data: &mut [u8],
    width: i32,
    height: i32,
    center_x: i32,
    center_y: i32,
    radius: i32,
    value: u8,
    softness: f32,
    is_erasing: bool,
) {
    if radius <= 0 || width <= 0 || height <= 0 {
        return;
    }
    let w = width as usize;
    let h = height as usize;
    if data.len() != w * h {
        return;
    }

    let radius_sq = (radius * radius) as i32;

    // クリッピング
    let min_x = center_x.saturating_sub(radius).max(0);
    let max_x = (center_x + radius).min(width - 1);
    let min_y = center_y.saturating_sub(radius).max(0);
    let max_y = (center_y + radius).min(height - 1);
    if min_x > max_x || min_y > max_y {
        return;
    }

    // フォールオフ LUT
    let lut = build_falloff_lut(radius, softness);
    let value_f = value as f32;
    let max_mask: f32 = 255.0;

    for y in min_y..=max_y {
        let dy = y - center_y;
        let row_offset = (y as usize) * w;
        for x in min_x..=max_x {
            let dx = x - center_x;
            let dist_sq = dx * dx + dy * dy;
            if dist_sq <= radius_sq {
                let dist = (dist_sq as f32).sqrt();
                let lut_idx = (dist as usize).min(radius as usize);
                let falloff = lut[lut_idx];
                let idx = row_offset + (x as usize);
                let current = data[idx] as f32;
                if is_erasing {
                    let erase_amount = max_mask * falloff;
                    data[idx] = (current - erase_amount).max(0.0) as u8;
                } else {
                    let strength = value_f * falloff;
                    let new_val = current.max(strength);
                    data[idx] = new_val.min(max_mask) as u8;
                }
            }
        }
    }
}

/// 点列をストロークとして塗る（LUT を 1 回だけ作って使い回し）。
pub fn paint_stroke(
    data: &mut [u8],
    width: i32,
    height: i32,
    points_xy: &[(f32, f32)],
    radius: i32,
    value: u8,
    softness: f32,
    is_erasing: bool,
) {
    if points_xy.is_empty() || radius <= 0 || width <= 0 || height <= 0 {
        return;
    }
    let w = width as usize;
    let h = height as usize;
    if data.len() != w * h {
        return;
    }

    let radius_sq = (radius * radius) as i32;
    let lut = build_falloff_lut(radius, softness);
    let value_f = value as f32;
    let max_mask: f32 = 255.0;

    for &(px, py) in points_xy {
        let center_x = px.round() as i32;
        let center_y = py.round() as i32;

        let min_x = center_x.saturating_sub(radius).max(0);
        let max_x = (center_x + radius).min(width - 1);
        let min_y = center_y.saturating_sub(radius).max(0);
        let max_y = (center_y + radius).min(height - 1);
        if min_x > max_x || min_y > max_y {
            continue;
        }

        for y in min_y..=max_y {
            let dy = y - center_y;
            let row_offset = (y as usize) * w;
            for x in min_x..=max_x {
                let dx = x - center_x;
                let dist_sq = dx * dx + dy * dy;
                if dist_sq <= radius_sq {
                    let dist = (dist_sq as f32).sqrt();
                    let lut_idx = (dist as usize).min(radius as usize);
                    let falloff = lut[lut_idx];
                    let idx = row_offset + (x as usize);
                    let current = data[idx] as f32;
                    if is_erasing {
                        let erase_amount = max_mask * falloff;
                        data[idx] = (current - erase_amount).max(0.0) as u8;
                    } else {
                        let strength = value_f * falloff;
                        let new_val = current.max(strength);
                        data[idx] = new_val.min(max_mask) as u8;
                    }
                }
            }
        }
    }

}

/// マスクをクリア（全 0）
pub fn clear(data: &mut [u8]) {
    for v in data.iter_mut() {
        *v = 0;
    }
}

/// マスクを反転（255 - x）
pub fn invert(data: &mut [u8]) {
    for v in data.iter_mut() {
        *v = 255u8.wrapping_sub(*v);
    }
}

/// 軸平行矩形を一様に塗る
pub fn fill_axis_aligned_rect(
    data: &mut [u8],
    width: i32,
    height: i32,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    value: u8,
) {
    if width <= 0 || height <= 0 {
        return;
    }
    let w = width as usize;
    if data.len() != w * (height as usize) {
        return;
    }

    let min_x = x0.min(x1).floor() as i32;
    let max_x = x0.max(x1).ceil() as i32;
    let min_y = y0.min(y1).floor() as i32;
    let max_y = y0.max(y1).ceil() as i32;

    let min_x = min_x.max(0).min(width - 1);
    let max_x = max_x.max(0).min(width - 1);
    let min_y = min_y.max(0).min(height - 1);
    let max_y = max_y.max(0).min(height - 1);
    if min_x > max_x || min_y > max_y {
        return;
    }

    for y in min_y..=max_y {
        let row = (y as usize) * w;
        for x in min_x..=max_x {
            data[row + (x as usize)] = value;
        }
    }
}

/// 単純な分離型ボックスブラー（半径 r、ピクセル数値で繰り返さず一回適用）
/// - vImage の Tent Convolve に近い見た目だが、同等性は要求しない（互換挙動より速度優先）
pub fn box_blur(data: &mut [u8], width: i32, height: i32, radius: i32) {
    if radius <= 0 || width <= 0 || height <= 0 {
        return;
    }
    let w = width as usize;
    let h = height as usize;
    if data.len() != w * h {
        return;
    }

    let r = radius as usize;
    let kernel_size = (r * 2 + 1) as f32;

    // 横方向パス
    let mut tmp: Vec<u8> = vec![0; w * h];
    for y in 0..h {
        let row = y * w;
        for x in 0..w {
            let xs = x.saturating_sub(r);
            let xe = (x + r).min(w - 1);
            let mut sum: u32 = 0;
            let mut count: u32 = 0;
            for ix in xs..=xe {
                sum += data[row + ix] as u32;
                count += 1;
            }
            tmp[row + x] = (sum / count.max(1)) as u8;
            // 平均カーネルサイズ調整は端で count が変わることで担保
            let _ = kernel_size;
        }
    }

    // 縦方向パス
    for y in 0..h {
        for x in 0..w {
            let ys = y.saturating_sub(r);
            let ye = (y + r).min(h - 1);
            let mut sum: u32 = 0;
            let mut count: u32 = 0;
            for iy in ys..=ye {
                sum += tmp[iy * w + x] as u32;
                count += 1;
            }
            data[y * w + x] = (sum / count.max(1)) as u8;
        }
    }
}

// --- 内部 ----------------------------------------------------------------

fn build_falloff_lut(radius: i32, softness: f32) -> Vec<f32> {
    let r = radius.max(1) as usize;
    let radius_f = radius as f32;
    let clamped_softness = softness.max(0.01);
    let inv_soft = 1.0 / clamped_softness;
    let mut lut = vec![0.0f32; r + 1];
    for d in 0..=r {
        let dist = (d as f32) / radius_f;
        let v = (1.0 - dist.powf(inv_soft)).max(0.0);
        lut[d] = v;
    }
    lut
}
