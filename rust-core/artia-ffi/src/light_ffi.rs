// Phase 4B: Light レイヤー FFI
// Why: Swift 側 `LightLayerBridge` が JSON descriptor / params を C 文字列で渡せるようにする。

use std::ffi::{c_char, c_void};
use std::sync::Mutex;

use super::conversions::{cstr_to_str, error_to_c_json};
use artia_wgpu::{LightLayerDescriptor, LightLayerParams, WgpuEngine};

type EngineHandle = Mutex<Box<WgpuEngine>>;

macro_rules! lock_engine {
    ($handle:expr, $default:expr) => {
        match $handle.lock() {
            Ok(guard) => guard,
            Err(_) => {
                log::error!("エンジン Mutex ロック失敗 (poisoned) - light FFI");
                return $default;
            }
        }
    };
}

/// Light レイヤーを追加する。
/// - `descriptor_json`: `LightLayerDescriptor` の JSON 文字列。
/// - 戻り値: 発行された LightLayerId.0 (1 以上) / 失敗時 0。
#[unsafe(no_mangle)]
pub extern "C" fn artia_light_create(
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
    let descriptor: LightLayerDescriptor = match serde_json::from_str(json) {
        Ok(d) => d,
        Err(e) => {
            log::error!("artia_light_create: JSON parse 失敗: {}", e);
            return 0;
        }
    };
    let handle = unsafe { &*(engine as *const EngineHandle) };
    let mut eng = lock_engine!(handle, 0);
    eng.add_light_layer(descriptor)
}

/// Light レイヤーにパラメータを部分適用する。
/// - 戻り値: 成功時 NULL / 失敗時 `{"error":"..."}` JSON 文字列 (要 `artia_free_string`)。
#[unsafe(no_mangle)]
pub extern "C" fn artia_light_update(
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
    let params: LightLayerParams = match serde_json::from_str(json) {
        Ok(p) => p,
        Err(e) => return error_to_c_json(&format!("JSON parse 失敗: {}", e)),
    };
    let handle = unsafe { &*(engine as *const EngineHandle) };
    let mut eng = lock_engine!(handle, error_to_c_json("Mutex poisoned"));
    if eng.update_light_layer(id, params) {
        std::ptr::null_mut()
    } else {
        error_to_c_json(&format!("LightLayer id={} が見つかりません", id))
    }
}

/// Light レイヤーを破棄する。
#[unsafe(no_mangle)]
pub extern "C" fn artia_light_destroy(engine: *mut c_void, id: u32) -> u32 {
    if engine.is_null() {
        return 0;
    }
    let handle = unsafe { &*(engine as *const EngineHandle) };
    let mut eng = lock_engine!(handle, 0);
    if eng.remove_light_layer(id) { 1 } else { 0 }
}

/// 現在の Light レイヤー数 (テスト/メトリクス用)。
#[unsafe(no_mangle)]
pub extern "C" fn artia_light_count(engine: *mut c_void) -> u32 {
    if engine.is_null() {
        return 0;
    }
    let handle = unsafe { &*(engine as *const EngineHandle) };
    let eng = lock_engine!(handle, 0);
    eng.light_layer_count() as u32
}
