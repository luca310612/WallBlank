import Foundation
import IOSurface

/// Rust FFI のSwift側ラッパー
/// C関数を安全なSwift APIとして提供する
enum RustCore {

    /// Rustコアを初期化する（アプリ起動時に1回呼ぶ）
    static func initialize() {
        artia_init()
        let version = self.version()
        print("[RustCore] 初期化完了 - Rustコア v\(version)")
    }

    /// Rustコアのバージョンを取得する
    static func version() -> String {
        guard let ptr = artia_version() else {
            return "不明"
        }
        let version = String(cString: ptr)
        artia_free_string(ptr)
        return version
    }

    // MARK: - PKG関連

    /// PKGファイル内の全テクスチャをPNGとして展開する
    /// - Parameters:
    ///   - pkgPath: PKGファイルのパス
    ///   - outputDir: 出力ディレクトリのパス
    /// - Returns: 展開されたファイルパスの配列、失敗時はnil
    static func extractPkg(pkgPath: String, outputDir: String) -> [String]? {
        guard let ptr = artia_pkg_extract(pkgPath, outputDir) else {
            return nil
        }
        let json = String(cString: ptr)
        artia_free_string(ptr)

        // エラーチェック
        if json.contains("\"error\"") {
            print("[RustCore] PKG展開エラー: \(json)")
            return nil
        }

        // JSON配列をデコード
        guard let data = json.data(using: .utf8),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return paths
    }

    /// PKGファイル内のテクスチャ一覧を取得する
    /// - Parameter pkgPath: PKGファイルのパス
    /// - Returns: テクスチャ情報の配列
    static func listPkgTextures(pkgPath: String) -> [[String: Any]]? {
        guard let ptr = artia_pkg_list_textures(pkgPath) else {
            return nil
        }
        let json = String(cString: ptr)
        artia_free_string(ptr)

        if json.contains("\"error\"") {
            print("[RustCore] PKGテクスチャ一覧エラー: \(json)")
            return nil
        }

        guard let data = json.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return result
    }

    // MARK: - ブラシ選択マスク（Rust）

    /// キャンバス座標の点列（`[x0,y0,x1,y1,…]`）からグレースケールマスクを生成する
    static func brushRasterizeMask(
        pointsInterleavedXY: [Float],
        pointCount: UInt32,
        canvasWidth: Int32,
        canvasHeight: Int32,
        params: UnsafeMutablePointer<ArtiaBrushMaskRasterParams>,
        existingMask: [UInt8]?
    ) -> [UInt8]? {
        let expected = Int(canvasWidth) * Int(canvasHeight)
        guard expected > 0, pointsInterleavedXY.count == Int(pointCount) * 2 else { return nil }

        var outLen: UInt32 = 0
        return pointsInterleavedXY.withUnsafeBufferPointer { xyBuf in
            guard let xyBase = xyBuf.baseAddress else { return nil }
            if let ex = existingMask {
                guard ex.count == expected else { return nil }
                return ex.withUnsafeBufferPointer { exBuf in
                    guard let exBase = exBuf.baseAddress else { return nil }
                    guard let raw = artia_brush_rasterize_mask(
                        xyBase,
                        pointCount,
                        canvasWidth,
                        canvasHeight,
                        params,
                        exBase,
                        UInt32(ex.count),
                        &outLen
                    ) else { return nil }
                    defer { artia_free_bytes(raw, outLen) }
                    guard Int(outLen) == expected else { return nil }
                    return Array(UnsafeBufferPointer(start: raw, count: Int(outLen)))
                }
            } else {
                guard let raw = artia_brush_rasterize_mask(
                    xyBase,
                    pointCount,
                    canvasWidth,
                    canvasHeight,
                    params,
                    nil,
                    0,
                    &outLen
                ) else { return nil }
                defer { artia_free_bytes(raw, outLen) }
                guard Int(outLen) == expected else { return nil }
                return Array(UnsafeBufferPointer(start: raw, count: Int(outLen)))
            }
        }
    }

