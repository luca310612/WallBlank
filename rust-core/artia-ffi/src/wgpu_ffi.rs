// WGPU アニメーションエンジンのFFIエクスポート
// Swift側からC互換関数として呼び出される

use std::ffi::{c_char, c_void};
use std::panic::AssertUnwindSafe;
use std::sync::Mutex;

use super::conversions::{cstr_to_str, rust_str_to_c};
use artia_wgpu::{WgpuEngine, RENDER_ERROR};

/// ブラシストローク用ポイント（画像座標）
#[repr(C)]
pub struct ArtiaStrokePoint {
    pub x: f32,
    pub y: f32,
}

/// ブラシパラメータ
#[repr(C)]
pub struct ArtiaBrushParams {
    pub radius: f32,
    pub softness: f32,
    pub is_erasing: bool,
}

/// エンジンハンドル型（Mutexでスレッドセーフに管理）
type EngineHandle = Mutex<Box<WgpuEngine>>;

/// ポインタからエンジンハンドルの参照を取得する
///
/// # Safety
/// - ptrはBox::into_rawで作成された有効なEngineHandleポインタであること
/// - 返り値の参照は、ptrが有効である間のみ使用すること
unsafe fn engine_ref<'a>(ptr: *mut c_void) -> &'a EngineHandle {
    &*(ptr as *const EngineHandle)
}

/// Mutexロックを安全に取得するヘルパーマクロ
/// poisoned状態の場合はログを出力してデフォルト値を返す
macro_rules! lock_engine {
    ($handle:expr) => {
        match $handle.lock() {
            Ok(guard) => guard,
            Err(_) => {
                log::error!("エンジンMutexロック失敗（poisoned）");
                return Default::default();
            }
        }
    };
    ($handle:expr, $default:expr) => {
        match $handle.lock() {
            Ok(guard) => guard,
            Err(_) => {
                log::error!("エンジンMutexロック失敗（poisoned）");
                return $default;
            }
        }
    };
}

// =============================================================================
// エンジンライフサイクル
// =============================================================================

/// WGPUアニメーションエンジンを作成する
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_create(
    canvas_width: u32,
    canvas_height: u32,
) -> *mut c_void {
    match WgpuEngine::new(canvas_width, canvas_height) {
        Ok(engine) => {
            let handle: Box<EngineHandle> = Box::new(Mutex::new(Box::new(engine)));
            Box::into_raw(handle) as *mut c_void
        }
        Err(e) => {
            log::error!("WGPUエンジン作成失敗: {}", e);
            std::ptr::null_mut()
        }
    }
}

/// エンジンを破棄する
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_destroy(engine: *mut c_void) {
    if engine.is_null() {
        return;
    }
    unsafe {
        let _ = Box::from_raw(engine as *mut EngineHandle);
    }
    log::info!("WGPUエンジン破棄完了");
}

/// 出力テクスチャのIOSurfaceRefを取得する
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_get_output_surface(
    engine: *mut c_void,
) -> *mut c_void {
    if engine.is_null() {
        return std::ptr::null_mut();
    }
    let handle = unsafe { engine_ref(engine) };
    let engine = lock_engine!(handle, std::ptr::null_mut());
    engine.iosurface_ptr()
}

/// 1フレームをレンダリングする
/// 戻り値: 0 = 成功, -1 = レンダリングエラー（GPUデバイスロストの可能性）
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_render_frame(
    engine: *mut c_void,
    delta_time: f32,
) -> i32 {
    if engine.is_null() {
        return RENDER_ERROR;
    }
    let handle = unsafe { engine_ref(engine) };
    let mut eng = lock_engine!(handle, RENDER_ERROR);

    // GPUデバイスロスト時のパニックをキャッチ
    match std::panic::catch_unwind(AssertUnwindSafe(|| eng.render_frame(delta_time))) {
        Ok(status) => status,
        Err(_) => {
            log::error!("render_frameでパニック発生（GPUデバイスロストの可能性）");
            RENDER_ERROR
        }
    }
}

