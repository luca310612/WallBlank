import MetalKit
import Combine

/// エディター専用のMetalレンダラー
/// レイヤーを下から順にオフスクリーンテクスチャに合成し、プレビュー表示する
class EditorRenderer: NSObject, ObservableObject {

    // MARK: - Metal リソース

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    /// レイヤー合成用パイプライン
    private var compositePipelineState: MTLRenderPipelineState?
    /// キャンバスクリア用パイプライン
    private var clearPipelineState: MTLRenderPipelineState?
    /// プレビュー表示用パイプライン
    private var previewPipelineState: MTLRenderPipelineState?

    /// オフスクリーン合成テクスチャ（ピンポンバッファ）
    private var canvasTextureA: MTLTexture?
    private var canvasTextureB: MTLTexture?
    private var useTextureA: Bool = true

    /// 最終合成結果テクスチャ
    @Published var compositeTexture: MTLTexture?

    /// レイヤーUniformsバッファ
    private var uniformBuffer: MTLBuffer?

    /// プレビュー更新が必要か
    @Published var needsRedraw: Bool = true

    /// キャンバスサイズ
    private var canvasWidth: Int = 1920
    private var canvasHeight: Int = 1080

    /// スレッドセーフ用ロック
    private let renderLock = NSLock()

    // MARK: - 初期化

    init?(device: MTLDevice? = nil) {
        guard let metalDevice = device ?? MTLCreateSystemDefaultDevice() else {
            print("[EditorRenderer] Metal デバイスの初期化に失敗")
            return nil
        }
        guard let queue = metalDevice.makeCommandQueue() else {
            print("[EditorRenderer] コマンドキューの作成に失敗")
            return nil
        }

        self.device = metalDevice
        self.commandQueue = queue

        super.init()

        setupPipelines()
        createCanvasTextures()

        print("[EditorRenderer] 初期化完了 (デバイス: \(metalDevice.name))")
    }

    // MARK: - パイプラインセットアップ

    private func setupPipelines() {
        guard let library = device.makeDefaultLibrary() else {
            print("[EditorRenderer] Metalライブラリの読み込みに失敗")
            return
        }

        // 合成パイプライン
        if let vertexFunc = library.makeFunction(name: "editorVertexShader"),
           let fragmentFunc = library.makeFunction(name: "editorCompositeFragment") {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            // アルファブレンディング有効
            descriptor.colorAttachments[0].isBlendingEnabled = false

            do {
                compositePipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                print("[EditorRenderer] 合成パイプライン作成失敗: \(error.localizedDescription)")
            }
        }

        // クリアパイプライン
        if let vertexFunc = library.makeFunction(name: "editorVertexShader"),
           let fragmentFunc = library.makeFunction(name: "editorClearFragment") {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

            do {
                clearPipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                print("[EditorRenderer] クリアパイプライン作成失敗: \(error.localizedDescription)")
            }
        }

        // プレビューパイプライン
        if let vertexFunc = library.makeFunction(name: "editorVertexShader"),
           let fragmentFunc = library.makeFunction(name: "editorPreviewFragment") {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

            do {
                previewPipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                print("[EditorRenderer] プレビューパイプライン作成失敗: \(error.localizedDescription)")
            }
        }

        // Uniformsバッファを確保
        let uniformSize = MemoryLayout<EditorLayerUniforms>.stride
        uniformBuffer = device.makeBuffer(length: uniformSize, options: .storageModeShared)
    }

    // MARK: - キャンバステクスチャ

    /// キャンバスサイズを変更
    func updateCanvasSize(width: Int, height: Int) {
        guard width > 0 && height > 0 else { return }
        guard width != canvasWidth || height != canvasHeight else { return }

        canvasWidth = width
        canvasHeight = height
        createCanvasTextures()
        needsRedraw = true

        print("[EditorRenderer] キャンバスサイズ変更: \(width)x\(height)")
    }

    private func createCanvasTextures() {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: canvasWidth,
            height: canvasHeight,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private

        canvasTextureA = device.makeTexture(descriptor: descriptor)
        canvasTextureB = device.makeTexture(descriptor: descriptor)

        canvasTextureA?.label = "エディターキャンバスA"
        canvasTextureB?.label = "エディターキャンバスB"
    }

    /// 現在の入力テクスチャ
    private var currentInputTexture: MTLTexture? {
        useTextureA ? canvasTextureA : canvasTextureB
    }

    /// 現在の出力テクスチャ
    private var currentOutputTexture: MTLTexture? {
        useTextureA ? canvasTextureB : canvasTextureA
    }

    /// テクスチャをスワップ
    private func swapTextures() {
        useTextureA.toggle()
    }

    // MARK: - テクスチャロード

