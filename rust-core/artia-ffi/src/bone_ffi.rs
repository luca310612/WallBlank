// Phase 4C: Skeleton FFI
// Why: Swift 側 `SkeletonBridge` から JSON descriptor / pose params で
//      生成・更新・破棄を行う。

use std::ffi::{c_char, c_void};
use std::sync::Mutex;

use super::conversions::{cstr_to_str, error_to_c_json, rust_str_to_c};
use artia_wgpu::{SkeletonDescriptor, SkeletonPoseParams, WgpuEngine};

type EngineHandle = Mutex<Box<WgpuEngine>>;

macro_rules! lock_engine {
    ($handle:expr, $default:expr) => {
        match $handle.lock() {
            Ok(guard) => guard,
            Err(_) => {
                log::error!("エンジン Mutex ロック失敗 (poisoned) - bone FFI");
                return $default;
            }
        }
    };
}

/// Skeleton を作成する。
#[unsafe(no_mangle)]
pub extern "C" fn artia_skeleton_create(
    engine: *mut c_void,
    descriptor_json: *const c_char,
) -> u32 {
    if engine.is_null() || descriptor_json.is_null() {
        return 0;
    }
    let json = match unsafe { cstr_to_str(descriptor_json) } {
        Some(s) if !s.is_empty() => s,
        _ => return 0,
    };
    let descriptor: SkeletonDescriptor = match serde_json::from_str(json) {
        Ok(d) => d,
        Err(e) => {
            log::error!("artia_skeleton_create: JSON parse 失敗: {}", e);
            return 0;
        }
    };
    let handle = unsafe { &*(engine as *const EngineHandle) };
    let mut eng = lock_engine!(handle, 0);
    eng.add_skeleton(descriptor)
}

/// Skeleton の pose を更新する。
#[unsafe(no_mangle)]
pub extern "C" fn artia_skeleton_update_pose(
    engine: *mut c_void,
    id: u32,
    params_json: *const c_char,
) -> *mut c_char {
    if engine.is_null() {
        return error_to_c_json("engine が NULL");
    }
    if params_json.is_null() {
        return error_to_c_json("params_json が NULL");
    }
    let json = match unsafe { cstr_to_str(params_json) } {
        Some(s) => s,
        None => return error_to_c_json("params_json が UTF-8 として不正"),
    };
    let params: SkeletonPoseParams = match serde_json::from_str(json) {
        Ok(p) => p,
        Err(e) => return error_to_c_json(&format!("JSON parse 失敗: {}", e)),
    };
    let handle = unsafe { &*(engine as *const EngineHandle) };
    let mut eng = lock_engine!(handle, error_to_c_json("Mutex poisoned"));
    if eng.update_skeleton_pose(id, params) {
        std::ptr::null_mut()
    } else {
        error_to_c_json(&format!("Skeleton id={} の pose 更新失敗 (件数不一致 or 未登録)", id))
    }
}

/// Skeleton を破棄する。
#[unsafe(no_mangle)]
pub extern "C" fn artia_skeleton_destroy(engine: *mut c_void, id: u32) -> u32 {
    if engine.is_null() {
        return 0;
    }
    let handle = unsafe { &*(engine as *const EngineHandle) };
    let mut eng = lock_engine!(handle, 0);
    if eng.remove_skeleton(id) { 1 } else { 0 }
}

/// 現在登録されている Skeleton 数 (テスト/メトリクス用)。
#[unsafe(no_mangle)]
pub extern "C" fn artia_skeleton_count(engine: *mut c_void) -> u32 {
    if engine.is_null() {
        return 0;
    }
    let handle = unsafe { &*(engine as *const EngineHandle) };
    let eng = lock_engine!(handle, 0);
    eng.skeleton_count() as u32
}

/// JSON ラウンドトリップ確認用。
#[unsafe(no_mangle)]
pub extern "C" fn artia_skeleton_validate_descriptor(
    descriptor_json: *const c_char,
) -> *mut c_char {
    if descriptor_json.is_null() {
        return error_to_c_json("descriptor_json が NULL");
    }
    let json = match unsafe { cstr_to_str(descriptor_json) } {
        Some(s) => s,
        None => return error_to_c_json("descriptor_json が UTF-8 として不正"),
    };
    let descriptor: SkeletonDescriptor = match serde_json::from_str(json) {
        Ok(d) => d,
        Err(e) => return error_to_c_json(&format!("JSON parse 失敗: {}", e)),
    };
    let normalized = match serde_json::to_string(&descriptor) {
        Ok(s) => s,
        Err(e) => return error_to_c_json(&format!("re-serialize 失敗: {}", e)),
    };
    rust_str_to_c(&normalized)
}
