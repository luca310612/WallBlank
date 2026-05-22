//! マグネットペン（色近傍）選択マスク — 元は `ImageEditorManager.computeMagneticSelectionMaskFromRGBA` と同等のロジック

const TARGET_PIXELS: f64 = 1_500_000.0;

/// `tolerance_01` は 0…1（Swift と同様）。RGB は 0…1 に正規化して距離の二乗と比較する。
pub fn magnetic_selection_mask(
    rgba: &[u8],
    width: usize,
    height: usize,
    seeds_xy: &[(f32, f32)],
    tolerance_01: f32,
    combine_mode: u32,
    existing: Option<&[u8]>,
) -> Option<Vec<u8>> {
    if seeds_xy.is_empty() || width == 0 || height == 0 {
        return None;
    }
    let pixel_count = width.checked_mul(height)?;
    let rgba_need = pixel_count.checked_mul(4)?;
    if rgba.len() < rgba_need {
        return None;
    }

    let w = width as i32;
    let h = height as i32;

    let factor_d = ((width * height) as f64 / TARGET_PIXELS).sqrt().max(1.0);
    let factor = factor_d.ceil() as i32;
    let factor = factor.max(1);

    let dw = (w / factor).max(1) as usize;
    let dh = (h / factor).max(1) as usize;

    let tol = tolerance_01.clamp(0.001, 1.0);
    let tol2 = tol * tol * 3.0;

    let to_down = |px: f32, py: f32| -> Option<(usize, usize)> {
        let x = px.round() as i32;
        let y = py.round() as i32;
        if x < 0 || x >= w || y < 0 || y >= h {
            return None;
        }
        let dx = ((x / factor) as usize).min(dw.saturating_sub(1));
        let dy = ((y / factor) as usize).min(dh.saturating_sub(1));
        Some((dx, dy))
    };

    #[inline]
    fn pixel01(bytes: &[u8], w: usize, h: usize, factor: i32, dx: usize, dy: usize) -> (f32, f32, f32) {
        let x = ((dx as i32 * factor).min(w as i32 - 1)).max(0) as usize;
        let y = ((dy as i32 * factor).min(h as i32 - 1)).max(0) as usize;
        let idx = (y * w + x) * 4;
        let r = bytes[idx] as f32 / 255.0;
        let g = bytes[idx + 1] as f32 / 255.0;
        let b = bytes[idx + 2] as f32 / 255.0;
        (r, g, b)
    }

    let mut selected_down = vec![0u8; dw * dh];
    // Swift と同様: visited はシード間で共有（既訪セルは再キューしない）
    let mut visited = vec![0u8; dw * dh];
    let mut queue_x: Vec<usize> = Vec::with_capacity(4096);
    let mut queue_y: Vec<usize> = Vec::with_capacity(4096);

    let push = |qx: usize, qy: usize, visited: &mut [u8], qx_vec: &mut Vec<usize>, qy_vec: &mut Vec<usize>| {
        let i = qy * dw + qx;
        if visited[i] != 0 {
            return;
        }
        visited[i] = 1;
        qx_vec.push(qx);
        qy_vec.push(qy);
    };

    for &(sx, sy) in seeds_xy {
        let Some((seed_dx, seed_dy)) = to_down(sx, sy) else {
            continue;
        };
        let (sr, sg, sb) = pixel01(rgba, width, height, factor, seed_dx, seed_dy);

        queue_x.clear();
        queue_y.clear();
        push(seed_dx, seed_dy, &mut visited, &mut queue_x, &mut queue_y);

        let mut qi = 0usize;
        while qi < queue_x.len() {
            let x = queue_x[qi];
            let y = queue_y[qi];
            qi += 1;

            let (r, g, b) = pixel01(rgba, width, height, factor, x, y);
            let dr = r - sr;
            let dg = g - sg;
            let db = b - sb;
            let dist2 = dr * dr + dg * dg + db * db;
            if dist2 <= tol2 {
                selected_down[y * dw + x] = 255;
                if x > 0 {
                    push(x - 1, y, &mut visited, &mut queue_x, &mut queue_y);
                }
                if x + 1 < dw {
                    push(x + 1, y, &mut visited, &mut queue_x, &mut queue_y);
                }
                if y > 0 {
                    push(x, y - 1, &mut visited, &mut queue_x, &mut queue_y);
                }
                if y + 1 < dh {
                    push(x, y + 1, &mut visited, &mut queue_x, &mut queue_y);
                }
            }
        }
    }

    let mut out = vec![0u8; pixel_count];
    for y in 0..height {
        let dy = (y as i32 / factor).min(dh as i32 - 1).max(0) as usize;
        for x in 0..width {
            let dx = (x as i32 / factor).min(dw as i32 - 1).max(0) as usize;
            out[y * width + x] = selected_down[dy * dw + dx];
        }
    }

    let new_mask = out;

    let existing_ok = existing
        .filter(|e| e.len() == pixel_count)
        .map(|e| e.as_ref());

    let Some(ex) = existing_ok else {
        return Some(new_mask);
    };

    let mut eff_combine = combine_mode.min(3);
    if eff_combine == 0 && ex.iter().any(|&v| v > 0) {
        eff_combine = 1;
    }

    let merged = match eff_combine {
        0 => new_mask,
        1 => merge_add(ex, &new_mask),
        2 => merge_multiply(ex, &new_mask),
        3 => merge_difference(ex, &new_mask),
        _ => new_mask,
    };

    Some(merged)
}