    /// `params` を inout で渡すラッパー（呼び出し側でスタック上の構造体を渡しやすくする）
    static func brushRasterizeMask(
        pointsInterleavedXY: [Float],
        pointCount: UInt32,
        canvasWidth: Int32,
        canvasHeight: Int32,
        params: inout ArtiaBrushMaskRasterParams,
        existingMask: [UInt8]?
    ) -> [UInt8]? {
        withUnsafeMutablePointer(to: &params) { ptr in
            brushRasterizeMask(
                pointsInterleavedXY: pointsInterleavedXY,
                pointCount: pointCount,
                canvasWidth: canvasWidth,
                canvasHeight: canvasHeight,
                params: ptr,
                existingMask: existingMask
            )
        }
    }

    // MARK: - マグネット選択・RGBAマスク（Rust / artia-core）

    /// 合成 RGBA からマグネット選択マスクを生成する（ロジックは `artia_core::magnetic_select`）
    static func magneticSelectionMask(
        rgba: [UInt8],
        width: Int,
        height: Int,
        seedsInterleavedXY: [Float],
        seedCount: UInt32,
        tolerance01: Float,
        combineMode: UInt32,
        existingMask: [UInt8]?
    ) -> [UInt8]? {
        let w = width
        let h = height
        let expected = w * h
        let rgbaNeed = expected * 4
        guard w > 0, h > 0, rgba.count >= rgbaNeed,
              seedsInterleavedXY.count == Int(seedCount) * 2 else { return nil }

        var outLen: UInt32 = 0
        return rgba.withUnsafeBufferPointer { rgbaBuf in
            guard let rgbaBase = rgbaBuf.baseAddress else { return nil }
            return seedsInterleavedXY.withUnsafeBufferPointer { seedsBuf in
                guard let seedsBase = seedsBuf.baseAddress else { return nil }
                if let ex = existingMask {
                    guard ex.count == expected else { return nil }
                    return ex.withUnsafeBufferPointer { exBuf in
                        guard let exBase = exBuf.baseAddress else { return nil }
                        guard let raw = artia_magnetic_selection_mask(
                            rgbaBase,
                            UInt32(rgbaNeed),
                            Int32(w),
                            Int32(h),
                            seedsBase,
                            seedCount,
                            tolerance01,
                            combineMode,
                            exBase,
                            UInt32(ex.count),
                            &outLen
                        ) else { return nil }
                        defer { artia_free_bytes(raw, outLen) }
                        guard Int(outLen) == expected else { return nil }
                        return Array(UnsafeBufferPointer(start: raw, count: Int(outLen)))
                    }
                } else {
                    guard let raw = artia_magnetic_selection_mask(
                        rgbaBase,
                        UInt32(rgbaNeed),
                        Int32(w),
                        Int32(h),
                        seedsBase,
                        seedCount,
                        tolerance01,
                        combineMode,
                        nil,
                        0,
                        &outLen
                    ) else { return nil }
                    defer { artia_free_bytes(raw, outLen) }
                    guard Int(outLen) == expected else { return nil }
                    return Array(UnsafeBufferPointer(start: raw, count: Int(outLen)))
                }
            }
        }
    }

