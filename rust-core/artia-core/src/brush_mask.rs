//! 自由ペン軌跡から選択マスク（グレースケール 0…1）をラスタ化する。
//! Swift `BrushMaskRasterizer` と同じ数式・手順（部分矩形最適化含む）。

use rand::Rng;

#[derive(Clone, Copy, Debug)]
pub struct BrushStrokeParams {
    pub radius: f64,
    pub hardness: f64,
    pub opacity: f32,
    pub flow: f32,
    pub smoothing_percent: f64,
    /// 0 = normal, 1 = add, 2 = subtract
    pub paint_mode: u8,
}

#[derive(Clone, Copy, Debug)]
pub struct MaskPostParams {
    pub post_blur_radius: f64,
    pub edge_adjust_pixels: i32,
    pub levels_in_black: f64,
    pub levels_in_white: f64,
    pub levels_out_black: f64,
    pub levels_out_white: f64,
    pub noise_amount: f64,
}

#[derive(Clone, Copy, Debug)]
pub struct GradientParams {
    /// 0 none, 1 linear_vertical, 2 linear_horizontal, 3 radial
    pub kind: u8,
    pub strength: f64,
}

/// `combine_mode`: 0 replace, 1 add, 2 multiply, 3 difference
pub fn rasterize_brush_trace(
    points: &[(f32, f32)],
    width: i32,
    height: i32,
    stroke: BrushStrokeParams,
    post: MaskPostParams,
    gradient: GradientParams,
    combine_mode: u32,
    existing: Option<&[u8]>,
) -> Option<Vec<u8>> {
    let w = width as usize;
    let h = height as usize;
    if w == 0 || h == 0 {
        return None;
    }
    let full_len = w.checked_mul(h)?;
    let pts_f64: Vec<(f64, f64)> = points.iter().map(|&(x, y)| (x as f64, y as f64)).collect();
    let smoothed = smooth_brush_points(&pts_f64, stroke.smoothing_percent);
    if smoothed.len() < 2 {
        return None;
    }

    let mut combine_resolved = combine_mode;
    if combine_resolved == 0 {
        if let Some(ex) = existing {
            if ex.len() == full_len && ex.iter().any(|&b| b > 0) {
                combine_resolved = 1;
            }
        }
    }

    let radius = stroke.radius.max(0.05);
    let hardness = stroke.hardness.clamp(0.0, 1.0);
    let opacity = stroke.opacity.clamp(0.0, 1.0);
    let flow = stroke.flow.clamp(0.1, 1.0);
    let step = (radius * 0.35).max(0.5);

    let centers = build_centers(&smoothed, step);
    let c0 = *centers.first()?;
    let (mut min_x, mut max_x, mut min_y, mut max_y) = (c0.0, c0.0, c0.1, c0.1);
    for &(x, y) in centers.iter().skip(1) {
        min_x = min_x.min(x);
        max_x = max_x.max(x);
        min_y = min_y.min(y);
        max_y = max_y.max(y);
    }

    let blur_passes = post.post_blur_radius.round().clamp(0.0, 32.0) as i32;
    let edge_steps = post.edge_adjust_pixels.abs();
    let disc_pad = radius.ceil() as i32 + 2;
    let pad = disc_pad + blur_passes + edge_steps as i32 + 4;
    let ix0 = (min_x.floor() as i32 - pad).max(0);
    let iy0 = (min_y.floor() as i32 - pad).max(0);
    let ix1 = (max_x.ceil() as i32 + pad).min(width);
    let iy1 = (max_y.ceil() as i32 + pad).min(height);
    let rw = (ix1 - ix0).max(1) as usize;
    let rh = (iy1 - iy0).max(1) as usize;
    let full_area = full_len;
    let sub_area = rw * rh;
    let use_sub_rect = sub_area * 20 < full_area * 19;

    if use_sub_rect {
        rasterize_sub_rect(
            w,
            h,
            ix0 as usize,
            iy0 as usize,
            rw,
            rh,
            &centers,
            radius,
            hardness,
            opacity,
            flow,
            stroke.paint_mode,
            post,
            gradient,
            combine_resolved,
            existing,
        )
    } else {
        rasterize_full_canvas(
            w,
            h,
            &centers,
            radius,
            hardness,
            opacity,
            flow,
            stroke.paint_mode,
            post,
            gradient,
            combine_resolved,
            existing,
        )
    }
}