/// 経過時間をリセットする
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_reset_time(engine: *mut c_void) {
    if engine.is_null() {
        return;
    }
    let handle = unsafe { engine_ref(engine) };
    let mut engine = lock_engine!(handle);
    engine.reset_time();
}

// =============================================================================
// ビューポート管理
// =============================================================================

/// ビューポートサイズを設定する（IOSurface再作成）
/// 戻り値: 新しいIOSurfaceポインタ（Swift側でMTLTexture再作成に使用）
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_set_viewport_size(
    engine: *mut c_void,
    width: u32,
    height: u32,
) -> *mut c_void {
    if engine.is_null() {
        return std::ptr::null_mut();
    }
    let handle = unsafe { engine_ref(engine) };
    let mut eng = lock_engine!(handle, std::ptr::null_mut());
    eng.set_viewport_size(width, height)
}

/// ビューポートパラメータを更新する（ズーム・パン変更時）
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_set_viewport_params(
    engine: *mut c_void,
    zoom: f32,
    pan_x: f32,
    pan_y: f32,
    canvas_origin_x: f32,
    canvas_origin_y: f32,
) {
    if engine.is_null() {
        return;
    }
    let handle = unsafe { engine_ref(engine) };
    let mut eng = lock_engine!(handle);
    eng.set_viewport_params(zoom, pan_x, pan_y, canvas_origin_x, canvas_origin_y);
}

/// ビューポートモードの有効/無効を切り替える
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_set_viewport_mode(
    engine: *mut c_void,
    enabled: bool,
) {
    if engine.is_null() {
        return;
    }
    let handle = unsafe { engine_ref(engine) };
    let mut eng = lock_engine!(handle);
    eng.set_viewport_mode(enabled);
}

/// 現在アクティブなIOSurfaceポインタを取得する（ビューポートモード対応）
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_get_active_surface(
    engine: *mut c_void,
) -> *mut c_void {
    if engine.is_null() {
        return std::ptr::null_mut();
    }
    let handle = unsafe { engine_ref(engine) };
    let eng = lock_engine!(handle, std::ptr::null_mut());
    eng.active_iosurface_ptr()
}

// =============================================================================
// デバッグ
// =============================================================================

/// デバッグ用: アクティブIOSurfaceに赤いテストパターンを書き込む
/// レンダリングパイプラインの問題切り分けに使用
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_debug_fill(engine: *mut c_void) {
    if engine.is_null() {
        return;
    }
    let handle = unsafe { engine_ref(engine) };
    let eng = lock_engine!(handle);
    eng.debug_fill_iosurface();
}

// =============================================================================
// レイヤー管理
// =============================================================================

/// レイヤーを追加する
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_add_layer(
    engine: *mut c_void,
    name: *const c_char,
    width: u32,
    height: u32,
    rgba_data: *const u8,
    data_len: u32,
) -> *mut c_char {
    if engine.is_null() || rgba_data.is_null() {
        return std::ptr::null_mut();
    }

    let name = match unsafe { cstr_to_str(name) } {
        Some(s) => s,
        None => "無名レイヤー",
    };

    let data = unsafe { std::slice::from_raw_parts(rgba_data, data_len as usize) };

    let handle = unsafe { engine_ref(engine) };
    let mut eng = lock_engine!(handle, std::ptr::null_mut());
    let layer_id = eng.add_layer(name, width, height, data);

    rust_str_to_c(&layer_id)
}

/// レイヤーを削除する
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_remove_layer(
    engine: *mut c_void,
    layer_id: *const c_char,
) -> i32 {
    if engine.is_null() {
        return 0;
    }
    let layer_id = match unsafe { cstr_to_str(layer_id) } {
        Some(s) => s,
        None => return 0,
    };
    let handle = unsafe { engine_ref(engine) };
    let mut eng = lock_engine!(handle, 0);
    if eng.remove_layer(layer_id) { 1 } else { 0 }
}

/// レイヤーの描画順序を変更する
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_reorder_layer(
    engine: *mut c_void,
    layer_id: *const c_char,
    new_index: u32,
) -> i32 {
    if engine.is_null() {
        return 0;
    }
    let layer_id = match unsafe { cstr_to_str(layer_id) } {
        Some(s) => s,
        None => return 0,
    };
    let handle = unsafe { engine_ref(engine) };
    let mut eng = lock_engine!(handle, 0);
    if eng.reorder_layer(layer_id, new_index) { 1 } else { 0 }
}

