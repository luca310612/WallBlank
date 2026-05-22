//! 8bit Planar マスクの in-place ペイント／加工 FFI
//! Why: Swift `MaskData` のホットパスをすべて Rust に集約し、
//! 描画中の CPU フレーム時間を削減する。

use artia_core::mask_paint;

/// 円形ブラシで in-place 塗布
#[unsafe(no_mangle)]
pub extern "C" fn artia_mask_paint_circle(
    data: *mut u8,
    data_len: u32,
    width: i32,
    height: i32,
    center_x: i32,
    center_y: i32,
    radius: i32,
    value: u8,
    softness: f32,
    is_erasing: u32,
) {
    if data.is_null() || width <= 0 || height <= 0 {
        return;
    }
    let expected = match (width as usize).checked_mul(height as usize) {
        Some(n) => n,
        None => return,
    };
    if data_len as usize != expected {
        return;
    }
    let slice = unsafe { std::slice::from_raw_parts_mut(data, expected) };
    mask_paint::paint_circle(
        slice,
        width,
        height,
        center_x,
        center_y,
        radius,
        value,
        softness,
        is_erasing != 0,
    );
}

/// ストロークを in-place 塗布。`points_xy` は interleaved [x0,y0,x1,y1,...]
#[unsafe(no_mangle)]
pub extern "C" fn artia_mask_paint_stroke(
    data: *mut u8,
    data_len: u32,
    width: i32,
    height: i32,
    points_xy: *const f32,
    point_count: u32,
    radius: i32,
    value: u8,
    softness: f32,
    is_erasing: u32,
) {
    if data.is_null() || points_xy.is_null() || width <= 0 || height <= 0 || point_count == 0 {
        return;
    }
    let expected = match (width as usize).checked_mul(height as usize) {
        Some(n) => n,
        None => return,
    };
    if data_len as usize != expected {
        return;
    }
    let n = point_count as usize;
    let pts: Vec<(f32, f32)> = unsafe {
        std::slice::from_raw_parts(points_xy, n * 2)
            .chunks_exact(2)
            .map(|c| (c[0], c[1]))
            .collect()
    };
    let slice = unsafe { std::slice::from_raw_parts_mut(data, expected) };
    mask_paint::paint_stroke(
        slice,
        width,
        height,
        &pts,
        radius,
        value,
        softness,
        is_erasing != 0,
    );
}

/// マスクをクリア（全 0）
#[unsafe(no_mangle)]
pub extern "C" fn artia_mask_clear(data: *mut u8, data_len: u32) {
    if data.is_null() || data_len == 0 {
        return;
    }
    let slice = unsafe { std::slice::from_raw_parts_mut(data, data_len as usize) };
    mask_paint::clear(slice);
}

/// マスクを反転
#[unsafe(no_mangle)]
pub extern "C" fn artia_mask_invert(data: *mut u8, data_len: u32) {
    if data.is_null() || data_len == 0 {
        return;
    }
    let slice = unsafe { std::slice::from_raw_parts_mut(data, data_len as usize) };
    mask_paint::invert(slice);
}

/// 軸平行矩形を一様に塗る
#[unsafe(no_mangle)]
pub extern "C" fn artia_mask_fill_rect(
    data: *mut u8,
    data_len: u32,
    width: i32,
    height: i32,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    value: u8,
) {
    if data.is_null() || width <= 0 || height <= 0 {
        return;
    }
    let expected = match (width as usize).checked_mul(height as usize) {
        Some(n) => n,
        None => return,
    };
    if data_len as usize != expected {
        return;
    }
    let slice = unsafe { std::slice::from_raw_parts_mut(data, expected) };
    mask_paint::fill_axis_aligned_rect(slice, width, height, x0, y0, x1, y1, value);
}

/// ボックスブラー（半径ピクセル指定、in-place）
#[unsafe(no_mangle)]
pub extern "C" fn artia_mask_box_blur(
    data: *mut u8,
    data_len: u32,
    width: i32,
    height: i32,
    radius: i32,
) {
    if data.is_null() || width <= 0 || height <= 0 || radius <= 0 {
        return;
    }
    let expected = match (width as usize).checked_mul(height as usize) {
        Some(n) => n,
        None => return,
    };
    if data_len as usize != expected {
        return;
    }
    let slice = unsafe { std::slice::from_raw_parts_mut(data, expected) };
    mask_paint::box_blur(slice, width, height, radius);
}
