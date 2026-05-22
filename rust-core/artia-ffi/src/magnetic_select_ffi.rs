//! マグネット選択・RGBAマスク適用の C FFI

use artia_core::magnetic_select::{magnetic_selection_mask, rgba_apply_selection_mask};

/// 合成 RGBA からマグネット選択マスクを生成する。
/// `seeds_xy`: キャンバス座標の `[x0,y0,x1,y1,…]`。成功時 `width*height` バイト（`artia_free_bytes`）
#[unsafe(no_mangle)]
pub extern "C" fn artia_magnetic_selection_mask(
    rgba: *const u8,
    rgba_len: u32,
    width: i32,
    height: i32,
    seeds_xy: *const f32,
    seed_count: u32,
    tolerance_01: f32,
    // combine_mode: 0 replace, 1 add, 2 multiply, 3 difference（BrushMaskRasterizer と同じ）
    combine_mode: u32,
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
    if rgba.is_null() || seeds_xy.is_null() || seed_count == 0 || width <= 0 || height <= 0 {
        return std::ptr::null_mut();
    }
    let w = width as usize;
    let h = height as usize;
    let expected = match w.checked_mul(h) {
        Some(n) => n,
        None => return std::ptr::null_mut(),
    };
    let rgba_need = match expected.checked_mul(4) {
        Some(n) => n,
        None => return std::ptr::null_mut(),
    };
    if rgba_len as usize != rgba_need {
        return std::ptr::null_mut();
    }
    if existing_len != 0 && existing_len as usize != expected {
        return std::ptr::null_mut();
    }

    let rgba_slice = unsafe { std::slice::from_raw_parts(rgba, rgba_len as usize) };
    let n = seed_count as usize;
    let seeds_flat = unsafe { std::slice::from_raw_parts(seeds_xy, n * 2) };
    let seeds: Vec<(f32, f32)> = seeds_flat
        .chunks_exact(2)
        .map(|c| (c[0], c[1]))
        .collect();
    if seeds.len() != n {
        return std::ptr::null_mut();
    }

    let existing_slice: Option<&[u8]> = if existing.is_null() || existing_len == 0 {
        None
    } else {
        Some(unsafe { std::slice::from_raw_parts(existing, existing_len as usize) })
    };

    let Some(data) = magnetic_selection_mask(
        rgba_slice,
        w,
        h,
        &seeds,
        tolerance_01,
        combine_mode,
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

/// 選択マスクを RGBA に適用（アルファのみ変更）。
/// `mode`: 0 = マスク外を透明（keep inside）, 1 = マスク内を透明（clear inside）
#[unsafe(no_mangle)]
pub extern "C" fn artia_rgba_apply_selection_mask(
    rgba: *const u8,
    rgba_len: u32,
    width: i32,
    height: i32,
    mask: *const u8,
    mask_len: u32,
    // mode: 0 = keep_inside, 1 = clear_inside
    mode: u32,
    out_len: *mut u32,
) -> *mut u8 {
    if out_len.is_null() {
        return std::ptr::null_mut();
    }
    unsafe {
        *out_len = 0;
    }
    if rgba.is_null() || mask.is_null() || width <= 0 || height <= 0 {
        return std::ptr::null_mut();
    }
    let w = width as usize;
    let h = height as usize;
    let pixel_count = match w.checked_mul(h) {
        Some(n) => n,
        None => return std::ptr::null_mut(),
    };
    let rgba_need = match pixel_count.checked_mul(4) {
        Some(n) => n,
        None => return std::ptr::null_mut(),
    };
    if rgba_len as usize != rgba_need || mask_len as usize != pixel_count {
        return std::ptr::null_mut();
    }

    let rgba_slice = unsafe { std::slice::from_raw_parts(rgba, rgba_len as usize) };
    let mask_slice = unsafe { std::slice::from_raw_parts(mask, mask_len as usize) };
    let keep_inside = mode == 0;

    let Some(data) = rgba_apply_selection_mask(rgba_slice, w, h, mask_slice, keep_inside) else {
        return std::ptr::null_mut();
    };
    if data.len() != rgba_need {
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
