// Artia FFI エクスポート層
// Swift側から呼び出されるC互換関数を定義する

use std::ffi::{c_char, CStr, CString};

mod audio_ffi;
mod bone_ffi;
mod brush_mask_ffi;
mod conversions;
mod firebase_ffi;
mod light_ffi;
mod magnetic_select_ffi;
mod mask_paint_ffi;
mod parallax_ffi;
mod particle_ffi;
mod spanning_ffi;
mod warp_ffi;
mod wgpu_ffi;

pub use particle_ffi::{
    artia_particle_create, artia_particle_destroy, artia_particle_system_count,
    artia_particle_update, artia_particle_validate_descriptor,
};

pub use light_ffi::{
    artia_light_count, artia_light_create, artia_light_destroy, artia_light_update,
};

pub use parallax_ffi::{
    artia_parallax_clear_layer, artia_parallax_set_layer, artia_parallax_update,
};

pub use warp_ffi::{
    artia_warp_count, artia_warp_create, artia_warp_destroy, artia_warp_update,
    artia_warp_validate_descriptor,
};

pub use bone_ffi::{
    artia_skeleton_count, artia_skeleton_create, artia_skeleton_destroy,
    artia_skeleton_update_pose, artia_skeleton_validate_descriptor,
};

pub use audio_ffi::{
    artia_audio_bind_emitter, artia_audio_summary, artia_audio_unbind_emitter,
    artia_audio_update,
};

pub use spanning_ffi::{artia_spanning_clear, artia_spanning_is_active, artia_spanning_set};

pub use brush_mask_ffi::{artia_brush_rasterize_mask, ArtiaBrushMaskRasterParams};
pub use magnetic_select_ffi::{artia_magnetic_selection_mask, artia_rgba_apply_selection_mask};
pub use mask_paint_ffi::{
    artia_mask_box_blur, artia_mask_clear, artia_mask_fill_rect, artia_mask_invert,
    artia_mask_paint_circle, artia_mask_paint_stroke,
};
use conversions::{error_to_c_json, rust_str_to_c};

/// Rustで確保した文字列を解放する
/// Swift側は受け取った文字列をコピーした後、必ずこの関数で解放すること
#[unsafe(no_mangle)]
pub extern "C" fn artia_free_string(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        let _ = CString::from_raw(ptr);
    }
}

/// Rustで確保したバイト配列を解放する
/// 注意: この関数は into_boxed_slice() + mem::forget() で確保されたメモリ専用
/// (capacity == len が保証されている前提)
#[unsafe(no_mangle)]
pub extern "C" fn artia_free_bytes(ptr: *mut u8, len: u32) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        let slice = std::slice::from_raw_parts_mut(ptr, len as usize);
        let _ = Box::from_raw(slice);
    }
}