fn smooth_brush_points(points: &[(f64, f64)], smoothing_percent: f64) -> Vec<(f64, f64)> {
    if points.len() < 3 {
        return points.to_vec();
    }
    let t = smoothing_percent / 100.0;
    if t <= 0.02 {
        return points.to_vec();
    }
    let iterations = ((t * 4.0).round() as usize).clamp(1, 4);
    let mut pts = points.to_vec();
    for _ in 0..iterations {
        pts = chaikin_smooth(&pts);
    }
    pts
}

fn chaikin_smooth(pts: &[(f64, f64)]) -> Vec<(f64, f64)> {
    if pts.len() < 2 {
        return pts.to_vec();
    }
    if pts.len() == 2 {
        return pts.to_vec();
    }
    let mut out = Vec::with_capacity(pts.len() * 2);
    out.push(pts[0]);
    for i in 0..pts.len() - 1 {
        let p0 = pts[i];
        let p1 = pts[i + 1];
        out.push((
            0.75 * p0.0 + 0.25 * p1.0,
            0.75 * p0.1 + 0.25 * p1.1,
        ));
        out.push((
            0.25 * p0.0 + 0.75 * p1.0,
            0.25 * p0.1 + 0.75 * p1.1,
        ));
    }
    out.push(pts[pts.len() - 1]);
    out
}

fn build_centers(smoothed: &[(f64, f64)], step: f64) -> Vec<(f64, f64)> {
    let mut centers = Vec::new();
    for i in 0..smoothed.len() - 1 {
        let a = smoothed[i];
        let b = smoothed[i + 1];
        let dist = hypot(b.0 - a.0, b.1 - a.1);
        let n = ((dist / step).ceil() as usize).max(1);
        for k in 0..n {
            let t = k as f64 / n as f64;
            centers.push((a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t));
        }
    }
    centers.push(smoothed[smoothed.len() - 1]);
    centers
}

fn hypot(dx: f64, dy: f64) -> f64 {
    (dx * dx + dy * dy).sqrt()
}

fn rasterize_full_canvas(
    width: usize,
    height: usize,
    centers: &[(f64, f64)],
    radius: f64,
    hardness: f64,
    opacity: f32,
    flow: f32,
    paint_mode: u8,
    post: MaskPostParams,
    gradient: GradientParams,
    combine_resolved: u32,
    existing_mask: Option<&[u8]>,
) -> Option<Vec<u8>> {
    let len = width * height;
    let mut existing = vec![0f32; len];
    if let Some(ex) = existing_mask {
        if ex.len() == len {
            for i in 0..len {
                existing[i] = ex[i] as f32 / 255.0;
            }
        }
    }
    let mut stroke_layer = vec![0f32; len];
    let mut last = centers[0];
    for &c in centers {
        stamp_line_segment(
            last,
            c,
            radius,
            hardness,
            opacity,
            flow,
            width,
            height,
            &mut stroke_layer,
        );
        last = c;
    }

    apply_gradient_multiply(
        &mut stroke_layer,
        width,
        height,
        gradient,
        width,
        height,
        0,
        0,
    );
    apply_post_blur(&mut stroke_layer, width, height, post.post_blur_radius);
    apply_edge_adjust(
        &mut stroke_layer,
        width,
        height,
        post.edge_adjust_pixels,
    );
    apply_levels(
        &mut stroke_layer,
        post.levels_in_black as f32,
        post.levels_in_white as f32,
        post.levels_out_black as f32,
        post.levels_out_white as f32,
    );
    let mut rng = rand::thread_rng();
    apply_noise(
        &mut stroke_layer,
        post.noise_amount as f32,
        &mut rng,
    );

    let acc: Vec<f32> = match combine_resolved {
        0 => stroke_layer,
        1 => existing
            .iter()
            .zip(stroke_layer.iter())
            .map(|(&e, &s)| merge_paint_onto(e, s, paint_mode))
            .collect(),
        2 => existing
            .iter()
            .zip(stroke_layer.iter())
            .map(|(&e, &s)| e * s)
            .collect(),
        3 => existing
            .iter()
            .zip(stroke_layer.iter())
            .map(|(&e, &s)| (e - s).abs())
            .collect(),
        _ => return None,
    };

    let mut bytes = vec![0u8; len];
    for i in 0..len {
        bytes[i] = (acc[i] * 255.0).round().clamp(0.0, 255.0) as u8;
    }
    Some(bytes)
}

