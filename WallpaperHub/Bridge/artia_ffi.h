#ifndef ARTIA_FFI_H
#define ARTIA_FFI_H

// このファイルはcbindgenにより自動生成されています。手動で編集しないでください。

#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

/**
 * Swift / C から渡すブラシ・マスクパラメータ（`BrushMaskRasterizer` と対応）
 */
typedef struct ArtiaBrushMaskRasterParams {
  float radius;
  float hardness;
  float opacity;
  float flow;
  float smoothing_percent;
  /**
   * 0 normal, 1 add, 2 subtract
   */
  uint32_t paint_mode;
  double post_blur_radius;
  int32_t edge_adjust_pixels;
  double levels_in_black;
  double levels_in_white;
  double levels_out_black;
  double levels_out_white;
  double noise_amount;
  /**
   * 0 none, 1 linear_vertical, 2 linear_horizontal, 3 radial
   */
  uint32_t gradient_kind;
  double gradient_strength;
  /**
   * 0 replace, 1 add, 2 multiply, 3 difference
   */
  uint32_t combine_mode;
} ArtiaBrushMaskRasterParams;

/**
 * ブラシストローク用ポイント（画像座標）
 */
typedef struct ArtiaStrokePoint {
  float x;
  float y;
} ArtiaStrokePoint;

/**
 * ブラシパラメータ
 */
typedef struct ArtiaBrushParams {
  float radius;
  float softness;
  bool is_erasing;
} ArtiaBrushParams;

/**
 * Rustで確保した文字列を解放する
 * Swift側は受け取った文字列をコピーした後、必ずこの関数で解放すること
 */
void artia_free_string(char *ptr);

/**
 * Rustで確保したバイト配列を解放する
 * 注意: この関数は into_boxed_slice() + mem::forget() で確保されたメモリ専用
 * (capacity == len が保証されている前提)
 */
void artia_free_bytes(uint8_t *ptr, uint32_t len);

/**
 * WallBlankのバージョン文字列を返す
 * 戻り値は artia_free_string() で解放すること
 */
char *artia_version(void);

/**
 * ログシステムを初期化する（アプリ起動時に1回呼ぶ）
 */
void artia_init(void);

/**
 * PKGファイル内の全テクスチャを指定ディレクトリにPNGとして展開する
 * 成功時: 展開されたファイルパスのJSON配列を返す (例: ["path/a.png", "path/b.png"])
 * 失敗時: {"error": "メッセージ"} 形式のJSON文字列を返す
 * 戻り値は artia_free_string() で解放すること
 */
char *artia_pkg_extract(const char *pkg_path,
                        const char *output_dir);

/**
 * WallBlank 独自フォーマット (.wallpaper) を書き出す。
 * `descriptor_json` は以下の JSON:
 * ```json
 * {
 *   "output_path": "...",
 *   "project_json": "{...}",
 *   "scene_json": "{...}",
 *   "assets": [{"name":"a.png","path":"/abs/a.png"}]
 * }
 * ```
 * 戻り値: 成功時 true / 失敗時 false (詳細は log::error!)
 */
bool artia_pkg_write(const char *descriptor_json);

/**
 * PKGファイル内のテクスチャ一覧をJSON配列で返す
 * 戻り値は artia_free_string() で解放すること
 */
char *artia_pkg_list_textures(const char *pkg_path);

/**
 * FFT バンド配列を audio uniform へ書き込む。
 * - `bands_ptr`: f32 配列 (0..1 正規化推奨)。`len` 個読む。
 * - `len`: 0 を渡せば「無音」扱いで全バンドが 0 に戻る。
 * - `time`: シェーダ位相用の経過時間 (秒)。
 */
void artia_audio_update(void *engine, const float *bands_ptr, uintptr_t len, float time);

/**
 * 直近の audio uniform 要約 (bass/mid/treble/time/active_bands) を out 配列に書き出す。
 * - `out_ptr`: f32 5 要素の領域。順に bass, mid, treble, time, active_bands。
 * - Returns: 1 = 成功, 0 = 引数不正。
 */
uint32_t artia_audio_summary(void *engine,
                             float *out_ptr);

/**
 * 指定 ParticleSystem に audio binding を設定する。
 * - `system_id`: ParticleSystemId.0
 * - `band_index`: 参照するバンド (0..127)。
 * - `scale`: 振幅倍率。`spawn_rate += band[band_index] * scale`。
 * - Returns: 1 = 成功, 0 = 該当 ID なし。
 */
