// Phase 6A: Audio Reactive FFI.
// Why: Swift 側で計算した FFT バンド配列を毎フレーム Rust エンジンへ送り、
//      audio uniform / particle audio binding の元データを更新する。

use std::ffi::c_void;
use std::sync::Mutex;

use artia_wgpu::{EmitterAudioBinding, WgpuEngine};

type EngineHandle = Mutex<Box<WgpuEngine>>;

macro_rules! lock_engine {
    ($handle:expr, $default:expr) => {
        match $handle.lock() {
            Ok(guard) => guard,
            Err(_) => {
                log::error!("エンジン Mutex ロック失敗 (poisoned) - audio FFI");
                return $default;
            }
        }
    };
}

/// FFT バンド配列を audio uniform へ書き込む。
/// - `bands_ptr`: f32 配列 (0..1 正規化推奨)。`len` 個読む。
/// - `len`: 0 を渡せば「無音」扱いで全バンドが 0 に戻る。
/// - `time`: シェーダ位相用の経過時間 (秒)。
#[unsafe(no_mangle)]
pub extern "C" fn artia_audio_update(
    engine: *mut c_void,
    bands_ptr: *const f32,
    len: usize,
    time: f32,
) {
    if engine.is_null() {
        return;
    }
    let handle = unsafe { &*(engine as *const EngineHandle) };
    let mut eng = match handle.lock() {
        Ok(g) => g,
        Err(_) => return,
    };
    if bands_ptr.is_null() || len == 0 {
        eng.update_audio_uniform(&[], time);
        return;
    }
    let slice = unsafe { std::slice::from_raw_parts(bands_ptr, len) };
    eng.update_audio_uniform(slice, time);
}

/// 直近の audio uniform 要約 (bass/mid/treble/time/active_bands) を out 配列に書き出す。
/// - `out_ptr`: f32 5 要素の領域。順に bass, mid, treble, time, active_bands。
/// - Returns: 1 = 成功, 0 = 引数不正。
#[unsafe(no_mangle)]
pub extern "C" fn artia_audio_summary(engine: *mut c_void, out_ptr: *mut f32) -> u32 {
    if engine.is_null() || out_ptr.is_null() {
        return 0;
    }
    let handle = unsafe { &*(engine as *const EngineHandle) };
    let eng = lock_engine!(handle, 0);
    let u = eng.audio_uniform();
    unsafe {
        *out_ptr.add(0) = u.bass;
        *out_ptr.add(1) = u.mid;
        *out_ptr.add(2) = u.treble;
        *out_ptr.add(3) = u.time;
        *out_ptr.add(4) = u.active_bands as f32;
    }
    1
}

/// 指定 ParticleSystem に audio binding を設定する。
/// - `system_id`: ParticleSystemId.0
/// - `band_index`: 参照するバンド (0..127)。
/// - `scale`: 振幅倍率。`spawn_rate += band[band_index] * scale`。
/// - Returns: 1 = 成功, 0 = 該当 ID なし。
#[unsafe(no_mangle)]
pub extern "C" fn artia_audio_bind_emitter(
    engine: *mut c_void,
    system_id: u32,
    band_index: u32,
    scale: f32,
) -> u32 {
    if engine.is_null() {
        return 0;
    }
    let handle = unsafe { &*(engine as *const EngineHandle) };
    let mut eng = lock_engine!(handle, 0);
    let binding = EmitterAudioBinding { band_index, scale };
    if eng.set_particle_audio_binding(system_id, Some(binding)) {
        1
    } else {
        0
    }
}

/// 指定 ParticleSystem の audio binding を解除する。
#[unsafe(no_mangle)]
pub extern "C" fn artia_audio_unbind_emitter(engine: *mut c_void, system_id: u32) -> u32 {
    if engine.is_null() {
        return 0;
    }
    let handle = unsafe { &*(engine as *const EngineHandle) };
    let mut eng = lock_engine!(handle, 0);
    if eng.set_particle_audio_binding(system_id, None) {
        1
    } else {
        0
    }
}