fn merge_add(existing: &[u8], new: &[u8]) -> Vec<u8> {
    let mut merged = new.to_vec();
    for i in 0..merged.len() {
        let e = existing[i] as f32 / 255.0;
        let s = new[i] as f32 / 255.0;
        let v = e + (1.0 - e) * s;
        merged[i] = (v * 255.0).round().clamp(0.0, 255.0) as u8;
    }
    merged
}

fn merge_multiply(existing: &[u8], new: &[u8]) -> Vec<u8> {
    let mut merged = new.to_vec();
    for i in 0..merged.len() {
        let v = (existing[i] as f32 / 255.0) * (new[i] as f32 / 255.0);
        merged[i] = (v * 255.0).round().clamp(0.0, 255.0) as u8;
    }
    merged
}

fn merge_difference(existing: &[u8], new: &[u8]) -> Vec<u8> {
    let mut merged = new.to_vec();
    for i in 0..merged.len() {
        let v = ((existing[i] as f32 / 255.0) - (new[i] as f32 / 255.0)).abs();
        merged[i] = (v * 255.0).round().clamp(0.0, 255.0) as u8;
    }
    merged
}

/// 選択マスクを RGBA に適用（アルファのみ変更）。`keep_inside`: true = マスク外を透明、false = マスク内を透明。
pub fn rgba_apply_selection_mask(
    rgba: &[u8],
    width: usize,
    height: usize,
    mask: &[u8],
    keep_inside: bool,
) -> Option<Vec<u8>> {
    let pixel_count = width.checked_mul(height)?;
    let need = pixel_count.checked_mul(4)?;
    if rgba.len() < need || mask.len() < pixel_count {
        return None;
    }
    let mut out = rgba[..need].to_vec();
    for i in 0..pixel_count {
        let m = mask[i];
        let base = i * 4;
        if keep_inside {
            if m == 0 {
                out[base + 3] = 0;
            }
        } else if m != 0 {
            out[base + 3] = 0;
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn magnetic_uniform_color_selects_all() {
        // 4x4 すべて赤
        let mut rgba = vec![255u8; 4 * 4 * 4];
        for p in 0..16 {
            let i = p * 4;
            rgba[i] = 200;
            rgba[i + 1] = 10;
            rgba[i + 2] = 10;
            rgba[i + 3] = 255;
        }
        let seeds = [(1.0_f32, 1.0)];
        let mask = magnetic_selection_mask(&rgba, 4, 4, &seeds, 0.5, 0, None).expect("mask");
        assert_eq!(mask.len(), 16);
        assert!(mask.iter().all(|&v| v == 255));
    }

    #[test]
    fn rgba_apply_keep_inside() {
        let rgba = vec![
            255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 128, 128, 128, 255,
        ];
        let mask = vec![255u8, 0, 0, 255];
        let out = rgba_apply_selection_mask(&rgba, 2, 2, &mask, true).unwrap();
        assert_eq!(out[3], 255);
        assert_eq!(out[7], 0);
        assert_eq!(out[11], 0);
        assert_eq!(out[15], 255);
    }
}