#[allow(clippy::too_many_arguments)]
fn rasterize_sub_rect(
    canvas_w: usize,
    canvas_h: usize,
    ox: usize,
    oy: usize,
    rw: usize,
    rh: usize,
    centers: &[(f64, f64)],
    radius: f64,
    hardness: f64,
    opacity: f32,
    flow: f32,
    paint_mode: u8,
    post: MaskPostParams,
    gradient: GradientParams,
    combine_resolved: u32,
    existing_mask: Option<&[u8]>,
) -> Option<Vec<u8>> {
    let full_len = canvas_w * canvas_h;
    let n = rw * rh;
    let mut existing_sub = vec![0f32; n];
    if let Some(ex) = existing_mask {
        if ex.len() == full_len {
            for y in 0..rh {
                let sy = y + oy;
                let base = sy * canvas_w + ox;
                for x in 0..rw {
                    existing_sub[y * rw + x] = ex[base + x] as f32 / 255.0;
                }
            }
        }
    }

    let mut stroke_layer = vec![0f32; n];
    let ox_f = ox as f64;
    let oy_f = oy as f64;
    let mut last = (centers[0].0 - ox_f, centers[0].1 - oy_f);
    for &c in centers {
        let lc = (c.0 - ox_f, c.1 - oy_f);
        stamp_line_segment(
            last,
            lc,
            radius,
            hardness,
            opacity,
            flow,
            rw,
            rh,
            &mut stroke_layer,
        );
        last = lc;
    }

    apply_gradient_multiply(
        &mut stroke_layer,
        rw,
        rh,
        gradient,
        canvas_w,
        canvas_h,
        ox as i32,
        oy as i32,
    );
    apply_post_blur(&mut stroke_layer, rw, rh, post.post_blur_radius);
    apply_edge_adjust(&mut stroke_layer, rw, rh, post.edge_adjust_pixels);
    apply_levels(
        &mut stroke_layer,
        post.levels_in_black as f32,
        post.levels_in_white as f32,
        post.levels_out_black as f32,
        post.levels_out_white as f32,
    );
    let mut rng = rand::thread_rng();
    apply_noise(
        &mut stroke_layer,
        post.noise_amount as f32,
        &mut rng,
    );

    let acc: Vec<f32> = match combine_resolved {
        0 => stroke_layer,
        1 => existing_sub
            .iter()
            .zip(stroke_layer.iter())
            .map(|(&e, &s)| merge_paint_onto(e, s, paint_mode))
            .collect(),
        2 => existing_sub
            .iter()
            .zip(stroke_layer.iter())
            .map(|(&e, &s)| e * s)
            .collect(),
        3 => existing_sub
            .iter()
            .zip(stroke_layer.iter())
            .map(|(&e, &s)| (e - s).abs())
            .collect(),
        _ => return None,
    };

    match combine_resolved {
        0 => {
            let mut bytes = vec![0u8; full_len];
            for y in 0..rh {
                for x in 0..rw {
                    let v = (acc[y * rw + x] * 255.0).round().clamp(0.0, 255.0) as u8;
                    bytes[(y + oy) * canvas_w + (x + ox)] = v;
                }
            }
            Some(bytes)
        }
        1 | 2 | 3 => {
            let mut bytes: Vec<u8> = if let Some(ex) = existing_mask {
                if ex.len() == full_len {
                    ex.to_vec()
                } else {
                    vec![0u8; full_len]
                }
            } else {
                vec![0u8; full_len]
            };
            for y in 0..rh {
                for x in 0..rw {
                    let fi = (y + oy) * canvas_w + (x + ox);
                    let si = y * rw + x;
                    bytes[fi] = (acc[si] * 255.0).round().clamp(0.0, 255.0) as u8;
                }
            }
            Some(bytes)
        }
        _ => None,
    }
}

