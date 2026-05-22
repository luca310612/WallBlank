import Foundation
import AppKit
import AVFoundation
import Combine
import MetalKit
import UniformTypeIdentifiers

// MARK: - ImageEditorManager + Layers
// Why: レイヤー追加(画像/動画)、選択、削除、複製、結合、移動を集約。

extension ImageEditorManager {

    func selectLayer(_ id: UUID?) {
        selectedLayerID = id
        project.selectedLayerID = id
    }

    @discardableResult
    func selectLayerAtCanvasPoint(_ point: CGPoint) -> EditorLayer? {
        let hit = CanvasHitTester.hitTest(
            point: point,
            layers: project.layers,
            canvasSize: project.canvasSize
        )
        selectLayer(hit?.id)
        return hit
    }

    func addLayer(from image: NSImage, name: String? = nil) {
        saveUndoSnapshot(description: "レイヤー追加")

        let layer = EditorLayer(name: name ?? "レイヤー \(project.layers.count + 1)")

        if let device = renderer?.metalDevice {
            layer.loadTexture(from: image, device: device)
        }

        // Rust WGPUエンジンにもレイヤーを追加（RGBAデータ変換）
        if let engine = wgpuEngine, let rgbaData = imageToRGBA(image) {
            let w = UInt32(layer.imageWidth)
            let h = UInt32(layer.imageHeight)
            layer.rustLayerID = RustCore.wgpuAddLayer(
                engine, name: layer.name, width: w, height: h, rgbaData: rgbaData
            )
        }

        // 画像解像度に基づいてキャンバスにフィットする初期transformを計算
        fitLayerToCanvas(layer)

        // transform設定後にRust側に同期
        if wgpuEngine != nil, let rustID = layer.rustLayerID {
            syncLayerPropertiesToRust(layer, rustLayerID: rustID)
        }

        project.layers.append(layer)
        syncRustLayerStackOrder()
        selectLayer(layer.id)
        isModified = true
        requestRender()

        debugLog("[ImageEditorManager] レイヤー追加: \(layer.name)")
    }

    func addLayer(from url: URL, name: String? = nil) {
        let layerName = name ?? url.deletingPathExtension().lastPathComponent

        saveUndoSnapshot(description: "レイヤー追加")

        let layer = EditorLayer(name: layerName)

        // Rust WGPUエンジンでファイルを直接読み込む（image crateで効率的に処理）
        debugLog("[ImageEditorManager] addLayer開始: engine=\(wgpuEngine != nil), path=\(url.path)")
        if let engine = wgpuEngine {
            if let rustID = RustCore.wgpuAddLayerFromFile(engine, name: layerName, filePath: url.path) {
                layer.rustLayerID = rustID
                layer.imagePath = url.path
                debugLog("[ImageEditorManager] Rustレイヤー登録成功: ID=\(rustID)")
                // 画像サイズの取得（NSImageから）
                if let image = NSImage(contentsOf: url),
                   let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    layer.imageWidth = cgImage.width
                    layer.imageHeight = cgImage.height
                    debugLog("[ImageEditorManager] 画像サイズ: \(cgImage.width)x\(cgImage.height)")
                }
                // Metal側のテクスチャも読み込む（サムネイル等の用途）
                if let device = renderer?.metalDevice {
                    layer.loadTexture(from: url, device: device)
                }
                // レイヤープロパティをRust側に即座に同期（EditorTransform含む）
                syncLayerPropertiesToRust(layer, rustLayerID: rustID)
            } else {
                debugLog("[ImageEditorManager] Rust画像読み込み失敗: \(url.path)")
                return
            }
        } else {
            // フォールバック: 従来のMetal方式
            guard let image = NSImage(contentsOf: url) else {
                debugLog("[ImageEditorManager] 画像読み込み失敗: \(url.path)")
                return
            }
            layer.imagePath = url.path
            if let device = renderer?.metalDevice {
                layer.loadTexture(from: image, device: device)
            }
        }

        // 画像解像度に基づいてキャンバスにフィットする初期transformを計算
        fitLayerToCanvas(layer)

        // transform設定後にRust側に再同期
        if wgpuEngine != nil, let rustID = layer.rustLayerID {
            syncLayerPropertiesToRust(layer, rustLayerID: rustID)
        }

        project.layers.append(layer)
        syncRustLayerStackOrder()
        selectLayer(layer.id)
        isModified = true
        requestRender()