    /// 選択マスクを RGBA に適用する（アルファチャンネルのみ変更）
    static func rgbaApplySelectionMask(
        rgba: Data,
        width: Int,
        height: Int,
        mask: [UInt8],
        keepInside: Bool
    ) -> Data? {
        let w = width
        let h = height
        let expected = w * h
        let rgbaNeed = expected * 4
        guard w > 0, h > 0, rgba.count >= rgbaNeed, mask.count == expected else { return nil }
        var outLen: UInt32 = 0
        let mode: UInt32 = keepInside ? 0 : 1
        return rgba.withUnsafeBytes { rgbaRaw in
            guard let rgbaBase = rgbaRaw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return mask.withUnsafeBufferPointer { maskBuf in
                guard let maskBase = maskBuf.baseAddress else { return nil }
                guard let raw = artia_rgba_apply_selection_mask(
                    rgbaBase,
                    UInt32(rgbaNeed),
                    Int32(w),
                    Int32(h),
                    maskBase,
                    UInt32(mask.count),
                    mode,
                    &outLen
                ) else { return nil }
                defer { artia_free_bytes(raw, outLen) }
                guard Int(outLen) == rgbaNeed else { return nil }
                return Data(UnsafeBufferPointer(start: raw, count: Int(outLen)))
            }
        }
    }

    // MARK: - WGPUアニメーションエンジン

    /// WGPUアニメーションエンジンを作成する
    /// - Parameters:
    ///   - width: キャンバス幅
    ///   - height: キャンバス高さ
    /// - Returns: エンジンハンドル（失敗時はnil）
    static func createWgpuEngine(width: UInt32, height: UInt32) -> UnsafeMutableRawPointer? {
        let engine = artia_wgpu_engine_create(width, height)
        if engine != nil {
            print("[RustCore] WGPUエンジン作成成功 (\(width)x\(height))")
        } else {
            print("[RustCore] WGPUエンジン作成失敗")
        }
        return engine
    }

    /// WGPUエンジンを破棄する
    static func destroyWgpuEngine(_ engine: UnsafeMutableRawPointer) {
        artia_wgpu_engine_destroy(engine)
        print("[RustCore] WGPUエンジン破棄完了")
    }

    /// IOSurfaceRefを取得する（Swift側で MTLDevice.makeTexture(iosurface:) に使用）
    static func getWgpuOutputSurface(_ engine: UnsafeMutableRawPointer) -> IOSurfaceRef? {
        guard let ptr = artia_wgpu_engine_get_output_surface(engine) else {
            return nil
        }
        // UnsafeMutableRawPointer → IOSurfaceRef に変換
        return unsafeBitCast(ptr, to: IOSurfaceRef.self)
    }

    // MARK: - ビューポート管理

    /// ビューポートサイズを設定する（IOSurface再作成）
    /// - Returns: 新しいIOSurfaceRef（MTLTexture再作成用）
    static func wgpuSetViewportSize(
        _ engine: UnsafeMutableRawPointer,
        width: UInt32,
        height: UInt32
    ) -> IOSurfaceRef? {
        guard let ptr = artia_wgpu_engine_set_viewport_size(engine, width, height) else {
            return nil
        }
        return unsafeBitCast(ptr, to: IOSurfaceRef.self)
    }

    /// ビューポートパラメータを更新する（ズーム・パン変更時）
    static func wgpuSetViewportParams(
        _ engine: UnsafeMutableRawPointer,
        zoom: Float,
        panX: Float,
        panY: Float,
        canvasOriginX: Float,
        canvasOriginY: Float
    ) {
        artia_wgpu_engine_set_viewport_params(engine, zoom, panX, panY, canvasOriginX, canvasOriginY)
    }

    /// ビューポートモードを設定する
    static func wgpuSetViewportMode(_ engine: UnsafeMutableRawPointer, enabled: Bool) {
        artia_wgpu_engine_set_viewport_mode(engine, enabled)
    }

    /// 現在アクティブなIOSurfaceRefを取得する（ビューポートモード対応）
    static func getWgpuActiveSurface(_ engine: UnsafeMutableRawPointer) -> IOSurfaceRef? {
        guard let ptr = artia_wgpu_engine_get_active_surface(engine) else {
            return nil
        }
        return unsafeBitCast(ptr, to: IOSurfaceRef.self)
    }

