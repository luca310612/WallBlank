// Phase 4B: パララックス FFI
// Why: ParallaxController (Swift) から WgpuEngine の `set_parallax_layer` / `update_parallax` /
//      `clear_parallax_layer` を呼び出すための C 互換関数群。
//      JSON 化が不要なほど単純なペイロードなので、ID + scalar / 既知レイヤー ID + 数値で渡す。

use std::ffi::{c_char, c_void};
use std::sync::Mutex;

use super::conversions::cstr_to_str;
use artia_wgpu::{ParallaxLayerSetting, WgpuEngine};

type EngineHandle = Mutex<Box<WgpuEngine>>;

macro_rules! lock_engine {
    ($handle:expr, $default:expr) => {
        match $handle.lock() {
            Ok(guard) => guard,
            Err(_) => {
                log::error!("エンジン Mutex ロック失敗 (poisoned) - parallax FFI");
                return $default;
            }
        }
    };
}

/// 指定レイヤーにパララックス設定を割り当てる。
/// - 戻り値: 1 = 成功, 0 = 該当レイヤーなし or 引数不正。
#[unsafe(no_mangle)]
pub extern "C" fn artia_parallax_set_layer(
    engine: *mut c_void,
    layer_id: *const c_char,
    depth: f32,
    strength: f32,
) -> u32 {
    if engine.is_null() || layer_id.is_null() {
        return 0;
    }
    let id = match unsafe { cstr_to_str(layer_id) } {
        Some(s) if !s.is_empty() => s,
        _ => return 0,
    };
    let handle = unsafe { &*(engine as *const EngineHandle) };
    let mut eng = lock_engine!(handle, 0);
    let setting = ParallaxLayerSetting { depth, strength };
    if eng.set_parallax_layer(id, setting) { 1 } else { 0 }
}

/// 指定レイヤーのパララックス設定を解除する。
#[unsafe(no_mangle)]
pub extern "C" fn artia_parallax_clear_layer(
    engine: *mut c_void,
    layer_id: *const c_char,
) -> u32 {
    if engine.is_null() || layer_id.is_null() {
        return 0;
    }
    let id = match unsafe { cstr_to_str(layer_id) } {
        Some(s) if !s.is_empty() => s,
        _ => return 0,
    };
    let handle = unsafe { &*(engine as *const EngineHandle) };
    let mut eng = lock_engine!(handle, 0);
    if eng.clear_parallax_layer(id) { 1 } else { 0 }
}

/// グローバルマウスオフセットを更新する。
/// - 引数: mouse_x_norm / mouse_y_norm を -1.0..1.0 の正規化値で渡す (画面中央 = 0,0)。
#[unsafe(no_mangle)]
pub extern "C" fn artia_parallax_update(
    engine: *mut c_void,
    mouse_x_norm: f32,
    mouse_y_norm: f32,
) {
    if engine.is_null() {
        return;
    }
    let handle = unsafe { &*(engine as *const EngineHandle) };
    // Mutex poisoned 時は何もせず抜ける。Why: 60fps 呼び出しなので致命的ログを増やさない。
    let mut eng = match handle.lock() {
        Ok(g) => g,
        Err(_) => return,
    };
    eng.update_parallax(mouse_x_norm, mouse_y_norm);
}