uint32_t artia_audio_bind_emitter(void *engine,
                                  uint32_t system_id,
                                  uint32_t band_index,
                                  float scale);

/**
 * 指定 ParticleSystem の audio binding を解除する。
 */
uint32_t artia_audio_unbind_emitter(void *engine, uint32_t system_id);

/**
 * Skeleton を作成する。
 */
uint32_t artia_skeleton_create(void *engine, const char *descriptor_json);

/**
 * Skeleton の pose を更新する。
 */
char *artia_skeleton_update_pose(void *engine, uint32_t id, const char *params_json);

/**
 * Skeleton を破棄する。
 */
uint32_t artia_skeleton_destroy(void *engine, uint32_t id);

/**
 * 現在登録されている Skeleton 数 (テスト/メトリクス用)。
 */
uint32_t artia_skeleton_count(void *engine);

/**
 * JSON ラウンドトリップ確認用。
 */
char *artia_skeleton_validate_descriptor(const char *descriptor_json);

/**
 * 軌跡点を interleaved `[x0,y0,x1,y1,...]` で渡す。
 * 成功時: `width*height` バイトのマスク（呼び出し側が `artia_free_bytes` で解放）
 * 失敗時: null、`out_len` は 0
 */
uint8_t *artia_brush_rasterize_mask(const float *points_xy,
                                    uint32_t point_count,
                                    int32_t width,
                                    int32_t height,
                                    const struct ArtiaBrushMaskRasterParams *params,
                                    const uint8_t *existing,
                                    uint32_t existing_len,
                                    uint32_t *out_len);

/**
 * FirebaseConfig を JSON で渡して初期化する。
 * JSON 形式: `{"project_id": "...", "api_key": "...", "storage_bucket": "...", "app_id": "..."?}`
 * 二度目以降の呼び出しは既存クライアントを保持したまま true を返す (no-op)。
 */
bool artia_fb_init(const char *config_json);

/**
 * 匿名サインインしてセッション JSON を返す。
 * 戻り値は `artia_fb_free_string()` で解放すること。
 */
char *artia_fb_auth_sign_in_anonymously(void);

/**
 * カスタムトークンでサインインしてセッション JSON を返す。
 */
char *artia_fb_auth_sign_in_with_custom_token(const char *token);

/**
 * 現在の ID トークンを返す (期限が近ければ自動リフレッシュ)。
 * 戻り値 JSON: `{"id_token": "...", "local_id": "..."}` か `{"error": "..."}`.
 */
char *artia_fb_auth_current_id_token(void);

/**
 * サインアウト。Rust 側のセッションキャッシュをクリアする (no-op に近い)。
 * 注意: Firebase SDK 側のサインアウトは Swift 側で別途行うこと。
 */
bool artia_fb_auth_sign_out(void);

/**
 * ドキュメントを取得して JSON 文字列で返す。
 */
char *artia_fb_firestore_get(const char *collection, const char *doc_id);

/**
 * 新規ドキュメントを作成。`doc_id_or_null` が null なら自動採番。
 * `fields_json` は `{"key": {"stringValue":"..."}}` の Tagged JSON。
 */
char *artia_fb_firestore_create(const char *collection,
                                const char *doc_id_or_null,
                                const char *fields_json);

/**
 * ドキュメントを部分/全更新する。`mask_json_or_null` は文字列配列 JSON (例 `["a","b"]`)。
 */
char *artia_fb_firestore_update(const char *collection,
                                const char *doc_id,
                                const char *fields_json,
                                const char *mask_json_or_null);

/**
 * ドキュメントを削除する。
 */
bool artia_fb_firestore_delete(const char *collection, const char *doc_id);

/**
 * runQuery を実行してヒット Document 配列を JSON で返す。
 * `parent` は documents 配下相対パス (空文字でルート可)。
 */
char *artia_fb_firestore_query(const char *parent, const char *query_json);

/**
 * バイト列をアップロードして StorageObject JSON を返す。
 */
char *artia_fb_storage_upload(const char *path,
                              const uint8_t *data,
                              uintptr_t len,
                              const char *content_type);