    /// NSImageからMTLTextureを生成
    func loadTexture(from image: NSImage) -> MTLTexture? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue,
            .SRGB: false
        ]

        return try? loader.newTexture(cgImage: cgImage, options: options)
    }

    /// ファイルURLからMTLTextureを生成
    func loadTexture(from url: URL) -> MTLTexture? {
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue,
            .SRGB: false
        ]

        return try? loader.newTexture(URL: url, options: options)
    }

    /// Metalデバイスを公開
    var metalDevice: MTLDevice { device }

    // MARK: - レイヤー合成レンダリング

    /// 全レイヤーを合成して結果テクスチャを生成
    func composeLayers(_ layers: [EditorLayer], canvasSize: CGSize) {
        renderLock.lock()
        defer { renderLock.unlock() }

        guard let compositePipeline = compositePipelineState,
              let clearPipeline = clearPipelineState else {
            print("[EditorRenderer] パイプラインが未初期化")
            return
        }

        // キャンバスサイズ更新
        updateCanvasSize(width: Int(canvasSize.width), height: Int(canvasSize.height))

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "エディターレイヤー合成"

        // ステップ1: キャンバスをクリア
        useTextureA = true
        if let outputTexture = currentInputTexture {
            let passDescriptor = MTLRenderPassDescriptor()
            passDescriptor.colorAttachments[0].texture = outputTexture
            passDescriptor.colorAttachments[0].loadAction = .clear
            passDescriptor.colorAttachments[0].storeAction = .store
            passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) {
                encoder.setRenderPipelineState(clearPipeline)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                encoder.endEncoding()
            }
        }

        // ステップ2: 各レイヤーを下から順に合成
        let visibleLayers = layers.filter { $0.isActive }

        for layer in visibleLayers {
            guard let layerTexture = layer.currentFrameTexture,
                  let inputTexture = currentInputTexture,
                  let outputTexture = currentOutputTexture else {
                continue
            }

            // Uniformsを設定
            var uniforms = EditorLayerUniforms(from: layer, canvasSize: canvasSize)
            uniformBuffer?.contents().copyMemory(
                from: &uniforms,
                byteCount: MemoryLayout<EditorLayerUniforms>.stride
            )

            // レンダーパス
            let passDescriptor = MTLRenderPassDescriptor()
            passDescriptor.colorAttachments[0].texture = outputTexture
            passDescriptor.colorAttachments[0].loadAction = .dontCare
            passDescriptor.colorAttachments[0].storeAction = .store

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) {
                encoder.setRenderPipelineState(compositePipeline)
                encoder.setFragmentTexture(inputTexture, index: 0)
                encoder.setFragmentTexture(layerTexture, index: 1)
                encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                encoder.endEncoding()
            }

            swapTextures()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // 最終結果を保存
        compositeTexture = currentInputTexture
        needsRedraw = false
    }

    // MARK: - MTKView描画

    /// MTKViewに合成結果を描画
    func draw(in view: MTKView) {
        guard let previewPipeline = previewPipelineState,
              let composite = compositeTexture,
              let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor else {
            return
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "エディタープレビュー描画"

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) {
            encoder.setRenderPipelineState(previewPipeline)
            encoder.setFragmentTexture(composite, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - エクスポート

    /// 合成結果をNSImageとしてエクスポート
    func exportAsImage() -> NSImage? {
        guard let texture = compositeTexture else {
            print("[EditorRenderer] 合成テクスチャがありません")
            return nil
        }

        // 読み取り可能なテクスチャにコピー
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .managed

        guard let readableTexture = device.makeTexture(descriptor: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            return nil
        }

        blitEncoder.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: readableTexture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.synchronize(resource: readableTexture)
        blitEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return createNSImage(from: readableTexture)
    }

    /// MTLTextureからNSImageを生成
    private func createNSImage(from texture: MTLTexture) -> NSImage? {
        let width = texture.width
        let height = texture.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        let region = MTLRegionMake2D(0, 0, width, height)
        texture.getBytes(&pixelData, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)

        // BGRA → RGBA に変換
        for i in stride(from: 0, to: pixelData.count, by: 4) {
            let b = pixelData[i]
            let r = pixelData[i + 2]
            pixelData[i] = r
            pixelData[i + 2] = b
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ), let cgImage = context.makeImage() else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    /// 合成結果をファイルに保存
    func exportToFile(url: URL, format: NSBitmapImageRep.FileType = .png) -> Bool {
        guard let image = exportAsImage(),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let data = bitmap.representation(using: format, properties: [:]) else {
            print("[EditorRenderer] エクスポート失敗")
            return false
        }

        do {
            try data.write(to: url)
            print("[EditorRenderer] エクスポート完了: \(url.path)")
            return true
        } catch {
            print("[EditorRenderer] ファイル書き込み失敗: \(error.localizedDescription)")
            return false
        }
    }
}