/// レイヤーIDを下から順のJSON配列（例: ["uuid1","uuid2"]）で渡し、Rust側の合成順を同期する
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_set_layer_stack_order_json(
    engine: *mut c_void,
    json: *const c_char,
) -> i32 {
    if engine.is_null() {
        return 0;
    }
    let json = match unsafe { cstr_to_str(json) } {
        Some(s) => s,
        None => return 0,
    };
    let ids: Vec<String> = match serde_json::from_str(json) {
        Ok(v) => v,
        Err(e) => {
            log::error!("レイヤースタック順JSON解析失敗: {}", e);
            return 0;
        }
    };
    let handle = unsafe { engine_ref(engine) };
    let mut eng = lock_engine!(handle, 0);
    if eng.set_layer_stack_order(&ids) {
        1
    } else {
        0
    }
}

// =============================================================================
// ファイル読み込み・テクスチャ更新・エクスポート
// =============================================================================

/// ファイルパスから画像を読み込んでレイヤーを追加する
/// 戻り値: レイヤーID文字列（失敗時はnull）
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_add_layer_from_file(
    engine: *mut c_void,
    name: *const c_char,
    file_path: *const c_char,
) -> *mut c_char {
    if engine.is_null() {
        return std::ptr::null_mut();
    }
    let name = match unsafe { cstr_to_str(name) } {
        Some(s) => s,
        None => "無名レイヤー",
    };
    let path = match unsafe { cstr_to_str(file_path) } {
        Some(s) => s,
        None => {
            log::error!("ファイルパスがnullです");
            return std::ptr::null_mut();
        }
    };
    let handle = unsafe { engine_ref(engine) };
    let mut eng = lock_engine!(handle, std::ptr::null_mut());
    match eng.add_layer_from_file(name, path) {
        Ok(layer_id) => rust_str_to_c(&layer_id),
        Err(e) => {
            log::error!("画像レイヤー追加失敗: {}", e);
            std::ptr::null_mut()
        }
    }
}

/// レイヤーのテクスチャを更新する（動画フレーム差し替え用）
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_update_layer_texture(
    engine: *mut c_void,
    layer_id: *const c_char,
    width: u32,
    height: u32,
    rgba_data: *const u8,
    data_len: u32,
) {
    if engine.is_null() || rgba_data.is_null() {
        return;
    }
    let layer_id = match unsafe { cstr_to_str(layer_id) } {
        Some(s) => s,
        None => return,
    };
    let data = unsafe { std::slice::from_raw_parts(rgba_data, data_len as usize) };
    let handle = unsafe { engine_ref(engine) };
    let mut eng = lock_engine!(handle);
    eng.update_layer_texture(layer_id, width, height, data);
}

/// レイヤーの画像調整パラメータを設定する（JSON文字列）
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_set_layer_adjustments(
    engine: *mut c_void,
    layer_id: *const c_char,
    adjustments_json: *const c_char,
) {
    if engine.is_null() {
        return;
    }
    let layer_id = match unsafe { cstr_to_str(layer_id) } {
        Some(s) => s,
        None => return,
    };
    let json = match unsafe { cstr_to_str(adjustments_json) } {
        Some(s) => s,
        None => return,
    };
    let handle = unsafe { engine_ref(engine) };
    let mut eng = lock_engine!(handle);
    eng.set_layer_adjustments(layer_id, json);
}

/// エディタ用変形を設定する（JSON文字列）
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_set_layer_editor_transform(
    engine: *mut c_void,
    layer_id: *const c_char,
    transform_json: *const c_char,
) {
    if engine.is_null() {
        return;
    }
    let layer_id = match unsafe { cstr_to_str(layer_id) } {
        Some(s) => s,
        None => return,
    };
    let json = match unsafe { cstr_to_str(transform_json) } {
        Some(s) => s,
        None => return,
    };
    let handle = unsafe { engine_ref(engine) };
    let mut eng = lock_engine!(handle);
    eng.set_layer_editor_transform(layer_id, json);
}