/**
 * オブジェクトをダウンロードしてバイト列を返す。
 * 成功時は ptr+ *out_len を埋めて返す (`artia_fb_free_bytes` で解放)。
 * 失敗時は null を返し out_len=0 を書き込む。
 */
uint8_t *artia_fb_storage_download(const char *path, uintptr_t *out_len);

/**
 * オブジェクトを削除する。
 */
bool artia_fb_storage_delete(const char *path);

/**
 * 端末トークンを指定トピックにサブスクライブする。
 */
bool artia_fb_messaging_subscribe_topic(const char *token, const char *topic);

/**
 * 端末トークンを指定トピックからアンサブスクライブする。
 */
bool artia_fb_messaging_unsubscribe_topic(const char *token, const char *topic);

/**
 * （任意・テスト用）端末トークン宛に通知を送信する。`payload_json` は
 * `{"title":"...","body":"...","data":{...}}` 形式。
 */
bool artia_fb_messaging_send_to_token(const char *token, const char *payload_json);

/**
 * `artia_fb_*` が返した *mut c_char を解放する。
 */
void artia_fb_free_string(char *ptr);

/**
 * `artia_fb_storage_download` が返した *mut u8 を解放する。
 */
void artia_fb_free_bytes(uint8_t *ptr, uintptr_t len);

/**
 * Light レイヤーを追加する。
 * - `descriptor_json`: `LightLayerDescriptor` の JSON 文字列。
 * - 戻り値: 発行された LightLayerId.0 (1 以上) / 失敗時 0。
 */
uint32_t artia_light_create(void *engine, const char *descriptor_json);

/**
 * Light レイヤーにパラメータを部分適用する。
 * - 戻り値: 成功時 NULL / 失敗時 `{"error":"..."}` JSON 文字列 (要 `artia_free_string`)。
 */
char *artia_light_update(void *engine,
                         uint32_t id,
                         const char *params_json);

/**
 * Light レイヤーを破棄する。
 */
uint32_t artia_light_destroy(void *engine, uint32_t id);

/**
 * 現在の Light レイヤー数 (テスト/メトリクス用)。
 */
uint32_t artia_light_count(void *engine);

/**
 * 合成 RGBA からマグネット選択マスクを生成する。
 * `seeds_xy`: キャンバス座標の `[x0,y0,x1,y1,…]`。成功時 `width*height` バイト（`artia_free_bytes`）
 */
uint8_t *artia_magnetic_selection_mask(const uint8_t *rgba,
                                       uint32_t rgba_len,
                                       int32_t width,
                                       int32_t height,
                                       const float *seeds_xy,
                                       uint32_t seed_count,
                                       float tolerance_01,
                                       uint32_t combine_mode,
                                       const uint8_t *existing,
                                       uint32_t existing_len,
                                       uint32_t *out_len);

/**
 * 選択マスクを RGBA に適用（アルファのみ変更）。
 * `mode`: 0 = マスク外を透明（keep inside）, 1 = マスク内を透明（clear inside）
 */
uint8_t *artia_rgba_apply_selection_mask(const uint8_t *rgba,
                                         uint32_t rgba_len,
                                         int32_t width,
                                         int32_t height,
                                         const uint8_t *mask,
                                         uint32_t mask_len,
                                         uint32_t mode,
                                         uint32_t *out_len);

/**
 * 円形ブラシで in-place 塗布
 */
void artia_mask_paint_circle(uint8_t *data,
                             uint32_t data_len,
                             int32_t width,
                             int32_t height,
                             int32_t center_x,
                             int32_t center_y,
                             int32_t radius,
                             uint8_t value,
                             float softness,
                             uint32_t is_erasing);

/**
 * ストロークを in-place 塗布。`points_xy` は interleaved [x0,y0,x1,y1,...]
 */
void artia_mask_paint_stroke(uint8_t *data,
                             uint32_t data_len,
                             int32_t width,
                             int32_t height,
                             const float *points_xy,
                             uint32_t point_count,
                             int32_t radius,
                             uint8_t value,
                             float softness,
                             uint32_t is_erasing);

/**
 * マスクをクリア（全 0）
 */
void artia_mask_clear(uint8_t *data, uint32_t data_len);

/**
 * マスクを反転
 */
void artia_mask_invert(uint8_t *data, uint32_t data_len);

/**
 * 軸平行矩形を一様に塗る
 */
