// Phase 7B: スパニング壁紙 FFI.
// Why: Swift 側 SpanningCanvasController から JSON 文字列で SpanningCanvas を渡し、
//      WgpuEngine に保持させる。 後続フェーズで描画パスがこれを参照する。

use std::ffi::{c_char, c_void, CStr};
use std::sync::Mutex;

use artia_wgpu::{SpanningCanvas, WgpuEngine};

type EngineHandle = Mutex<Box<WgpuEngine>>;

/// SpanningCanvas を JSON で渡す。
/// 戻り値: 0 = 成功, 非 0 = 失敗 (エラー詳細はログへ)
#[unsafe(no_mangle)]
pub extern "C" fn artia_spanning_set(
    engine: *mut c_void,
    json_ptr: *const c_char,
) -> i32 {
    if engine.is_null() || json_ptr.is_null() {
        return -1;
    }
    let handle = unsafe { &*(engine as *const EngineHandle) };
    let mut eng = match handle.lock() {
        Ok(g) => g,
        Err(_) => {
            log::error!("エンジン Mutex ロック失敗 - spanning FFI");
            return -2;
        }
    };
    let json_str = unsafe {
        match CStr::from_ptr(json_ptr).to_str() {
            Ok(s) => s,
            Err(_) => {
                log::error!("spanning: 不正な UTF-8 文字列");
                return -3;
            }
        }
    };
    let canvas = match SpanningCanvas::from_json(json_str) {
        Ok(c) => c,
        Err(e) => {
            log::error!("spanning: JSON デコード失敗: {}", e);
            return -4;
        }
    };
    match eng.set_spanning_canvas(Some(canvas)) {
        Ok(()) => 0,
        Err(e) => {
            log::error!("spanning: validate 失敗: {}", e);
            -5
        }
    }
}

/// スパニング設定をクリアする (各ディスプレイ独立モードへ戻す)。
#[unsafe(no_mangle)]
pub extern "C" fn artia_spanning_clear(engine: *mut c_void) -> i32 {
    if engine.is_null() {
        return -1;
    }
    let handle = unsafe { &*(engine as *const EngineHandle) };
    let mut eng = match handle.lock() {
        Ok(g) => g,
        Err(_) => return -2,
    };
    let _ = eng.set_spanning_canvas(None);
    0
}

/// 現在のスパニング状態を取得する (1 = 有効, 0 = 無効)。
#[unsafe(no_mangle)]
pub extern "C" fn artia_spanning_is_active(engine: *mut c_void) -> i32 {
    if engine.is_null() {
        return 0;
    }
    let handle = unsafe { &*(engine as *const EngineHandle) };
    let eng = match handle.lock() {
        Ok(g) => g,
        Err(_) => return 0,
    };
    if eng.spanning_canvas().is_some() {
        1
    } else {
        0
    }
}