/// 合成結果をRGBAバイト列として取得する（エクスポート用）
/// 戻り値: RGBAデータポインタ（呼び出し側でartia_free_bytesで解放すること）
/// out_width, out_heightに幅と高さが書き込まれる
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_export_rgba(
    engine: *mut c_void,
    out_width: *mut u32,
    out_height: *mut u32,
) -> *mut u8 {
    if engine.is_null() || out_width.is_null() || out_height.is_null() {
        return std::ptr::null_mut();
    }
    let handle = unsafe { engine_ref(engine) };
    let mut eng = lock_engine!(handle, std::ptr::null_mut());
    let (data, w, h) = eng.export_rgba();

    unsafe {
        *out_width = w;
        *out_height = h;
    }

    // Vec<u8>をヒープに移動してポインタを返す
    let mut boxed = data.into_boxed_slice();
    let ptr = boxed.as_mut_ptr();
    std::mem::forget(boxed);
    ptr
}

// =============================================================================
// レイヤープロパティ
// =============================================================================

/// レイヤーの変形を設定する（JSON文字列）
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_set_layer_transform(
    engine: *mut c_void,
    layer_id: *const c_char,
    transform_json: *const c_char,
) {
    if engine.is_null() {
        return;
    }
    let layer_id = match unsafe { cstr_to_str(layer_id) } {
        Some(s) => s,
        None => return,
    };
    let json = match unsafe { cstr_to_str(transform_json) } {
        Some(s) => s,
        None => return,
    };
    let handle = unsafe { engine_ref(engine) };
    let mut eng = lock_engine!(handle);
    eng.set_layer_transform(layer_id, json);
}

/// レイヤーの不透明度を設定する
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_set_layer_opacity(
    engine: *mut c_void,
    layer_id: *const c_char,
    opacity: f32,
) {
    if engine.is_null() {
        return;
    }
    let layer_id = match unsafe { cstr_to_str(layer_id) } {
        Some(s) => s,
        None => return,
    };
    let handle = unsafe { engine_ref(engine) };
    let mut eng = lock_engine!(handle);
    eng.set_layer_opacity(layer_id, opacity);
}

/// レイヤーのブレンドモードを設定する
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_set_layer_blend_mode(
    engine: *mut c_void,
    layer_id: *const c_char,
    blend_mode: u32,
) {
    if engine.is_null() {
        return;
    }
    let layer_id = match unsafe { cstr_to_str(layer_id) } {
        Some(s) => s,
        None => return,
    };
    let handle = unsafe { engine_ref(engine) };
    let mut eng = lock_engine!(handle);
    eng.set_layer_blend_mode(layer_id, blend_mode);
}

/// レイヤーの表示/非表示を設定する
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_set_layer_visible(
    engine: *mut c_void,
    layer_id: *const c_char,
    visible: bool,
) {
    if engine.is_null() {
        return;
    }
    let layer_id = match unsafe { cstr_to_str(layer_id) } {
        Some(s) => s,
        None => return,
    };
    let handle = unsafe { engine_ref(engine) };
    let mut eng = lock_engine!(handle);
    eng.set_layer_visible(layer_id, visible);
}

// =============================================================================
// アニメーション
// =============================================================================

/// レイヤーにアニメーション設定を適用する（JSON文字列）
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_set_layer_animation(
    engine: *mut c_void,
    layer_id: *const c_char,
    config_json: *const c_char,
) {
    if engine.is_null() {
        return;
    }
    let layer_id = match unsafe { cstr_to_str(layer_id) } {
        Some(s) => s,
        None => return,
    };
    let json = match unsafe { cstr_to_str(config_json) } {
        Some(s) => s,
        None => return,
    };
    let handle = unsafe { engine_ref(engine) };
    let mut eng = lock_engine!(handle);
    eng.set_layer_animation(layer_id, json);
}