void artia_mask_fill_rect(uint8_t *data,
                          uint32_t data_len,
                          int32_t width,
                          int32_t height,
                          float x0,
                          float y0,
                          float x1,
                          float y1,
                          uint8_t value);

/**
 * ボックスブラー（半径ピクセル指定、in-place）
 */
void artia_mask_box_blur(uint8_t *data,
                         uint32_t data_len,
                         int32_t width,
                         int32_t height,
                         int32_t radius);

/**
 * 指定レイヤーにパララックス設定を割り当てる。
 * - 戻り値: 1 = 成功, 0 = 該当レイヤーなし or 引数不正。
 */
uint32_t artia_parallax_set_layer(void *engine, const char *layer_id, float depth, float strength);

/**
 * 指定レイヤーのパララックス設定を解除する。
 */
uint32_t artia_parallax_clear_layer(void *engine, const char *layer_id);

/**
 * グローバルマウスオフセットを更新する。
 * - 引数: mouse_x_norm / mouse_y_norm を -1.0..1.0 の正規化値で渡す (画面中央 = 0,0)。
 */
void artia_parallax_update(void *engine,
                           float mouse_x_norm,
                           float mouse_y_norm);

/**
 * パーティクルシステムを生成する。
 *
 * - `descriptor_json`: `ParticleSystemDescriptor` を JSON 化した C 文字列。
 * - 戻り値: 成功時に発行された `ParticleSystemId.0` (u32, 1 以上)。
 *           失敗時は 0 (= 無効 ID)。
 */
uint32_t artia_particle_create(void *engine, const char *descriptor_json);

/**
 * パーティクルシステムにパラメータを部分適用する。
 *
 * - `params_json`: `ParticleSystemParams` (各フィールドは Optional) の JSON。
 * - 戻り値: 成功時 NULL ポインタ。失敗時 `{"error":"..."}` JSON 文字列 (要 `artia_free_string`)。
 */
char *artia_particle_update(void *engine,
                            uint32_t id,
                            const char *params_json);

/**
 * パーティクルシステムを破棄する。
 * - 戻り値: 成功時 1 / 該当 ID 不在で 0。
 */
uint32_t artia_particle_destroy(void *engine, uint32_t id);

/**
 * 現在登録されているパーティクルシステム数を返す (テスト/メトリクス用)。
 */
uint32_t artia_particle_system_count(void *engine);

/**
 * 軽量な疎通確認用関数: 引数の JSON descriptor を一旦 parse → 再シリアライズして返す。
 * Why: Swift 側の Codable 表現と Rust 側 serde 表現の不整合を、エンジンを跨がずに検証できる。
 *      戻り値は `artia_free_string` で解放すること。
 */
char *artia_particle_validate_descriptor(const char *descriptor_json);

/**
 * SpanningCanvas を JSON で渡す。
 * 戻り値: 0 = 成功, 非 0 = 失敗 (エラー詳細はログへ)
 */
int32_t artia_spanning_set(void *engine, const char *json_ptr);

/**
 * スパニング設定をクリアする (各ディスプレイ独立モードへ戻す)。
 */
int32_t artia_spanning_clear(void *engine);

/**
 * 現在のスパニング状態を取得する (1 = 有効, 0 = 無効)。
 */
int32_t artia_spanning_is_active(void *engine);

/**
 * PuppetWarp を作成する。
 * - 戻り値: 1 以上の `PuppetWarpId.0` / 失敗時 0。
 */
uint32_t artia_warp_create(void *engine, const char *descriptor_json);

/**
 * PuppetWarp に handle を再適用する。
 */
char *artia_warp_update(void *engine, uint32_t id, const char *params_json);

/**
 * PuppetWarp を破棄する。
 */
uint32_t artia_warp_destroy(void *engine, uint32_t id);

/**
 * 現在登録されている PuppetWarp 数 (テスト/メトリクス用)。
 */
uint32_t artia_warp_count(void *engine);

/**
 * JSON ラウンドトリップ確認用。
 */
char *artia_warp_validate_descriptor(const char *descriptor_json);

/**
 * WGPUアニメーションエンジンを作成する
 */
void *artia_wgpu_engine_create(uint32_t canvas_width, uint32_t canvas_height);

/**
 * エンジンを破棄する
 */
void artia_wgpu_engine_destroy(void *engine);