    /// WGPUエンジンで1フレームをレンダリングする
    /// - Returns: true = 成功, false = エラー（GPUデバイスロストの可能性）
    @discardableResult
    static func wgpuRenderFrame(_ engine: UnsafeMutableRawPointer, deltaTime: Float) -> Bool {
        return artia_wgpu_engine_render_frame(engine, deltaTime) == 0
    }

    /// WGPUエンジンの経過時間をリセットする
    static func wgpuResetTime(_ engine: UnsafeMutableRawPointer) {
        artia_wgpu_engine_reset_time(engine)
    }

    /// WGPUエンジンにレイヤーを追加する
    /// - Parameters:
    ///   - engine: エンジンハンドル
    ///   - name: レイヤー名
    ///   - width: テクスチャ幅
    ///   - height: テクスチャ高さ
    ///   - rgbaData: RGBA8ピクセルデータ
    /// - Returns: レイヤーID（UUID文字列）
    static func wgpuAddLayer(
        _ engine: UnsafeMutableRawPointer,
        name: String,
        width: UInt32,
        height: UInt32,
        rgbaData: Data
    ) -> String? {
        return rgbaData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            guard let ptr = artia_wgpu_engine_add_layer(
                engine, name, width, height, baseAddress, UInt32(rgbaData.count)
            ) else {
                return nil
            }
            let layerId = String(cString: ptr)
            artia_free_string(ptr)
            return layerId
        }
    }

    /// ファイルパスから画像を読み込んでレイヤーを追加する
    /// - Parameters:
    ///   - engine: エンジンハンドル
    ///   - name: レイヤー名
    ///   - filePath: 画像ファイルパス
    /// - Returns: レイヤーID（UUID文字列）、失敗時はnil
    static func wgpuAddLayerFromFile(
        _ engine: UnsafeMutableRawPointer,
        name: String,
        filePath: String
    ) -> String? {
        guard let ptr = artia_wgpu_engine_add_layer_from_file(engine, name, filePath) else {
            print("[RustCore] 画像レイヤー追加失敗: \(filePath)")
            return nil
        }
        let layerId = String(cString: ptr)
        artia_free_string(ptr)
        print("[RustCore] 画像レイヤー追加成功: \(name) (ID: \(layerId))")
        return layerId
    }

    /// レイヤーのテクスチャを更新する（動画フレーム差し替え用）
    /// - Parameters:
    ///   - engine: エンジンハンドル
    ///   - layerId: レイヤーID
    ///   - width: テクスチャ幅
    ///   - height: テクスチャ高さ
    ///   - rgbaData: RGBA8ピクセルデータ
    static func wgpuUpdateLayerTexture(
        _ engine: UnsafeMutableRawPointer,
        layerId: String,
        width: UInt32,
        height: UInt32,
        rgbaData: Data
    ) {
        rgbaData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            artia_wgpu_engine_update_layer_texture(
                engine, layerId, width, height, baseAddress, UInt32(rgbaData.count)
            )
        }
    }

    /// レイヤーの画像調整パラメータを設定する（JSON文字列）
    static func wgpuSetLayerAdjustments(
        _ engine: UnsafeMutableRawPointer,
        layerId: String,
        adjustmentsJson: String
    ) {
        artia_wgpu_engine_set_layer_adjustments(engine, layerId, adjustmentsJson)
    }

    /// エディタ用変形を設定する（JSON文字列）
    static func wgpuSetLayerEditorTransform(
        _ engine: UnsafeMutableRawPointer,
        layerId: String,
        transformJson: String
    ) {
        artia_wgpu_engine_set_layer_editor_transform(engine, layerId, transformJson)
    }

    /// 合成結果をRGBAバイト列として取得する（エクスポート用）
    /// - Parameter engine: エンジンハンドル
    /// - Returns: (RGBAデータ, 幅, 高さ)、失敗時はnil
    static func wgpuExportRGBA(_ engine: UnsafeMutableRawPointer) -> (Data, UInt32, UInt32)? {
        var width: UInt32 = 0
        var height: UInt32 = 0
        guard let ptr = artia_wgpu_engine_export_rgba(engine, &width, &height) else {
            print("[RustCore] RGBA エクスポート失敗")
            return nil
        }
        let byteCount = Int(width * height * 4)
        let data = Data(bytes: ptr, count: byteCount)
        artia_free_bytes(ptr, UInt32(byteCount))
        return (data, width, height)
    }

    /// WGPUエンジンからレイヤーを削除する
    @discardableResult
    static func wgpuRemoveLayer(_ engine: UnsafeMutableRawPointer, layerId: String) -> Bool {
        return artia_wgpu_engine_remove_layer(engine, layerId) == 1
    }

    /// レイヤーの描画順序を変更する
    @discardableResult
    static func wgpuReorderLayer(
        _ engine: UnsafeMutableRawPointer,
        layerId: String,
        newIndex: UInt32
    ) -> Bool {
        return artia_wgpu_engine_reorder_layer(engine, layerId, newIndex) == 1
    }

    /// 下から順のレイヤーIDのJSON配列で、Rust側の合成順をSwiftと完全一致させる
    @discardableResult
    static func wgpuSetLayerStackOrderJson(
        _ engine: UnsafeMutableRawPointer,
        json: String
    ) -> Bool {
        return artia_wgpu_engine_set_layer_stack_order_json(engine, json) == 1
    }

    /// キャンバス座標の矩形にマスク値を塗る（0=透明、255=不透明）
    static func wgpuFillMaskRect(
        _ engine: UnsafeMutableRawPointer,
        x0: Float,
        y0: Float,
        x1: Float,
        y1: Float,
        value: UInt8
    ) {
        artia_wgpu_engine_fill_mask_rect(engine, x0, y0, x1, y1, value)
    }

    /// レイヤーの変形を設定する（JSON文字列）
    static func wgpuSetLayerTransform(
        _ engine: UnsafeMutableRawPointer,
        layerId: String,
        transformJson: String
    ) {
        artia_wgpu_engine_set_layer_transform(engine, layerId, transformJson)
    }

    /// レイヤーの不透明度を設定する
    static func wgpuSetLayerOpacity(
        _ engine: UnsafeMutableRawPointer,
        layerId: String,
        opacity: Float
    ) {
        artia_wgpu_engine_set_layer_opacity(engine, layerId, opacity)
    }

    /// レイヤーのブレンドモードを設定する
    static func wgpuSetLayerBlendMode(
        _ engine: UnsafeMutableRawPointer,
        layerId: String,
        blendMode: UInt32
    ) {
        artia_wgpu_engine_set_layer_blend_mode(engine, layerId, blendMode)
    }

    /// レイヤーの表示/非表示を設定する
    static func wgpuSetLayerVisible(
        _ engine: UnsafeMutableRawPointer,
        layerId: String,
        visible: Bool
    ) {
        artia_wgpu_engine_set_layer_visible(engine, layerId, visible)
    }

    /// レイヤーにアニメーション設定を適用する（JSON文字列）
    static func wgpuSetLayerAnimation(
        _ engine: UnsafeMutableRawPointer,
        layerId: String,
        configJson: String
    ) {
        artia_wgpu_engine_set_layer_animation(engine, layerId, configJson)
    }

    /// カスタムキーフレームトラックを追加する（JSON文字列）
    static func wgpuAddKeyframeTrack(
        _ engine: UnsafeMutableRawPointer,
        layerId: String,
        
        trackJson: String
    ) {
        artia_wgpu_engine_add_keyframe_track(engine, layerId, trackJson)
    }

    /// アニメーション再生/一時停止
    static func wgpuSetPlaying(_ engine: UnsafeMutableRawPointer, playing: Bool) {
        artia_wgpu_engine_set_playing(engine, playing)
    }

    /// アニメーション時刻にシークする
    static func wgpuSeek(_ engine: UnsafeMutableRawPointer, time: Float) {
        artia_wgpu_engine_seek(engine, time)
    }

    /// 水面エフェクト設定を更新する（JSON文字列）
    static func wgpuSetWaterEffect(_ engine: UnsafeMutableRawPointer, configJson: String) {
        artia_wgpu_engine_set_water_effect(engine, configJson)
    }

    /// マスクテクスチャを設定する（R8フォーマット）
    static func wgpuSetMaskTexture(
        _ engine: UnsafeMutableRawPointer,
        width: UInt32,
        height: UInt32,
        maskData: Data
    ) {
        maskData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            artia_wgpu_engine_set_mask_texture(engine, width, height, baseAddress, UInt32(maskData.count))
        }
    }

    /// マスクテクスチャをクリアする
    static func wgpuClearMask(_ engine: UnsafeMutableRawPointer) {
        artia_wgpu_engine_clear_mask(engine)
    }

    // MARK: - マスク編集（GPUブラシ用の入口）

    struct MaskStrokePoint {
        var x: Float
        var y: Float
    }

    struct BrushParams {
        var radius: Float
        var softness: Float
        var isErasing: Bool
    }

    /// マスクにブラシストロークを適用する
    static func wgpuPaintMaskStroke(
        _ engine: UnsafeMutableRawPointer,
        points: [MaskStrokePoint],
        params: BrushParams
    ) {
        guard !points.isEmpty else { return }

        let cParams = ArtiaBrushParams(
            radius: params.radius,
            softness: params.softness,
            is_erasing: params.isErasing
        )

        let localPoints = points.map { point in
            ArtiaStrokePoint(x: point.x, y: point.y)
        }

        localPoints.withUnsafeBufferPointer { buffer in
            artia_wgpu_engine_paint_mask_stroke(
                engine,
                buffer.baseAddress,
                UInt32(buffer.count),
                cParams
            )
        }
    }

    /// マスクをぼかす
    static func wgpuBlurMask(_ engine: UnsafeMutableRawPointer, radius: UInt32) {
        artia_wgpu_engine_blur_mask(engine, radius)
    }

    /// マスクを反転する
    static func wgpuInvertMask(_ engine: UnsafeMutableRawPointer) {
        artia_wgpu_engine_invert_mask(engine)
    }

    // MARK: - 水流ブラシ（FlowField）

    /// 水流ブラシ用ストローク点（レイヤー画像座標系）
    struct FlowStrokePoint {
        var x: Float
        var y: Float
    }

    /// 水流ブラシパラメータ
    struct FlowBrushParams {
        /// ブラシ半径（ピクセル）
        var radius: Float
        /// 速度の強さ（UV/秒、推奨 0.05 - 0.5）
        var strength: Float
        /// フォールオフ（0.05 - 1.0、大きいほど中心に集中）
        var softness: Float
    }

    /// 指定レイヤーに水流ブラシのストロークをペイントする
    @discardableResult
    static func wgpuPaintFlowStroke(
        _ engine: UnsafeMutableRawPointer,
        layerId: String,
        points: [FlowStrokePoint],
        params: FlowBrushParams
    ) -> Bool {
        guard !points.isEmpty else { return false }
        let localPoints = points.map { ArtiaStrokePoint(x: $0.x, y: $0.y) }
        return localPoints.withUnsafeBufferPointer { buffer in
            layerId.withCString { idPtr in
                artia_wgpu_engine_paint_flow_stroke(
                    engine,
                    idPtr,
                    buffer.baseAddress,
                    UInt32(buffer.count),
                    params.radius,
                    params.strength,
                    params.softness
                )
            }
        }
    }

    /// 指定レイヤーのフローフィールドをクリアする
    @discardableResult
    static func wgpuClearFlowField(
        _ engine: UnsafeMutableRawPointer,
        layerId: String
    ) -> Bool {
        return layerId.withCString { idPtr in
            artia_wgpu_engine_clear_flow_field(engine, idPtr)
        }
    }

    /// 指定レイヤーの水流パラメータを設定する
    /// - Parameters:
    ///   - enabled: フロー有効/無効
    ///   - loopDuration: ループ周期（秒、推奨 2.0）
    ///   - speedScale: 速度倍率（推奨 0.05）
    @discardableResult
    static func wgpuSetFlowParams(
        _ engine: UnsafeMutableRawPointer,
        layerId: String,
        enabled: Bool,
        loopDuration: Float,
        speedScale: Float
    ) -> Bool {
        return layerId.withCString { idPtr in
            artia_wgpu_engine_set_flow_params(
                engine,
                idPtr,
                enabled,
                loopDuration,
                speedScale
            )
        }
    }

    // MARK: - デバッグ

    /// デバッグ用: IOSurfaceに赤色テストパターンを書き込む
    /// レンダリングパイプラインの問題切り分けに使用
    static func wgpuDebugFill(_ engine: UnsafeMutableRawPointer) {
        artia_wgpu_engine_debug_fill(engine)
        print("[RustCore] デバッグ: IOSurface赤色塗りつぶし完了")
    }

    // MARK: - マスクペイント FFI（MaskData ホットパス）
    // Why: Swift の二重ループで重かった paint/paintStroke/blur/invert/clear/fillRect を Rust へ集約。

    /// 円形ブラシで in-place 塗布
    static func maskPaintCircle(
        data: inout [UInt8],
        width: Int32,
        height: Int32,
        centerX: Int32,
        centerY: Int32,
        radius: Int32,
        value: UInt8,
        softness: Float,
        isErasing: Bool
    ) {
        let len = UInt32(data.count)
        data.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            artia_mask_paint_circle(
                base,
                len,
                width,
                height,
                centerX,
                centerY,
                radius,
                value,
                softness,
                isErasing ? 1 : 0
            )
        }
    }

    /// 点列ストロークを in-place 塗布
    static func maskPaintStroke(
        data: inout [UInt8],
        width: Int32,
        height: Int32,
        pointsXY: [Float],
        radius: Int32,
        value: UInt8,
        softness: Float,
        isErasing: Bool
    ) {
        let len = UInt32(data.count)
        let count = UInt32(pointsXY.count / 2)
        guard count > 0 else { return }
        data.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            pointsXY.withUnsafeBufferPointer { ptsBuf in
                guard let ptsBase = ptsBuf.baseAddress else { return }
                artia_mask_paint_stroke(
                    base,
                    len,
                    width,
                    height,
                    ptsBase,
                    count,
                    radius,
                    value,
                    softness,
                    isErasing ? 1 : 0
                )
            }
        }
    }

    /// マスクをクリア
    static func maskClear(data: inout [UInt8]) {
        let len = UInt32(data.count)
        data.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            artia_mask_clear(base, len)
        }
    }

    /// マスクを反転
    static func maskInvert(data: inout [UInt8]) {
        let len = UInt32(data.count)
        data.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            artia_mask_invert(base, len)
        }
    }

    /// 軸平行矩形を一様に塗る
    static func maskFillRect(
        data: inout [UInt8],
        width: Int32,
        height: Int32,
        x0: Float,
        y0: Float,
        x1: Float,
        y1: Float,
        value: UInt8
    ) {
        let len = UInt32(data.count)
        data.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            artia_mask_fill_rect(base, len, width, height, x0, y0, x1, y1, value)
        }
    }

    /// ボックスブラー（in-place）
    static func maskBoxBlur(
        data: inout [UInt8],
        width: Int32,
        height: Int32,
        radius: Int32
    ) {
        let len = UInt32(data.count)
        data.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            artia_mask_box_blur(base, len, width, height, radius)
        }
    }
}