fn merge_paint_onto(existing: f32, stroke: f32, mode: u8) -> f32 {
    match mode {
        0 => existing + (1.0 - existing) * stroke,
        1 => (existing + stroke).min(1.0),
        2 => (existing - stroke).max(0.0),
        _ => existing + (1.0 - existing) * stroke,
    }
}

fn stamp_line_segment(
    from: (f64, f64),
    to: (f64, f64),
    radius: f64,
    hardness: f64,
    opacity: f32,
    flow: f32,
    width: usize,
    height: usize,
    buffer: &mut [f32],
) {
    let dist = hypot(to.0 - from.0, to.1 - from.1);
    let sub = ((dist / (radius * 0.4).max(0.5)).ceil() as i32).max(1) as usize;
    for k in 0..=sub {
        let t = k as f64 / sub as f64;
        let cx = from.0 + (to.0 - from.0) * t;
        let cy = from.1 + (to.1 - from.1) * t;
        stamp_disc(
            cx,
            cy,
            radius,
            hardness,
            opacity,
            flow,
            width,
            height,
            buffer,
        );
    }
}

fn stamp_disc(
    cx: f64,
    cy: f64,
    radius: f64,
    hardness: f64,
    opacity: f32,
    flow: f32,
    width: usize,
    height: usize,
    buffer: &mut [f32],
) {
    let r = radius.ceil() as i32 + 1;
    let ix = cx.floor() as i32;
    let iy = cy.floor() as i32;
    let inner = radius * hardness.max(0.001);
    let edge = (radius - inner).max(0.5);

    for dy in -r..=r {
        for dx in -r..=r {
            let px = ix + dx;
            let py = iy + dy;
            if px < 0 || py < 0 {
                continue;
            }
            let px = px as usize;
            let py = py as usize;
            if px >= width || py >= height {
                continue;
            }
            let fx = px as f64 + 0.5;
            let fy = py as f64 + 0.5;
            let d = hypot(fx - cx, fy - cy);
            if d > radius {
                continue;
            }

            let radial = if d <= inner {
                1.0f32
            } else {
                let u = ((radius - d) / edge) as f32;
                u.clamp(0.0, 1.0)
            };
            let src = radial * opacity * flow;
            if src <= 0.0001 {
                continue;
            }

            let idx = py * width + px;
            let dst = buffer[idx];
            buffer[idx] = dst + (1.0 - dst) * src;
        }
    }
}

fn apply_gradient_multiply(
    buffer: &mut [f32],
    width: usize,
    height: usize,
    settings: GradientParams,
    full_cw: usize,
    full_ch: usize,
    origin_x: i32,
    origin_y: i32,
) {
    if settings.kind == 0 || settings.strength <= 0.001 {
        return;
    }
    let s = settings.strength.clamp(0.0, 1.0) as f32;
    let cw = full_cw.max(1);
    let ch = full_ch.max(1);
    for y in 0..height {
        for x in 0..width {
            let idx = y * width + x;
            let gx = x as i32 + origin_x;
            let gy = y as i32 + origin_y;
            let g = match settings.kind {
                1 => gy as f32 / (ch.saturating_sub(1).max(1)) as f32,
                2 => gx as f32 / (cw.saturating_sub(1).max(1)) as f32,
                3 => {
                    let nx = (gx as f32 / cw as f32) - 0.5;
                    let ny = (gy as f32 / ch as f32) - 0.5;
                    1.0 - ((nx * nx + ny * ny).sqrt() * 2.0).min(1.0)
                }
                _ => 1.0f32,
            };
            let m = 1.0 - s + s * g;
            buffer[idx] *= m;
        }
    }
}

fn apply_post_blur(buffer: &mut [f32], width: usize, height: usize, radius: f64) {
    let passes = radius.round().clamp(0.0, 32.0) as i32;
    if passes <= 0 {
        return;
    }
    for _ in 0..passes {
        box_blur_horizontal(buffer, width, height, 1);
        box_blur_vertical(buffer, width, height, 1);
    }
}