/**
 * 出力テクスチャのIOSurfaceRefを取得する
 */
void *artia_wgpu_engine_get_output_surface(void *engine);

/**
 * 1フレームをレンダリングする
 * 戻り値: 0 = 成功, -1 = レンダリングエラー（GPUデバイスロストの可能性）
 */
int32_t artia_wgpu_engine_render_frame(void *engine, float delta_time);

/**
 * 経過時間をリセットする
 */
void artia_wgpu_engine_reset_time(void *engine);

/**
 * ビューポートサイズを設定する（IOSurface再作成）
 * 戻り値: 新しいIOSurfaceポインタ（Swift側でMTLTexture再作成に使用）
 */
void *artia_wgpu_engine_set_viewport_size(void *engine, uint32_t width, uint32_t height);

/**
 * ビューポートパラメータを更新する（ズーム・パン変更時）
 */
void artia_wgpu_engine_set_viewport_params(void *engine,
                                           float zoom,
                                           float pan_x,
                                           float pan_y,
                                           float canvas_origin_x,
                                           float canvas_origin_y);

/**
 * ビューポートモードの有効/無効を切り替える
 */
void artia_wgpu_engine_set_viewport_mode(void *engine, bool enabled);

/**
 * 現在アクティブなIOSurfaceポインタを取得する（ビューポートモード対応）
 */
void *artia_wgpu_engine_get_active_surface(void *engine);

/**
 * デバッグ用: アクティブIOSurfaceに赤いテストパターンを書き込む
 * レンダリングパイプラインの問題切り分けに使用
 */
void artia_wgpu_engine_debug_fill(void *engine);

/**
 * レイヤーを追加する
 */
char *artia_wgpu_engine_add_layer(void *engine,
                                  const char *name,
                                  uint32_t width,
                                  uint32_t height,
                                  const uint8_t *rgba_data,
                                  uint32_t data_len);

/**
 * レイヤーを削除する
 */
int32_t artia_wgpu_engine_remove_layer(void *engine, const char *layer_id);

/**
 * レイヤーの描画順序を変更する
 */
int32_t artia_wgpu_engine_reorder_layer(void *engine, const char *layer_id, uint32_t new_index);

/**
 * レイヤーIDを下から順のJSON配列（例: ["uuid1","uuid2"]）で渡し、Rust側の合成順を同期する
 */
int32_t artia_wgpu_engine_set_layer_stack_order_json(void *engine,
                                                     const char *json);

/**
 * ファイルパスから画像を読み込んでレイヤーを追加する
 * 戻り値: レイヤーID文字列（失敗時はnull）
 */
char *artia_wgpu_engine_add_layer_from_file(void *engine, const char *name, const char *file_path);

/**
 * レイヤーのテクスチャを更新する（動画フレーム差し替え用）
 */
void artia_wgpu_engine_update_layer_texture(void *engine,
                                            const char *layer_id,
                                            uint32_t width,
                                            uint32_t height,
                                            const uint8_t *rgba_data,
                                            uint32_t data_len);

/**
 * レイヤーの画像調整パラメータを設定する（JSON文字列）
 */
void artia_wgpu_engine_set_layer_adjustments(void *engine,
                                             const char *layer_id,
                                             const char *adjustments_json);

/**
 * エディタ用変形を設定する（JSON文字列）
 */
void artia_wgpu_engine_set_layer_editor_transform(void *engine,
                                                  const char *layer_id,
                                                  const char *transform_json);

/**
 * 合成結果をRGBAバイト列として取得する（エクスポート用）
 * 戻り値: RGBAデータポインタ（呼び出し側でartia_free_bytesで解放すること）
 * out_width, out_heightに幅と高さが書き込まれる
 */
uint8_t *artia_wgpu_engine_export_rgba(void *engine, uint32_t *out_width, uint32_t *out_height);

/**
 * レイヤーの変形を設定する（JSON文字列）
 */
void artia_wgpu_engine_set_layer_transform(void *engine,
                                           const char *layer_id,
                                           const char *transform_json);

/**
 * レイヤーの不透明度を設定する
 */
void artia_wgpu_engine_set_layer_opacity(void *engine, const char *layer_id, float opacity);

/**
 * レイヤーのブレンドモードを設定する
 */
void artia_wgpu_engine_set_layer_blend_mode(void *engine,
                                            const char *layer_id,
                                            uint32_t blend_mode);

