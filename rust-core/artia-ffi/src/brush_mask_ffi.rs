//! ブラシマスクラスタ化の C FFI

use artia_core::brush_mask::{
    rasterize_brush_trace, BrushStrokeParams, GradientParams, MaskPostParams,
};

/// Swift / C から渡すブラシ・マスクパラメータ（`BrushMaskRasterizer` と対応）
#[repr(C)]
#[derive(Clone, Copy)]
pub struct ArtiaBrushMaskRasterParams {
    pub radius: f32,
    pub hardness: f32,
    pub opacity: f32,
    pub flow: f32,
    pub smoothing_percent: f32,
    /// 0 normal, 1 add, 2 subtract
    pub paint_mode: u32,
    pub post_blur_radius: f64,
    pub edge_adjust_pixels: i32,
    pub levels_in_black: f64,
    pub levels_in_white: f64,
    pub levels_out_black: f64,
    pub levels_out_white: f64,
    pub noise_amount: f64,
    /// 0 none, 1 linear_vertical, 2 linear_horizontal, 3 radial
    pub gradient_kind: u32,
    pub gradient_strength: f64,
    /// 0 replace, 1 add, 2 multiply, 3 difference
    pub combine_mode: u32,
}

/// 軌跡点を interleaved `[x0,y0,x1,y1,...]` で渡す。
/// 成功時: `width*height` バイトのマスク（呼び出し側が `artia_free_bytes` で解放）
/// 失敗時: null、`out_len` は 0
#[unsafe(no_mangle)]
pub extern "C" fn artia_brush_rasterize_mask(
    points_xy: *const f32,
    point_count: u32,
    width: i32,
    height: i32,
    params: *const ArtiaBrushMaskRasterParams,
    existing: *const u8,
    existing_len: u32,
    out_len: *mut u32,
) -> *mut u8 {
    if out_len.is_null() {
        return std::ptr::null_mut();
    }
    unsafe {
        *out_len = 0;
    }
    if points_xy.is_null() || params.is_null() || point_count < 2 || width <= 0 || height <= 0 {
        return std::ptr::null_mut();
    }
    let w = width as usize;
    let h = height as usize;
    let expected = match w.checked_mul(h) {
        Some(n) => n,
        None => return std::ptr::null_mut(),
    };
    if existing_len != 0 && existing_len as usize != expected {
        return std::ptr::null_mut();
    }

    let p = unsafe { *params };
    let n = point_count as usize;
    let pts: Vec<(f32, f32)> = unsafe {
        std::slice::from_raw_parts(points_xy, n * 2)
            .chunks_exact(2)
            .map(|c| (c[0], c[1]))
            .collect()
    };
    if pts.len() < 2 {
        return std::ptr::null_mut();
    }

    let existing_slice: Option<&[u8]> = if existing.is_null() || existing_len == 0 {
        None
    } else {
        Some(unsafe { std::slice::from_raw_parts(existing, existing_len as usize) })
    };

    let stroke = BrushStrokeParams {
        radius: p.radius as f64,
        hardness: p.hardness as f64,
        opacity: p.opacity,
        flow: p.flow,
        smoothing_percent: p.smoothing_percent as f64,
        paint_mode: (p.paint_mode.min(2)) as u8,
    };
    let post = MaskPostParams {
        post_blur_radius: p.post_blur_radius,
        edge_adjust_pixels: p.edge_adjust_pixels,
        levels_in_black: p.levels_in_black,
        levels_in_white: p.levels_in_white,
        levels_out_black: p.levels_out_black,
        levels_out_white: p.levels_out_white,
        noise_amount: p.noise_amount,
    };
    let gradient = GradientParams {
        kind: p.gradient_kind.min(3) as u8,
        strength: p.gradient_strength,
    };

    let combine = p.combine_mode.min(3);
    let Some(data) = rasterize_brush_trace(
        &pts,
        width,
        height,
        stroke,
        post,
        gradient,
        combine,
        existing_slice,
    ) else {
        return std::ptr::null_mut();
    };
    if data.len() != expected {
        return std::ptr::null_mut();
    }

    let mut boxed = data.into_boxed_slice();
    let ptr = boxed.as_mut_ptr();
    let len = boxed.len();
    std::mem::forget(boxed);
    unsafe {
        *out_len = len as u32;
    }
    ptr
}
