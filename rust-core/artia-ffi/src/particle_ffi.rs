// Phase 4A: パーティクルシステム FFI
// Why: Swift 側から JSON descriptor を渡して ParticleSystem を生成 / 更新 / 破棄するための
//      C 互換関数群。エンジンハンドルは wgpu_ffi.rs 側の `EngineHandle` (`Mutex<Box<WgpuEngine>>`)
//      と同一なので、ポインタ解釈はそちらの慣習に倣う。

use std::ffi::{c_char, c_void};
use std::sync::Mutex;

use super::conversions::{cstr_to_str, error_to_c_json, rust_str_to_c};
use artia_wgpu::{ParticleSystemDescriptor, ParticleSystemParams, WgpuEngine};

/// wgpu_ffi.rs と同じハンドル型。private なのでこちらで再定義。
type EngineHandle = Mutex<Box<WgpuEngine>>;

/// `engine` ポインタからロック済み参照を取得するマクロ。
/// Why: Mutex poisoned 時に default 値で抜けるパターンを wgpu_ffi.rs と揃える。
macro_rules! lock_engine {
    ($handle:expr, $default:expr) => {
        match $handle.lock() {
            Ok(guard) => guard,
            Err(_) => {
                log::error!("エンジン Mutex ロック失敗 (poisoned) - particle FFI");
                return $default;
            }
        }
    };
}

/// パーティクルシステムを生成する。
///
/// - `descriptor_json`: `ParticleSystemDescriptor` を JSON 化した C 文字列。
/// - 戻り値: 成功時に発行された `ParticleSystemId.0` (u32, 1 以上)。
///           失敗時は 0 (= 無効 ID)。
#[unsafe(no_mangle)]
pub extern "C" fn artia_particle_create(
    engine: *mut c_void,
    descriptor_json: *const c_char,
) -> u32 {
    if engine.is_null() || descriptor_json.is_null() {
        log::error!("artia_particle_create: 引数が NULL");
        return 0;
    }
    let json = match unsafe { cstr_to_str(descriptor_json) } {
        Some(s) if !s.is_empty() => s,
        _ => {
            log::error!("artia_particle_create: descriptor_json が NULL/空/UTF-8 不正");
            return 0;
        }
    };
    let descriptor: ParticleSystemDescriptor = match serde_json::from_str(json) {
        Ok(d) => d,
        Err(e) => {
            log::error!("artia_particle_create: JSON parse 失敗: {}", e);
            return 0;
        }
    };
    let handle = unsafe { &*(engine as *const EngineHandle) };
    let mut eng = lock_engine!(handle, 0);
    eng.add_particle_system(descriptor)
}

/// パーティクルシステムにパラメータを部分適用する。
///
/// - `params_json`: `ParticleSystemParams` (各フィールドは Optional) の JSON。
/// - 戻り値: 成功時 NULL ポインタ。失敗時 `{"error":"..."}` JSON 文字列 (要 `artia_free_string`)。
#[unsafe(no_mangle)]
pub extern "C" fn artia_particle_update(
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
    let params: ParticleSystemParams = match serde_json::from_str(json) {
        Ok(p) => p,
        Err(e) => return error_to_c_json(&format!("JSON parse 失敗: {}", e)),
    };
    let handle = unsafe { &*(engine as *const EngineHandle) };
    let mut eng = lock_engine!(handle, error_to_c_json("Mutex poisoned"));
    if eng.update_particle_system(id, params) {
        std::ptr::null_mut()
    } else {
        error_to_c_json(&format!("ParticleSystem id={} が見つかりません", id))
    }
}

/// パーティクルシステムを破棄する。
/// - 戻り値: 成功時 1 / 該当 ID 不在で 0。
#[unsafe(no_mangle)]
pub extern "C" fn artia_particle_destroy(engine: *mut c_void, id: u32) -> u32 {
    if engine.is_null() {
        return 0;
    }
    let handle = unsafe { &*(engine as *const EngineHandle) };
    let mut eng = lock_engine!(handle, 0);
    if eng.remove_particle_system(id) { 1 } else { 0 }
}

/// 現在登録されているパーティクルシステム数を返す (テスト/メトリクス用)。
#[unsafe(no_mangle)]
pub extern "C" fn artia_particle_system_count(engine: *mut c_void) -> u32 {
    if engine.is_null() {
        return 0;
    }
    let handle = unsafe { &*(engine as *const EngineHandle) };
    let eng = lock_engine!(handle, 0);
    eng.particle_system_count() as u32
}

/// 軽量な疎通確認用関数: 引数の JSON descriptor を一旦 parse → 再シリアライズして返す。
/// Why: Swift 側の Codable 表現と Rust 側 serde 表現の不整合を、エンジンを跨がずに検証できる。
///      戻り値は `artia_free_string` で解放すること。
#[unsafe(no_mangle)]
pub extern "C" fn artia_particle_validate_descriptor(
    descriptor_json: *const c_char,
) -> *mut c_char {
    if descriptor_json.is_null() {
        return error_to_c_json("descriptor_json が NULL");
    }
    let json = match unsafe { cstr_to_str(descriptor_json) } {
        Some(s) => s,
        None => return error_to_c_json("descriptor_json が UTF-8 として不正"),
    };
    let descriptor: ParticleSystemDescriptor = match serde_json::from_str(json) {
        Ok(d) => d,
        Err(e) => return error_to_c_json(&format!("JSON parse 失敗: {}", e)),
    };
    let normalized = match serde_json::to_string(&descriptor) {
        Ok(s) => s,
        Err(e) => return error_to_c_json(&format!("re-serialize 失敗: {}", e)),
    };
    rust_str_to_c(&normalized)
}