/// カスタムキーフレームトラックを追加する（JSON文字列）
/// TODO: Phase 4で実装
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_add_keyframe_track(
    _engine: *mut c_void,
    _layer_id: *const c_char,
    _track_json: *const c_char,
) {
    log::warn!("artia_wgpu_engine_add_keyframe_track: 未実装（Phase 4で実装予定）");
}

/// レイヤーの全キーフレームをクリアする
/// TODO: Phase 4で実装
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_clear_keyframes(
    _engine: *mut c_void,
    _layer_id: *const c_char,
) {
    log::warn!("artia_wgpu_engine_clear_keyframes: 未実装（Phase 4で実装予定）");
}

// =============================================================================
// 再生制御
// =============================================================================

/// アニメーション再生/一時停止
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_set_playing(
    engine: *mut c_void,
    playing: bool,
) {
    if engine.is_null() {
        return;
    }
    let handle = unsafe { engine_ref(engine) };
    let mut eng = lock_engine!(handle);
    eng.set_playing(playing);
}

/// アニメーション時刻にシークする
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_seek(
    engine: *mut c_void,
    time: f32,
) {
    if engine.is_null() {
        return;
    }
    let handle = unsafe { engine_ref(engine) };
    let mut eng = lock_engine!(handle);
    eng.seek(time);
}

// =============================================================================
// エフェクト（Phase 5で実装予定のスタブ）
// =============================================================================

/// 水面エフェクト設定を更新する（JSON文字列）
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_set_water_effect(
    _engine: *mut c_void,
    _config_json: *const c_char,
) {
    log::warn!("artia_wgpu_engine_set_water_effect: 未実装（Phase 5で実装予定）");
}

/// マスクテクスチャを設定する（R8フォーマット）
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_set_mask_texture(
    engine: *mut c_void,
    width: u32,
    height: u32,
    mask_data: *const u8,
    data_len: u32,
) {
    if engine.is_null() || mask_data.is_null() || data_len == 0 {
        return;
    }

    let handle = unsafe { engine_ref(engine) };
    let mut eng = lock_engine!(handle);

    let len = data_len as usize;
    let slice = unsafe { std::slice::from_raw_parts(mask_data, len) };
    eng.set_mask_texture(width, height, slice);
}

/// マスクテクスチャをクリアする
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_clear_mask(engine: *mut c_void) {
    if engine.is_null() {
        return;
    }
    let handle = unsafe { engine_ref(engine) };
    let mut eng = lock_engine!(handle);
    eng.clear_mask();
}

/// マスクにブラシストロークを適用する（GPUマスク編集用入口）
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_paint_mask_stroke(
    engine: *mut c_void,
    points: *const ArtiaStrokePoint,
    point_count: u32,
    params: ArtiaBrushParams,
) {
    if engine.is_null() || points.is_null() || point_count == 0 {
        return;
    }
    let handle = unsafe { engine_ref(engine) };
    let mut eng = lock_engine!(handle);

    // 生のFFI用ポイント列を、エンジン側で扱う(f32, f32)の列に変換する
    let raw_slice = unsafe { std::slice::from_raw_parts(points, point_count as usize) };
    let points_vec: Vec<(f32, f32)> = raw_slice.iter().map(|p| (p.x, p.y)).collect();

    eng.paint_mask_stroke(
        &points_vec,
        params.radius,
        params.softness,
        params.is_erasing,
    );
}

/// マスクをぼかす
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_blur_mask(engine: *mut c_void, radius: u32) {
    if engine.is_null() {
        return;
    }
    let handle = unsafe { engine_ref(engine) };
    let mut eng = lock_engine!(handle);
    eng.blur_mask(radius);
}

/// マスクを反転する
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_invert_mask(engine: *mut c_void) {
    if engine.is_null() {
        return;
    }
    let handle = unsafe { engine_ref(engine) };
    let mut eng = lock_engine!(handle);
    eng.invert_mask();
}

/// キャンバス座標の矩形にマスク値を塗る（切り抜き・矩形選択用）
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_fill_mask_rect(
    engine: *mut c_void,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    value: u8,
) {
    if engine.is_null() {
        return;
    }
    let handle = unsafe { engine_ref(engine) };
    let mut eng = lock_engine!(handle);
    eng.fill_mask_rect(x0, y0, x1, y1, value);
}