/// Artiaのバージョン文字列を返す
/// 戻り値は artia_free_string() で解放すること
#[unsafe(no_mangle)]
pub extern "C" fn artia_version() -> *mut c_char {
    let version = artia_core::version();
    match CString::new(version) {
        Ok(c_str) => c_str.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// ログシステムを初期化する（アプリ起動時に1回呼ぶ）
#[unsafe(no_mangle)]
pub extern "C" fn artia_init() {
    let _ = env_logger::try_init();
    log::info!("Artia Rustコア初期化完了 (v{})", artia_core::version());
}

// =============================================================================
// PKG関連FFI
// =============================================================================

/// PKGファイル内の全テクスチャを指定ディレクトリにPNGとして展開する
/// 成功時: 展開されたファイルパスのJSON配列を返す (例: ["path/a.png", "path/b.png"])
/// 失敗時: {"error": "メッセージ"} 形式のJSON文字列を返す
/// 戻り値は artia_free_string() で解放すること
#[unsafe(no_mangle)]
pub extern "C" fn artia_pkg_extract(
    pkg_path: *const c_char,
    output_dir: *const c_char,
) -> *mut c_char {
    if pkg_path.is_null() {
        return error_to_c_json("PKGパスがnullです");
    }
    if output_dir.is_null() {
        return error_to_c_json("出力パスがnullです");
    }
    let pkg_path = match unsafe { CStr::from_ptr(pkg_path) }.to_str() {
        Ok(s) => s,
        Err(_) => return error_to_c_json("不正なPKGパス"),
    };
    let output_dir = match unsafe { CStr::from_ptr(output_dir) }.to_str() {
        Ok(s) => s,
        Err(_) => return error_to_c_json("不正な出力パス"),
    };

    match artia_core::pkg_reader::PkgReader::open(pkg_path) {
        Ok(reader) => match reader.extract_all_textures(output_dir) {
            Ok(paths) => {
                let json = serde_json::to_string(&paths).unwrap_or_else(|_| "[]".to_string());
                rust_str_to_c(&json)
            }
            Err(e) => error_to_c_json(&e.to_string()),
        },
        Err(e) => error_to_c_json(&e.to_string()),
    }
}

/// Artia 独自フォーマット (.wallpaper) を書き出す。
/// `descriptor_json` は以下の JSON:
/// ```json
/// {
///   "output_path": "...",
///   "project_json": "{...}",
///   "scene_json": "{...}",
///   "assets": [{"name":"a.png","path":"/abs/a.png"}]
/// }
/// ```
/// 戻り値: 成功時 true / 失敗時 false (詳細は log::error!)
#[unsafe(no_mangle)]
pub extern "C" fn artia_pkg_write(descriptor_json: *const c_char) -> bool {
    if descriptor_json.is_null() {
        log::error!("artia_pkg_write: descriptor_json が null");
        return false;
    }
    let json = match unsafe { CStr::from_ptr(descriptor_json) }.to_str() {
        Ok(s) => s,
        Err(e) => {
            log::error!("artia_pkg_write: descriptor_json が UTF-8 でない: {e}");
            return false;
        }
    };
    let descriptor: artia_core::pkg_writer::PkgWriteDescriptor =
        match serde_json::from_str(json) {
            Ok(d) => d,
            Err(e) => {
                log::error!("artia_pkg_write: JSON 解析失敗: {e}");
                return false;
            }
        };
    let input = descriptor.into_input();
    match artia_core::pkg_writer::PkgWriter::write(&input) {
        Ok(()) => true,
        Err(e) => {
            log::error!("artia_pkg_write: 書き込み失敗: {e}");
            false
        }
    }
}

/// PKGファイル内のテクスチャ一覧をJSON配列で返す
/// 戻り値は artia_free_string() で解放すること
#[unsafe(no_mangle)]
pub extern "C" fn artia_pkg_list_textures(pkg_path: *const c_char) -> *mut c_char {
    if pkg_path.is_null() {
        return error_to_c_json("PKGパスがnullです");
    }
    let pkg_path = match unsafe { CStr::from_ptr(pkg_path) }.to_str() {
        Ok(s) => s,
        Err(_) => return error_to_c_json("不正なPKGパス"),
    };

    match artia_core::pkg_reader::PkgReader::open(pkg_path) {
        Ok(reader) => {
            let textures: Vec<_> = reader
                .list_textures()
                .iter()
                .map(|e| serde_json::json!({"name": e.name, "size": e.size}))
                .collect();
            let json = serde_json::to_string(&textures).unwrap_or_else(|_| "[]".to_string());
            rust_str_to_c(&json)
        }
        Err(e) => error_to_c_json(&e.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_version_ffi() {
        let ptr = artia_version();
        assert!(!ptr.is_null());
        let version = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap();
        assert_eq!(version, "0.1.0");
        artia_free_string(ptr);
    }

    #[test]
    fn test_free_null() {
        // null ポインタを渡してもクラッシュしないこと
        artia_free_string(std::ptr::null_mut());
    }
}