fn box_blur_horizontal(buffer: &mut [f32], width: usize, height: usize, r: i32) {
    let mut tmp = buffer.to_vec();
    for y in 0..height {
        for x in 0..width {
            let mut sum = 0f32;
            let mut count = 0f32;
            for dx in -r..=r {
                let nx = x as i32 + dx;
                if nx >= 0 && (nx as usize) < width {
                    sum += buffer[y * width + nx as usize];
                    count += 1.0;
                }
            }
            tmp[y * width + x] = sum / count.max(1.0);
        }
    }
    buffer.copy_from_slice(&tmp);
}

fn box_blur_vertical(buffer: &mut [f32], width: usize, height: usize, r: i32) {
    let mut tmp = buffer.to_vec();
    for y in 0..height {
        for x in 0..width {
            let mut sum = 0f32;
            let mut count = 0f32;
            for dy in -r..=r {
                let ny = y as i32 + dy;
                if ny >= 0 && (ny as usize) < height {
                    sum += buffer[ny as usize * width + x];
                    count += 1.0;
                }
            }
            tmp[y * width + x] = sum / count.max(1.0);
        }
    }
    buffer.copy_from_slice(&tmp);
}

fn apply_edge_adjust(buffer: &mut [f32], width: usize, height: usize, delta: i32) {
    if delta == 0 {
        return;
    }
    let steps = delta.unsigned_abs() as usize;
    let dilate = delta > 0;
    for _ in 0..steps {
        morph_step(buffer, width, height, dilate);
    }
}

fn morph_step(buffer: &mut [f32], width: usize, height: usize, dilate: bool) {
    let src = buffer.to_vec();
    for y in 0..height {
        for x in 0..width {
            let idx = y * width + x;
            let mut v = src[idx];
            for dy in -1i32..=1 {
                for dx in -1i32..=1 {
                    let nx = x as i32 + dx;
                    let ny = y as i32 + dy;
                    if nx < 0 || ny < 0 {
                        continue;
                    }
                    let nx = nx as usize;
                    let ny = ny as usize;
                    if nx >= width || ny >= height {
                        continue;
                    }
                    let nv = src[ny * width + nx];
                    if dilate {
                        v = v.max(nv);
                    } else {
                        v = v.min(nv);
                    }
                }
            }
            buffer[idx] = v;
        }
    }
}

fn apply_levels(
    buffer: &mut [f32],
    in_black: f32,
    in_white: f32,
    out_black: f32,
    out_white: f32,
) {
    let ib = in_black.clamp(0.0, 254.0);
    let iw = in_white.clamp(ib + 1.0, 255.0);
    let ob = out_black.clamp(0.0, 255.0);
    let ow = out_white.clamp(ob, 255.0);
    let scale = (ow - ob) / (iw - ib);
    for v in buffer.iter_mut() {
        let x = *v * 255.0;
        let t = (x - ib) / (iw - ib);
        let u = t.clamp(0.0, 1.0);
        *v = (ob + u * scale) / 255.0;
    }
}

fn apply_noise(buffer: &mut [f32], amount: f32, rng: &mut impl Rng) {
    if amount <= 0.0001 {
        return;
    }
    for v in buffer.iter_mut() {
        let n = rng.gen_range(-1.0f32..1.0f32) * amount * 0.25;
        *v = (*v + n).clamp(0.0, 1.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tiny_stroke_produces_some_alpha() {
        let pts = vec![(10.0f32, 10.0f32), (20.0f32, 12.0f32)];
        let stroke = BrushStrokeParams {
            radius: 8.0,
            hardness: 0.8,
            opacity: 1.0,
            flow: 1.0,
            smoothing_percent: 0.0,
            paint_mode: 0,
        };
        let post = MaskPostParams {
            post_blur_radius: 0.0,
            edge_adjust_pixels: 0,
            levels_in_black: 0.0,
            levels_in_white: 255.0,
            levels_out_black: 0.0,
            levels_out_white: 255.0,
            noise_amount: 0.0,
        };
        let grad = GradientParams {
            kind: 0,
            strength: 0.0,
        };
        let out = rasterize_brush_trace(&pts, 64, 64, stroke, post, grad, 0, None).unwrap();
        assert!(out.iter().any(|&b| b > 0));
    }
}