/**
 * レイヤーの表示/非表示を設定する
 */
void artia_wgpu_engine_set_layer_visible(void *engine, const char *layer_id, bool visible);

/**
 * レイヤーにアニメーション設定を適用する（JSON文字列）
 */
void artia_wgpu_engine_set_layer_animation(void *engine,
                                           const char *layer_id,
                                           const char *config_json);

/**
 * カスタムキーフレームトラックを追加する（JSON文字列）
 * TODO: Phase 4で実装
 */
void artia_wgpu_engine_add_keyframe_track(void *_engine,
                                          const char *_layer_id,
                                          const char *_track_json);

/**
 * レイヤーの全キーフレームをクリアする
 * TODO: Phase 4で実装
 */
void artia_wgpu_engine_clear_keyframes(void *_engine, const char *_layer_id);

/**
 * アニメーション再生/一時停止
 */
void artia_wgpu_engine_set_playing(void *engine, bool playing);

/**
 * アニメーション時刻にシークする
 */
void artia_wgpu_engine_seek(void *engine, float time);

/**
 * 水面エフェクト設定を更新する（JSON文字列）
 */
void artia_wgpu_engine_set_water_effect(void *_engine, const char *_config_json);

/**
 * マスクテクスチャを設定する（R8フォーマット）
 */
void artia_wgpu_engine_set_mask_texture(void *engine,
                                        uint32_t width,
                                        uint32_t height,
                                        const uint8_t *mask_data,
                                        uint32_t data_len);

/**
 * マスクテクスチャをクリアする
 */
void artia_wgpu_engine_clear_mask(void *engine);

/**
 * マスクにブラシストロークを適用する（GPUマスク編集用入口）
 */
void artia_wgpu_engine_paint_mask_stroke(void *engine,
                                         const struct ArtiaStrokePoint *points,
                                         uint32_t point_count,
                                         struct ArtiaBrushParams params);

/**
 * マスクをぼかす
 */
void artia_wgpu_engine_blur_mask(void *engine, uint32_t radius);

/**
 * マスクを反転する
 */
void artia_wgpu_engine_invert_mask(void *engine);

/**
 * キャンバス座標の矩形にマスク値を塗る（切り抜き・矩形選択用）
 */
void artia_wgpu_engine_fill_mask_rect(void *engine,
                                      float x0,
                                      float y0,
                                      float x1,
                                      float y1,
                                      uint8_t value);

/**
 * 指定レイヤーに水流ブラシのストロークをペイントする
 *
 * layer_id: レイヤーID（C文字列）
 * points: ストローク点列（レイヤー画像座標系）
 * point_count: 点数
 * radius: ブラシ半径（ピクセル）
 * strength: 速度の強さ（UV単位/秒、推奨 0.05 - 0.5）
 * softness: フォールオフ（0.05 - 1.0）
 */
bool artia_wgpu_engine_paint_flow_stroke(void *engine,
                                         const char *layer_id,
                                         const struct ArtiaStrokePoint *points,
                                         uint32_t point_count,
                                         float radius,
                                         float strength,
                                         float softness);

/**
 * 指定レイヤーのフローフィールドをクリアする（速度ベクトル全て0）
 */
bool artia_wgpu_engine_clear_flow_field(void *engine, const char *layer_id);

/**
 * 指定レイヤーのフローパラメータを設定する
 *
 * enabled: フロー有効/無効
 * loop_duration: ループ周期（秒）。フェードクロスの長さ
 * speed_scale: 速度倍率（フィールド全体の強さ）
 */
bool artia_wgpu_engine_set_flow_params(void *engine,
                                       const char *layer_id,
                                       bool enabled,
                                       float loop_duration,
                                       float speed_scale);

/**
 * PSDファイルからレイヤー情報を取得する
 */
char *artia_psd_parse_layers(const char *_psd_path);

/**
 * PSDファイルからレイヤー画像データを取得する
 */
uint8_t *artia_psd_extract_layer_image(const char *_psd_path,
                                       uint32_t _layer_index,
                                       uint32_t *_out_width,
                                       uint32_t *_out_height);

/**
 * PSDから全レイヤーをエンジンに直接ロードする
 */
char *artia_wgpu_engine_load_psd(void *_engine, const char *_psd_path);

#endif  /* ARTIA_FFI_H */