// =============================================================================
// 水流ブラシ（FlowField）
// =============================================================================

/// 指定レイヤーに水流ブラシのストロークをペイントする
///
/// layer_id: レイヤーID（C文字列）
/// points: ストローク点列（レイヤー画像座標系）
/// point_count: 点数
/// radius: ブラシ半径（ピクセル）
/// strength: 速度の強さ（UV単位/秒、推奨 0.05 - 0.5）
/// softness: フォールオフ（0.05 - 1.0）
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_paint_flow_stroke(
    engine: *mut c_void,
    layer_id: *const c_char,
    points: *const ArtiaStrokePoint,
    point_count: u32,
    radius: f32,
    strength: f32,
    softness: f32,
) -> bool {
    if engine.is_null() || layer_id.is_null() || points.is_null() || point_count == 0 {
        return false;
    }
    let id = match unsafe { cstr_to_str(layer_id) } {
        Some(s) => s,
        None => return false,
    };
    let handle = unsafe { engine_ref(engine) };
    let mut eng = lock_engine!(handle, false);
    let raw_slice = unsafe { std::slice::from_raw_parts(points, point_count as usize) };
    let points_vec: Vec<(f32, f32)> = raw_slice.iter().map(|p| (p.x, p.y)).collect();

    let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
        eng.paint_flow_stroke(id, &points_vec, radius, strength, softness)
    }));
    match result {
        Ok(b) => b,
        Err(_) => {
            log::error!("paint_flow_stroke でパニック発生");
            false
        }
    }
}

/// 指定レイヤーのフローフィールドをクリアする（速度ベクトル全て0）
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_clear_flow_field(
    engine: *mut c_void,
    layer_id: *const c_char,
) -> bool {
    if engine.is_null() || layer_id.is_null() {
        return false;
    }
    let id = match unsafe { cstr_to_str(layer_id) } {
        Some(s) => s,
        None => return false,
    };
    let handle = unsafe { engine_ref(engine) };
    let mut eng = lock_engine!(handle, false);
    eng.clear_flow_field(id)
}

/// 指定レイヤーのフローパラメータを設定する
///
/// enabled: フロー有効/無効
/// loop_duration: ループ周期（秒）。フェードクロスの長さ
/// speed_scale: 速度倍率（フィールド全体の強さ）
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_set_flow_params(
    engine: *mut c_void,
    layer_id: *const c_char,
    enabled: bool,
    loop_duration: f32,
    speed_scale: f32,
) -> bool {
    if engine.is_null() || layer_id.is_null() {
        return false;
    }
    let id = match unsafe { cstr_to_str(layer_id) } {
        Some(s) => s,
        None => return false,
    };
    let handle = unsafe { engine_ref(engine) };
    let mut eng = lock_engine!(handle, false);
    eng.set_flow_params(id, enabled, loop_duration, speed_scale)
}

// =============================================================================
// PSD（Phase 6で実装予定のスタブ）
// =============================================================================

/// PSDファイルからレイヤー情報を取得する
#[unsafe(no_mangle)]
pub extern "C" fn artia_psd_parse_layers(_psd_path: *const c_char) -> *mut c_char {
    log::warn!("artia_psd_parse_layers: 未実装");
    rust_str_to_c("[]")
}

/// PSDファイルからレイヤー画像データを取得する
#[unsafe(no_mangle)]
pub extern "C" fn artia_psd_extract_layer_image(
    _psd_path: *const c_char,
    _layer_index: u32,
    _out_width: *mut u32,
    _out_height: *mut u32,
) -> *mut u8 {
    log::warn!("artia_psd_extract_layer_image: 未実装");
    std::ptr::null_mut()
}

/// PSDから全レイヤーをエンジンに直接ロードする
#[unsafe(no_mangle)]
pub extern "C" fn artia_wgpu_engine_load_psd(
    _engine: *mut c_void,
    _psd_path: *const c_char,
) -> *mut c_char {
    log::warn!("artia_wgpu_engine_load_psd: 未実装");
    rust_str_to_c("[]")
}
                        