        debugLog("[ImageEditorManager] レイヤー追加: \(layer.name)")
    }

    func fitLayerToCanvas(_ layer: EditorLayer) {
        let imgW = CGFloat(layer.imageWidth > 0 ? layer.imageWidth : layer.videoWidth)
        let imgH = CGFloat(layer.imageHeight > 0 ? layer.imageHeight : layer.videoHeight)
        let canvasW = CGFloat(project.canvasWidth)
        let canvasH = CGFloat(project.canvasHeight)
        guard imgW > 0, imgH > 0, canvasW > 0, canvasH > 0 else { return }

        // アスペクト比を維持してキャンバスにフィットするスケールを計算
        // scale=1.0で元ピクセルサイズなので、キャンバスに収まるには
        // min(canvasW/imgW, canvasH/imgH) のスケールが必要
        let fitScale = Float(min(canvasW / imgW, canvasH / imgH))

        layer.transform = LayerTransform(
            offsetX: 0, offsetY: 0,
            scaleX: fitScale, scaleY: fitScale,
            rotation: 0,
            flipHorizontal: false, flipVertical: false
        )
        debugLog("[ImageEditorManager] レイヤーフィット: 画像\(Int(imgW))x\(Int(imgH)) → キャンバス\(Int(canvasW))x\(Int(canvasH)) (fitScale=\(String(format: "%.2f", fitScale)))")
    }

    func imageToRGBA(_ image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let w = cgImage.width
        let h = cgImage.height
        let bytesPerRow = w * 4
        var data = Data(count: h * bytesPerRow)

        data.withUnsafeMutableBytes { rawBuffer in
            guard let ptr = rawBuffer.baseAddress else { return }
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: ptr,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        }

        return data
    }

    func exportCompositeRGBAForSelection() -> (rgba: Data, width: Int, height: Int)? {
        if let engine = wgpuEngine {
            // ビューポートモードを一時的に無効化してキャンバス解像度でエクスポート
            RustCore.wgpuSetViewportMode(engine, enabled: false)
            let out = RustCore.wgpuExportRGBA(engine)
            RustCore.wgpuSetViewportMode(engine, enabled: true)
            if let (data, w, h) = out {
                return (data, Int(w), Int(h))
            }
            return nil
        }

        // フォールバック: 従来レンダラーで合成してNSImage→RGBA
        renderer?.composeLayers(project.layers, canvasSize: project.canvasSize)
        guard let img = renderer?.exportAsImage(), let rgba = imageToRGBA(img) else { return nil }
        return (rgba, project.canvasWidth, project.canvasHeight)
    }

    func buildMagneticSelectionMask(
        seedCanvasPoints: [CGPoint],
        tolerance01: Float = 0.12,
        combineMode: EditorMaskCombineMode
    ) -> SelectionMask? {
        guard !seedCanvasPoints.isEmpty else { return nil }
        guard let exported = exportCompositeRGBAForSelection() else { return nil }
        let w = exported.width
        let h = exported.height
        guard w > 0, h > 0, exported.rgba.count >= w * h * 4 else { return nil }
        let bytes = [UInt8](exported.rgba)
        return Self.computeMagneticSelectionMaskFromRGBA(
            bytes: bytes,
            width: w,
            height: h,
            seedCanvasPoints: seedCanvasPoints,
            tolerance01: tolerance01,
            combineMode: combineMode,
            existing: selection.mask
        )
    }

    static func computeMagneticSelectionMaskFromRGBA(
        bytes: [UInt8],
        width w: Int,
        height h: Int,
        seedCanvasPoints: [CGPoint],
        tolerance01: Float,
        combineMode: EditorMaskCombineMode,
        existing: SelectionMask?
    ) -> SelectionMask? {
        guard w > 0, h > 0, !seedCanvasPoints.isEmpty else { return nil }
        let expected = w * h
        guard bytes.count >= expected * 4 else { return nil }

        var interleaved = [Float](repeating: 0, count: seedCanvasPoints.count * 2)
        for (i, p) in seedCanvasPoints.enumerated() {
            interleaved[i * 2] = Float(p.x)
            interleaved[i * 2 + 1] = Float(p.y)
        }

        let existingBytes: [UInt8]?
        if let ex = existing,
           ex.width == w, ex.height == h, ex.data.count == expected {
            existingBytes = ex.data
        } else {
            existingBytes = nil
        }

        let combineU = editorMaskCombineModeU32(combineMode)
        guard let data = RustCore.magneticSelectionMask(
            rgba: bytes,
            width: w,
            height: h,
            seedsInterleavedXY: interleaved,
            seedCount: UInt32(seedCanvasPoints.count),
            tolerance01: tolerance01,
            combineMode: combineU,
            existingMask: existingBytes
        ) else {
            return nil
        }
        return SelectionMask(width: w, height: h, data: data)
    }

    static func editorMaskCombineModeU32(_ c: EditorMaskCombineMode) -> UInt32 {
        switch c {
        case .replace: return 0
        case .add: return 1
        case .multiply: return 2
        case .difference: return 3
        }
    }

    func makeTransparentPixelRGBA(width: Int, height: Int) -> Data {
        let count = width * height * 4
        return Data(repeating: 0, count: count)
    }

    func addVideoLayer(from url: URL, name: String? = nil) {
        guard let device = renderer?.metalDevice ?? metalDevice else {
            debugLog("[ImageEditorManager] Metalデバイスが利用できません")
            return
        }

        // VideoFrameExtractorを初期化
        guard let extractor = VideoFrameExtractor(url: url, device: device) else {
            debugLog("[ImageEditorManager] 動画の読み込みに失敗: \(url.path)")
            return
        }

        saveUndoSnapshot(description: "動画レイヤー追加")

        let layerName = name ?? url.deletingPathExtension().lastPathComponent
        let layer = EditorLayer(name: layerName)

        // 動画プロパティを設定
        layer.videoPath = url.path
        layer.videoDuration = extractor.duration
        layer.videoFPS = extractor.fps
        layer.videoWidth = Int(extractor.videoSize.width)
        layer.videoHeight = Int(extractor.videoSize.height)
        layer.videoFrameExtractor = extractor

        // レイヤーサイズ情報にも動画解像度を反映
        layer.imageWidth = Int(extractor.videoSize.width)
        layer.imageHeight = Int(extractor.videoSize.height)

        // 先頭フレームをサムネイル用テクスチャとして設定
        layer.texture = extractor.thumbnailTexture()

        // Rust WGPUエンジンに先頭フレームのRGBAデータで登録
        if let engine = wgpuEngine {
            if let rgbaData = extractFirstFrameRGBA(extractor: extractor) {
                let w = UInt32(layer.videoWidth)
                let h = UInt32(layer.videoHeight)
                layer.rustLayerID = RustCore.wgpuAddLayer(
                    engine, name: layerName, width: w, height: h, rgbaData: rgbaData
                )
            }
        }

        project.layers.append(layer)
        syncRustLayerStackOrder()
        selectLayer(layer.id)
        isModified = true

        // タイムラインのデュレーションを動画に合わせて自動拡張
        animationManager?.adjustDurationForVideoLayer(layer)

        requestRender()

        debugLog("[ImageEditorManager] 動画レイヤー追加: \(layerName)")
        debugLog("  デュレーション: \(String(format: "%.2f", extractor.duration))秒")
        debugLog("  解像度: \(Int(extractor.videoSize.width))x\(Int(extractor.videoSize.height))")
    }

    func extractFirstFrameRGBA(extractor: VideoFrameExtractor) -> Data? {
        // AVAssetImageGeneratorで先頭フレームのCGImageを同期取得
        let generator = AVAssetImageGenerator(asset: extractor.asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)

        var cgImage: CGImage?
        let semaphore = DispatchSemaphore(value: 0)

        generator.generateCGImagesAsynchronously(
            forTimes: [NSValue(time: .zero)]
        ) { _, image, _, _, _ in
            cgImage = image
            semaphore.signal()
        }
        semaphore.wait()

        guard let image = cgImage else { return nil }
        return cgImageToRGBA(image)
    }

    func cgImageToRGBA(_ cgImage: CGImage) -> Data {
        let w = cgImage.width
        let h = cgImage.height
        let bytesPerRow = w * 4
        var data = Data(count: h * bytesPerRow)

        data.withUnsafeMutableBytes { rawBuffer in
            guard let ptr = rawBuffer.baseAddress else { return }
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: ptr,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return data
    }

    func addLayers(from urls: [URL]) {
        let videoExtensions = ["mp4", "mov", "m4v"]

        for url in urls {
            let ext = url.pathExtension.lowercased()
            if videoExtensions.contains(ext) {
                addVideoLayer(from: url)
            } else {
                addLayer(from: url)
            }
        }
    }

    func removeLayer(_ id: UUID) {
        guard let index = project.layerIndex(for: id) else { return }
        saveUndoSnapshot(description: "レイヤー削除")

        let layer = project.layers[index]

        // Rust WGPUエンジンからも削除
        if let engine = wgpuEngine, let rustID = layer.rustLayerID {
            RustCore.wgpuRemoveLayer(engine, layerId: rustID)
        }

        project.layers.remove(at: index)
        syncRustLayerStackOrder()

        // 選択中のレイヤーが削除された場合
        if selectedLayerID == id {
            if !project.layers.isEmpty {
                let newIndex = min(index, project.layers.count - 1)
                selectLayer(project.layers[newIndex].id)
            } else {
                selectLayer(nil)
            }
        }

        isModified = true
        requestRender()
        debugLog("[ImageEditorManager] レイヤー削除: \(layer.name)")
    }

    func moveLayer(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
              sourceIndex >= 0, sourceIndex < project.layers.count,
              destinationIndex >= 0, destinationIndex < project.layers.count else { return }

        saveUndoSnapshot(description: "レイヤー移動")
        let layer = project.layers.remove(at: sourceIndex)
        project.layers.insert(layer, at: destinationIndex)

        syncRustLayerStackOrder()

        isModified = true
        requestRender()
    }

    func duplicateLayer(_ id: UUID) {
        guard let index = project.layerIndex(for: id),
              let original = project.layers[safe: index] else { return }

        saveUndoSnapshot(description: "レイヤー複製")

        let copy = EditorLayer(
            name: "\(original.name) コピー",
            opacity: original.opacity,
            blendMode: original.blendMode,
            transform: original.transform,
            adjustments: original.adjustments,
            filterPreset: original.filterPreset
        )
        copy.imagePath = original.imagePath
        copy.texture = original.texture
        copy.imageWidth = original.imageWidth
        copy.imageHeight = original.imageHeight

        // 動画レイヤーの場合: VideoFrameExtractorを再作成
        if original.isVideoLayer {
            copy.videoPath = original.videoPath
            copy.videoDuration = original.videoDuration
            copy.videoFPS = original.videoFPS
            copy.videoWidth = original.videoWidth
            copy.videoHeight = original.videoHeight
            if let path = original.videoPath,
               let device = renderer?.metalDevice ?? metalDevice {
                let url = URL(fileURLWithPath: path)
                copy.videoFrameExtractor = VideoFrameExtractor(url: url, device: device)
            }
        }

        // Rust WGPUエンジンにも複製レイヤーを追加
        if let engine = wgpuEngine {
            if let imagePath = copy.imagePath {
                copy.rustLayerID = RustCore.wgpuAddLayerFromFile(
                    engine, name: copy.name, filePath: imagePath
                )
            } else {
                // imagePathがない場合（NSImage由来など）: 1x1透明ピクセルでレイヤーを確保し、後でテクスチャ差し替えは行わない
                let w = UInt32(max(1, copy.imageWidth))
                let h = UInt32(max(1, copy.imageHeight))
                let rgbaData = makeTransparentPixelRGBA(width: Int(w), height: Int(h))
                copy.rustLayerID = RustCore.wgpuAddLayer(
                    engine, name: copy.name, width: w, height: h, rgbaData: rgbaData
                )
            }

            // 複製元のプロパティを同期
            if let rustID = copy.rustLayerID {
                syncLayerPropertiesToRust(copy, rustLayerID: rustID)
            }
        }

        project.layers.insert(copy, at: index + 1)
        syncRustLayerStackOrder()
        selectLayer(copy.id)
        isModified = true
        requestRender()

        debugLog("[ImageEditorManager] レイヤー複製: \(original.name) → \(copy.name)")
    }

    func mergeDown(_ id: UUID) {
        guard let index = project.layerIndex(for: id),
              index > 0 else {
            debugLog("[ImageEditorManager] 結合できるレイヤーがありません")
            return
        }

        saveUndoSnapshot(description: "レイヤー結合")

        let topLayer = project.layers[index]
        let bottomLayer = project.layers[index - 1]

        // 対象の2レイヤーだけを合成する（全レイヤーではなく）
        let twoLayers = [bottomLayer, topLayer]
        renderer?.composeLayers(twoLayers, canvasSize: project.canvasSize)
        guard let mergedImage = renderer?.exportAsImage() else { return }

        if let device = renderer?.metalDevice {
            bottomLayer.loadTexture(from: mergedImage, device: device)
        }
        bottomLayer.name = "\(bottomLayer.name) + \(topLayer.name)"

        // Rust WGPUエンジンに合成結果を反映: 上下レイヤーを削除し、合成画像で1レイヤーとして追加
        if let engine = wgpuEngine {
            if let topRust = topLayer.rustLayerID {
                RustCore.wgpuRemoveLayer(engine, layerId: topRust)
            }
            if let bottomRust = bottomLayer.rustLayerID {
                RustCore.wgpuRemoveLayer(engine, layerId: bottomRust)
            }
            if let rgbaData = imageToRGBA(mergedImage) {
                let w = UInt32(project.canvasWidth)
                let h = UInt32(project.canvasHeight)
                if let newRustID = RustCore.wgpuAddLayer(
                    engine, name: bottomLayer.name, width: w, height: h, rgbaData: rgbaData
                ) {
                    bottomLayer.rustLayerID = newRustID
                    bottomLayer.imagePath = nil
                    bottomLayer.imageWidth = project.canvasWidth
                    bottomLayer.imageHeight = project.canvasHeight
                    syncLayerPropertiesToRust(bottomLayer, rustLayerID: newRustID)
                }
            }
        }

        project.layers.remove(at: index)
        syncRustLayerStackOrder()
        selectLayer(bottomLayer.id)
        isModified = true
        requestRender()
    }
}
