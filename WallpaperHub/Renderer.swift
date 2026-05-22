import MetalKit
import AppKit
import AVFoundation
import CoreVideo
import ImageIO

private final class SharedStaticImageTextureCache {
    static let shared = SharedStaticImageTextureCache()

    private struct Entry {
        var texture: MTLTexture
        var refCount: Int
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    private init() {}

    func retainTexture(for key: String, create: () throws -> MTLTexture) rethrows -> (texture: MTLTexture, reused: Bool) {
        lock.lock()
        if var entry = entries[key] {
            entry.refCount += 1
            entries[key] = entry
            lock.unlock()
            return (entry.texture, true)
        }
        lock.unlock()

        let texture = try create()

        lock.lock()
        if var entry = entries[key] {
            entry.refCount += 1
            entries[key] = entry
            lock.unlock()
            return (entry.texture, true)
        }
        entries[key] = Entry(texture: texture, refCount: 1)
        lock.unlock()
        return (texture, false)
    }

    func releaseTexture(for key: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[key] else { return }
        entry.refCount -= 1
        if entry.refCount <= 0 {
            entries.removeValue(forKey: key)
        } else {
            entries[key] = entry
        }
    }
}

enum ShaderType: Int, CaseIterable {
    case transparent = 0  // 透過（macOSデスクトップをそのまま表示）
    case gradient = 1
    case plasma = 2
    case noise = 3
}

/// Uniforms構造体（Metal Shading Language との完全一致を保証）
/// メモリレイアウト: 96バイト、16バイトアライメント
///
/// オフセット:
///   0: time (4)
///   4: _pad0 (4)
///   8: resolution (8) - float2は8バイトアライメント
///  16: shaderType (4)
///  20: hasBackgroundImage (4)
///  24: effectIntensity (4)
///  28: _pad1 (4)
///  32: mousePosition (8) - float2は8バイトアライメント
///  40: clickTime (4)
///  44: clickActive (4)
///  48: octaveCount (4)
///  52: hasMaskTexture (4)
///  56: spanWallpaperAcrossDisplays (4)
///  60: _pad2 (4)
///  64: displayOrigin (8)
///  72: displaySize (8)
///  80: canvasSize (8)
///  88: _pad3 (8)
/// Total: 96 bytes (16バイト境界に整列)
struct Uniforms {
    var time: Float
    var _pad0: Float = 0             // resolution用8バイトアライメント
    var resolution: SIMD2<Float>
    var shaderType: Int32
    var hasBackgroundImage: Int32
    var effectIntensity: Float
    var _pad1: Float = 0             // mousePosition用8バイトアライメント
    var mousePosition: SIMD2<Float>  // クリック位置 (0-1 normalized)
    var clickTime: Float             // 最後のクリックからの経過時間
    var clickActive: Int32           // クリックがアクティブかどうか
    var octaveCount: Int32           // FBMオクターブ数 (2-5)
    var hasMaskTexture: Int32        // マスクテクスチャがあるかどうか
    var spanWallpaperAcrossDisplays: Int32
    var _pad2: Int32 = 0             // 16バイト境界用パディング
    var displayOrigin: SIMD2<Float>  // 仮想キャンバス上のディスプレイ左上
    var displaySize: SIMD2<Float>    // 仮想キャンバス上のディスプレイサイズ
    var canvasSize: SIMD2<Float>     // 仮想キャンバス全体サイズ
    var _pad3: SIMD2<Float> = .zero  // 16バイト境界用パディング
}

// MARK: - Effect Uniforms（EffectTypes.swiftのEffectUniformsを直接使用し重複を排除）
typealias RendererEffectUniforms = EffectUniforms

class Renderer: NSObject, MTKViewDelegate {

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    /// shaderType ごとに事前ビルドした PSO バリアント。
    /// Why: Composite.metal の `kShaderType` が Function Constant 化されたため、
    /// PSO ごとに使われない分岐をコンパイル時に dead code 除去できる。
    /// キーは ShaderType.rawValue (0=transparent / 1=gradient / 2=plasma / 3=noise)。
    private var pipelineStates: [Int: MTLRenderPipelineState] = [:]
    /// 後方互換用ヘルパ: 旧 pipelineState API を残しつつ currentShader に対応する PSO を返す。
    private var pipelineState: MTLRenderPipelineState? {
        pipelineStates[currentShader.rawValue] ?? pipelineStates[ShaderType.transparent.rawValue]
    }
    private weak var boundView: MTKView?

    private let startTime: CFTimeInterval

    // スレッドセーフなプロパティアクセス用ロック
    private let propertyLock = NSLock()

    // シェーダー設定（スレッドセーフ）
    private var _currentShader: ShaderType = .transparent
    var currentShader: ShaderType {
        get {
            propertyLock.lock()
            defer { propertyLock.unlock() }
            return _currentShader
        }
        set {
            propertyLock.lock()
            _currentShader = newValue
            needsRedraw = true
            propertyLock.unlock()
        }
    }

    // 壁紙未設定時の透過モード（macOSデスクトップを表示）
    private var _isTransparentMode: Bool = false
    var isTransparentMode: Bool {
        get {
            propertyLock.lock()
            defer { propertyLock.unlock() }
            return _isTransparentMode
        }
        set {
            propertyLock.lock()
            _isTransparentMode = newValue
            needsRedraw = true
            propertyLock.unlock()
        }
    }

    // 背景画像関連（スレッドセーフ）
    private var _backgroundTexture: MTLTexture?
    var backgroundTexture: MTLTexture? {
        get {
            propertyLock.lock()
            defer { propertyLock.unlock() }
            return _backgroundTexture
        }
        set {
            propertyLock.lock()
            _backgroundTexture = newValue
            needsRedraw = true
            propertyLock.unlock()
        }
    }

    private var _effectIntensity: Float = 0.0
    var effectIntensity: Float {
        get {
            propertyLock.lock()
            defer { propertyLock.unlock() }
            return _effectIntensity
        }
        set {
            propertyLock.lock()
            _effectIntensity = newValue
            needsRedraw = true
            propertyLock.unlock()
        }
    }

    private var _spanWallpaperAcrossDisplays: Bool = false
    private var _spanDisplayOrigin = SIMD2<Float>(0, 0)
    private var _spanDisplaySize = SIMD2<Float>(1, 1)
    private var _spanCanvasSize = SIMD2<Float>(1, 1)

    // 動画再生関連
    private var videoPlayer: AVPlayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var displayLink: CVDisplayLink?
    private var textureCache: CVMetalTextureCache?
    private var _isVideoPlaying = false
    private var isVideoPlaying: Bool {
        get { propertyLock.lock(); defer { propertyLock.unlock() }; return _isVideoPlaying }
        set { propertyLock.lock(); _isVideoPlaying = newValue; propertyLock.unlock() }
    }
    private var videoURL: URL?
    private var gifURL: URL?
    private var imageURL: URL?
    private var playerItemStatusObservation: NSKeyValueObservation?
    var onVideoFirstFrameReady: (() -> Void)?
    var onVideoLoadFailed: ((String) -> Void)?
    var onBackgroundReady: (() -> Void)?
    var onBackgroundLoadFailed: ((String) -> Void)?
    private var hasSignaledCurrentVideoFirstFrame = false
    private var keepTransparentUntilBackgroundReady = false

    /// 動画に音声トラックがあるかどうか
    private var _hasAudioTrack: Bool = false
    private(set) var hasAudioTrack: Bool {
        get { propertyLock.lock(); defer { propertyLock.unlock() }; return _hasAudioTrack }
        set { propertyLock.lock(); _hasAudioTrack = newValue; propertyLock.unlock() }
    }

    /// 音量 (0.0〜1.0)
    private var _volume: Float = 1.0
    var volume: Float {
        get { propertyLock.lock(); defer { propertyLock.unlock() }; return _volume }
        set {
            propertyLock.lock()
            _volume = newValue
            propertyLock.unlock()
            // AVPlayerはスレッドセーフでないため、メインスレッドでアクセス
            DispatchQueue.main.async { [weak self] in
                self?.videoPlayer?.volume = newValue
            }
        }
    }

    // CVMetalTextureの参照を保持（テクスチャのバッキングメモリを維持）
    private var currentVideoTexture: CVMetalTexture?
    private var sharedStaticImageCacheKey: String?

    // GIFアニメーション関連（フルフレームキャッシュ）
    private var gifImageSource: CGImageSource?
    private var gifTotalFrameCount: Int = 0
    private var gifFrameDelays: [Double] = []
    private var gifCurrentFrame: Int = 0
    private var gifLastFrameTime: CFTimeInterval = 0
    private var _isGifPlaying = false
    private var isGifPlaying: Bool {
        get { propertyLock.lock(); defer { propertyLock.unlock() }; return _isGifPlaying }
        set { propertyLock.lock(); _isGifPlaying = newValue; propertyLock.unlock() }
    }

    // GIF フレーム用キャッシュ（リング上限＝全フレーム想定）
    // バッファサイズは解像度に応じて動的に計算
    private var gifRingBufferSize: Int = 10
    private var gifTextureCache: [Int: MTLTexture] = [:]
    private var gifTextureCacheOrder: [Int] = []  // LRU順序管理
    private var gifFrameWidth: Int = 0
    private var gifFrameHeight: Int = 0
    private let gifCacheLock = NSLock()  // GIFキャッシュのスレッドセーフティ用

    // GIF非同期ロード用
    private let gifLoadQueue = DispatchQueue(label: "com.artia.gif.loader", qos: .userInitiated)
    private var gifPendingFrames: Set<Int> = []
    private let gifPendingLock = NSLock()

    // マウスインタラクション（スレッドセーフ）
    private var _mousePosition: SIMD2<Float> = SIMD2<Float>(0.5, 0.5)
    var mousePosition: SIMD2<Float> {
        get { propertyLock.lock(); defer { propertyLock.unlock() }; return _mousePosition }
        set { propertyLock.lock(); _mousePosition = newValue; propertyLock.unlock() }
    }
    private var _lastClickTime: CFTimeInterval = 0
    var lastClickTime: CFTimeInterval {
        get { propertyLock.lock(); defer { propertyLock.unlock() }; return _lastClickTime }
        set { propertyLock.lock(); _lastClickTime = newValue; propertyLock.unlock() }
    }
    private var _clickActive: Bool = false
    var clickActive: Bool {
        get { propertyLock.lock(); defer { propertyLock.unlock() }; return _clickActive }
        set { propertyLock.lock(); _clickActive = newValue; needsRedraw = true; propertyLock.unlock() }
    }

    // シェーダー品質設定（スレッドセーフ）
    private var _octaveCount: Int32 = 5
    var octaveCount: Int32 {
        get { propertyLock.lock(); defer { propertyLock.unlock() }; return _octaveCount }
        set { propertyLock.lock(); _octaveCount = newValue; needsRedraw = true; propertyLock.unlock() }
    }

    // エフェクト関連（スレッドセーフ）
    private var _maskTexture: MTLTexture?
    var maskTexture: MTLTexture? {
        get {
            propertyLock.lock()
            defer { propertyLock.unlock() }
            return _maskTexture
        }
        set {
            propertyLock.lock()
            _maskTexture = newValue
            needsRedraw = true
            propertyLock.unlock()
        }
    }

    private var _effectConfiguration: EffectConfiguration = .default
    var effectConfiguration: EffectConfiguration {
        get {
            propertyLock.lock()
            defer { propertyLock.unlock() }
            return _effectConfiguration
        }
        set {
            propertyLock.lock()
            _effectConfiguration = newValue
            needsRedraw = true
            propertyLock.unlock()
        }
    }

    // エフェクトUniformsバッファ
    private var effectUniformBuffer: MTLBuffer!
    private let effectUniformAlignedSize = (MemoryLayout<RendererEffectUniforms>.size + 0xFF) & ~0xFF

    // 静的コンテンツ検出用
    private var needsRedraw = true

    // 動画フレーム重複スキップ用
    private var lastVideoFrameTime: CMTime = .invalid

    // テクスチャキャッシュフラッシュ用（時間ベース）
    private var lastTextureCacheFlushTime: CFTimeInterval = 0
    private let textureCacheFlushIntervalSeconds: Double = 2.0  // 2秒ごとにフラッシュ

    // シェーダーへ渡す解像度ログの重複抑制
    private var lastLoggedDrawableResolution: SIMD2<Int>?
    private var lastLoggedDrawableTextureSize: SIMD2<Int>?
    private var lastLoggedOffscreenResolution: SIMD2<Int>?
    private var lastLoggedOffscreenTextureSize: SIMD2<Int>?

    // スレッドセーフ用
    private var isInvalidated = false
    private let renderLock = NSLock()

    // トリプルバッファリング
    private static let maxFramesInFlight = 3
    private let frameSemaphore = DispatchSemaphore(value: maxFramesInFlight)
    private var uniformBuffer: MTLBuffer!
    private var currentFrameIndex = 0
    private let uniformAlignedSize = (MemoryLayout<Uniforms>.size + 0xFF) & ~0xFF

    // インフライト中のフレーム数を追跡（セマフォ過剰解放防止用）
    private var framesInFlight: Int = 0
    private let framesInFlightLock = NSLock()

    // 頂点バッファ（不変なので let で定義）
    private let vertexBuffer: MTLBuffer

    // フルスクリーン四角形の頂点データ
    private static let vertices: [SIMD4<Float>] = [
        SIMD4<Float>(-1, -1, 0, 1),
        SIMD4<Float>( 1, -1, 0, 1),
        SIMD4<Float>(-1,  1, 0, 1),
        SIMD4<Float>( 1,  1, 0, 1)
    ]

    init?(metalView: MTKView) {
        guard let device = metalView.device,
              let commandQueue = device.makeCommandQueue(),
              let vertexBuffer = device.makeBuffer(
                  bytes: Self.vertices,
                  length: MemoryLayout<SIMD4<Float>>.stride * Self.vertices.count,
                  options: .storageModeShared
              )
        else {
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue
        self.vertexBuffer = vertexBuffer
        self.boundView = metalView
        self.startTime = CACurrentMediaTime()

        // トリプルバッファリング用uniformバッファ
        let uniformBufferSize = uniformAlignedSize * Self.maxFramesInFlight
        guard let uBuffer = device.makeBuffer(length: uniformBufferSize, options: .storageModeShared) else {
            return nil
        }
        self.uniformBuffer = uBuffer

        // エフェクトUniformsバッファ
        let effectBufferSize = effectUniformAlignedSize * Self.maxFramesInFlight
        guard let eBuffer = device.makeBuffer(length: effectBufferSize, options: .storageModeShared) else {
            return nil
        }
        self.effectUniformBuffer = eBuffer

        super.init()

        setupPipeline(metalView: metalView)
        setupTextureCache()
    }

    /// スリープ復帰・再起動直後などに、描画コンテキスト（pipeline/texture cache）とメディア状態を再初期化する。
    /// - Important: MTKView の `drawable` が不安定な瞬間があるため、呼び出し側で少し遅延して実行してもよい。
    func reinitializeRenderContext(reason: String) {
        renderLock.lock()
        let invalidated = isInvalidated
        renderLock.unlock()
        guard !invalidated else { return }

        // Metal パイプラインを作り直す（ピクセルフォーマット変更やデバイスロスト後の固まり対策）
        if let view = boundView {
            setupPipeline(metalView: view)
        } else {
            // view が取れない場合でも最低限既定フォーマットで再生成
            setupPipeline(pixelFormat: .bgra8Unorm)
        }

        // 動画テクスチャキャッシュを作り直す（復帰後に古いキャッシュが詰まって固まるケースの対策）
        setupTextureCache()
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
        lastTextureCacheFlushTime = 0
        currentVideoTexture = nil
        lastVideoFrameTime = .invalid

        // 背景を再ロードして AVPlayerItemVideoOutput / GIF ストリーミング状態を確実に復元
        // （復帰直後に backgroundTexture が古い参照のままになるのを防ぐ）
        if let url = videoURL {
            loadVideo(from: url)
        } else if let url = gifURL {
            loadGif(from: url)
        } else if let url = imageURL {
            loadBackgroundImage(from: url)
        }

        needsRedraw = true
        debugLog("[Renderer] reinitializeRenderContext (\(reason))")
    }

    private func setupTextureCache() {
        var cache: CVMetalTextureCache?
        let result = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        if result == kCVReturnSuccess {
            textureCache = cache
        } else {
            debugLog("Failed to create texture cache: \(result)")
        }
    }

    // パイプラインを作成した時のピクセルフォーマットを記録
    private var currentPixelFormat: MTLPixelFormat = .invalid

    func setupPipeline(metalView: MTKView) {
        setupPipeline(pixelFormat: metalView.colorPixelFormat)
    }

    func setupPipeline(pixelFormat: MTLPixelFormat) {
        // 既に同じフォーマットでパイプラインが作成済みなら何もしない
        if !pipelineStates.isEmpty && currentPixelFormat == pixelFormat {
            return
        }

        guard let library = device.makeDefaultLibrary() else {
            debugLog("Failed to create shader library - Shaders.metal may not be included in build target")
            return
        }
        debugLog("Shader library loaded successfully")

        guard let vertexFunction = library.makeFunction(name: "vertexShader") else {
            debugLog("Failed to find vertexShader function")
            return
        }

        // 各 ShaderType ごとに Function Constant 値で PSO バリアントを生成。
        // Why: Composite.metal が `kShaderType [[function_constant(0)]]` に切り替わり、
        // PSO 単位で dead code 除去が効くようになったため、起動時に 4 バリアントを揃える。
        var built: [Int: MTLRenderPipelineState] = [:]
        for shader in ShaderType.allCases {
            let constants = MTLFunctionConstantValues()
            var typeValue = Int32(shader.rawValue)
            constants.setConstantValue(&typeValue, type: .int, index: 0)

            let fragmentFunction: MTLFunction
            do {
                fragmentFunction = try library.makeFunction(name: "fragmentShader", constantValues: constants)
            } catch {
                debugLog("Failed to specialize fragmentShader for shaderType=\(shader.rawValue): \(error)")
                continue
            }

            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat

            // アルファブレンディングを有効化（透過シェーダーでmacOSデスクトップを透かして表示）
            pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
            pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
            pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
            pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

            do {
                let state = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
                built[shader.rawValue] = state
            } catch {
                debugLog("Failed to create pipeline state for shaderType=\(shader.rawValue): \(error)")
            }
        }

        guard !built.isEmpty else {
            debugLog("Failed to create any pipeline state")
            return
        }

        pipelineStates = built
        currentPixelFormat = pixelFormat
        debugLog("Pipeline states created (\(built.count) variants) for format: \(pixelFormat)")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // 画面サイズ変更時の処理
    }

    /// 再描画が必要であることをマーク
    func markDirty() {
        needsRedraw = true
    }

    func setDisplaySpanConfiguration(enabled: Bool, displayRect: CGRect, canvasRect: CGRect) {
        let safeDisplayWidth = max(Float(displayRect.width), 1)
        let safeDisplayHeight = max(Float(displayRect.height), 1)
        let safeCanvasWidth = max(Float(canvasRect.width), safeDisplayWidth, 1)
        let safeCanvasHeight = max(Float(canvasRect.height), safeDisplayHeight, 1)

        propertyLock.lock()
        _spanWallpaperAcrossDisplays = enabled
        _spanDisplayOrigin = SIMD2<Float>(
            Float(displayRect.minX - canvasRect.minX),
            Float(displayRect.minY - canvasRect.minY)
        )
        _spanDisplaySize = SIMD2<Float>(safeDisplayWidth, safeDisplayHeight)
        _spanCanvasSize = SIMD2<Float>(safeCanvasWidth, safeCanvasHeight)
        needsRedraw = true
        propertyLock.unlock()
    }

    private func displaySpanConfigurationSnapshot() -> (enabled: Int32, origin: SIMD2<Float>, size: SIMD2<Float>, canvasSize: SIMD2<Float>) {
        propertyLock.lock()
        defer { propertyLock.unlock() }
        return (
            _spanWallpaperAcrossDisplays ? 1 : 0,
            _spanDisplayOrigin,
            _spanDisplaySize,
            _spanCanvasSize
        )
    }

    private func logShaderDimensionsIfNeeded(context: String, resolution: SIMD2<Float>, texture: MTLTexture?) {
        let resolutionInt = SIMD2<Int>(Int(resolution.x), Int(resolution.y))
        let textureSize = texture.map { SIMD2<Int>($0.width, $0.height) }

        switch context {
        case "drawable":
            guard lastLoggedDrawableResolution != resolutionInt || lastLoggedDrawableTextureSize != textureSize else { return }
            lastLoggedDrawableResolution = resolutionInt
            lastLoggedDrawableTextureSize = textureSize
        case "offscreen":
            guard lastLoggedOffscreenResolution != resolutionInt || lastLoggedOffscreenTextureSize != textureSize else { return }
            lastLoggedOffscreenResolution = resolutionInt
            lastLoggedOffscreenTextureSize = textureSize
        default:
            break
        }

        if let textureSize {
            debugLog("[Renderer] Shader uniforms (\(context)): screenSize=\(resolutionInt.x)x\(resolutionInt.y), textureSize=\(textureSize.x)x\(textureSize.y)")
        } else {
            debugLog("[Renderer] Shader uniforms (\(context)): screenSize=\(resolutionInt.x)x\(resolutionInt.y), textureSize=nil")
        }
    }

    func draw(in view: MTKView) {
        // 無効化チェック
        renderLock.lock()
        let invalidated = isInvalidated
        renderLock.unlock()
        guard !invalidated else { return }

        // 透過モード: 壁紙未設定時はウィンドウを完全透明にしてmacOSデスクトップを表示
        if isTransparentMode {
            // 背景ロード完了待ちの遅延透過中は、動画/GIFの初回フレーム取得を試みる。
            // ここで取得に成功すると completeDeferredBackgroundPresentationIfNeeded() が
            // 呼ばれて isTransparentMode が false に戻り、通常描画に進める。
            if keepTransparentUntilBackgroundReady {
                if isVideoPlaying { updateVideoFrame() }
                if isGifPlaying { updateGifFrame() }
            }

            // 上の処理で透過解除された場合は通常描画に進む
            if !isTransparentMode {
                // フォールスルーして通常パスへ
            } else {
                guard view.drawableSize.width > 0,
                      view.drawableSize.height > 0,
                      let drawable = view.currentDrawable,
                      let renderPassDescriptor = view.currentRenderPassDescriptor
                else { return }

                // クリアカラーを完全透明に設定
                renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                renderPassDescriptor.colorAttachments[0].loadAction = .clear

                guard let commandBuffer = commandQueue.makeCommandBuffer(),
                      let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
                else { return }

                // 何も描画せず透明フレームをコミット
                renderEncoder.endEncoding()
                commandBuffer.present(drawable)
                commandBuffer.commit()
                needsRedraw = false
                return
            }
        }

        // 動画フレームを更新（新しいフレームがあるときだけテクスチャ更新）
        var videoFrameUpdated = false
        if isVideoPlaying {
            let oldTexture = backgroundTexture
            updateVideoFrame()
            videoFrameUpdated = (backgroundTexture !== oldTexture)
        }

        // GIFフレームを更新
        var gifFrameUpdated = false
        if isGifPlaying {
            let oldFrame = gifCurrentFrame
            updateGifFrame()
            gifFrameUpdated = (gifCurrentFrame != oldFrame)
        }

        // 静的コンテンツ検出: アニメーション不要なら描画をスキップ
        let hasShaderEffect = effectIntensity > 0.0
        let hasClickEffect = clickActive
        let hasActiveEffects = effectConfiguration.hasActiveEffects
        let isAnimating = hasShaderEffect || isVideoPlaying || isGifPlaying || hasClickEffect || hasActiveEffects

        if !isAnimating && !needsRedraw {
            return
        }

        // 動画/GIF表示中でシェーダーエフェクトなし：新フレームがない場合は描画スキップ
        // 120FPSでも30fps動画なら4回中3回はスキップ → GPU負荷大幅削減
        if !hasShaderEffect && !hasClickEffect {
            if isVideoPlaying && !videoFrameUpdated && !needsRedraw {
                return
            }
            if isGifPlaying && !gifFrameUpdated && !needsRedraw {
                return
            }
        }

        // ピクセルフォーマット変更時のみパイプライン再作成
        if currentPixelFormat != view.colorPixelFormat {
            setupPipeline(pixelFormat: view.colorPixelFormat)
        }

        // 描画に必要な条件を確認
        guard let pipelineState = pipelineState,
              view.drawableSize.width > 0,
              view.drawableSize.height > 0,
              let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor
        else { return }

        // クリアカラーを透明に設定（透過シェーダーでmacOSデスクトップを透かすため）
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderPassDescriptor.colorAttachments[0].loadAction = .clear

        // トリプルバッファリング: GPUが前のフレームを処理中でも次のフレームを準備
        // タイムアウト付きでwait（GPUハング時のデッドロック防止）
        let waitResult = frameSemaphore.wait(timeout: .now() + .milliseconds(100))
        if waitResult == .timedOut {
            // タイムアウト時はフレームをスキップ
            debugLog("[Renderer] Frame semaphore timeout - skipping frame")
            return
        }

        // インフライト数を増加
        framesInFlightLock.lock()
        framesInFlight += 1
        framesInFlightLock.unlock()

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            framesInFlightLock.lock()
            framesInFlight -= 1
            framesInFlightLock.unlock()
            frameSemaphore.signal()
            return
        }

        // Uniforms設定 — トリプルバッファで書き込み
        let currentTime = Float(CACurrentMediaTime() - startTime)
        let timeSinceClick = Float(CACurrentMediaTime() - lastClickTime)
        let hasBackground: Int32 = backgroundTexture != nil ? 1 : 0
        let hasMask: Int32 = maskTexture != nil ? 1 : 0
        let spanConfig = displaySpanConfigurationSnapshot()

        let bufferIndex = currentFrameIndex % Self.maxFramesInFlight
        let offset = bufferIndex * uniformAlignedSize
        let effectOffset = bufferIndex * effectUniformAlignedSize

        var uniforms = Uniforms(
            time: currentTime,
            resolution: SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            shaderType: Int32(currentShader.rawValue),
            hasBackgroundImage: hasBackground,
            effectIntensity: effectIntensity,
            mousePosition: mousePosition,
            clickTime: timeSinceClick,
            clickActive: clickActive ? 1 : 0,
            octaveCount: octaveCount,
            hasMaskTexture: hasMask,
            spanWallpaperAcrossDisplays: spanConfig.enabled,
            displayOrigin: spanConfig.origin,
            displaySize: spanConfig.size,
            canvasSize: spanConfig.canvasSize
        )

        logShaderDimensionsIfNeeded(context: "drawable", resolution: uniforms.resolution, texture: backgroundTexture)

        // エフェクトUniformsを生成
        var effectUniforms = EffectUniforms(from: effectConfiguration)

        uniformBuffer.contents().advanced(by: offset).copyMemory(from: &uniforms, byteCount: MemoryLayout<Uniforms>.size)
        effectUniformBuffer.contents().advanced(by: effectOffset).copyMemory(from: &effectUniforms, byteCount: MemoryLayout<EffectUniforms>.size)

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        renderEncoder.setFragmentBuffer(uniformBuffer, offset: offset, index: 0)
        renderEncoder.setFragmentBuffer(effectUniformBuffer, offset: effectOffset, index: 1)

        if let texture = backgroundTexture {
            renderEncoder.setFragmentTexture(texture, index: 0)
        }

        if let mask = maskTexture {
            renderEncoder.setFragmentTexture(mask, index: 1)
        }

        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()
        commandBuffer.present(drawable)

        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self = self else { return }
            // インフライト数を減少
            self.framesInFlightLock.lock()
            self.framesInFlight -= 1
            self.framesInFlightLock.unlock()

            // 無効化されていない場合のみセマフォをシグナル
            self.renderLock.lock()
            let invalidated = self.isInvalidated
            self.renderLock.unlock()
            if !invalidated {
                self.frameSemaphore.signal()
            }
        }

        commandBuffer.commit()
        currentFrameIndex += 1
        needsRedraw = false
    }

    /// Rendererを無効化（解放前に呼ぶ）
    func invalidate() {
        renderLock.lock()
        isInvalidated = true
        renderLock.unlock()

        // すべてのメディア再生を停止
        stopVideo()
        stopGif()
        releaseSharedStaticImageIfNeeded()

        // テクスチャをクリア
        backgroundTexture = nil

        // インフライト中のフレーム数だけセマフォをシグナル（過剰解放防止）
        framesInFlightLock.lock()
        let currentInFlight = framesInFlight
        framesInFlight = 0
        framesInFlightLock.unlock()

        for _ in 0..<currentInFlight {
            frameSemaphore.signal()
        }
    }

    // MARK: - 背景画像管理

    /// 画像ファイルから背景テクスチャを読み込む
    func loadBackgroundImage(from url: URL) {
        releaseSharedStaticImageIfNeeded()
        imageURL = url
        guard let image = NSImage(contentsOf: url) else {
            debugLog("Failed to load image from: \(url)")
            onBackgroundLoadFailed?("Failed to load image from: \(url.lastPathComponent)")
            return
        }

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            debugLog("Failed to get CGImage from NSImage")
            onBackgroundLoadFailed?("Failed to decode image: \(url.lastPathComponent)")
            return
        }

        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue,
            .SRGB: false
        ]
        let textureLoader = MTKTextureLoader(device: device)
        let cacheKey = makeSharedStaticImageCacheKey(for: url)

        do {
            let result = try SharedStaticImageTextureCache.shared.retainTexture(for: cacheKey) {
                try textureLoader.newTexture(cgImage: cgImage, options: options)
            }
            backgroundTexture = result.texture
            sharedStaticImageCacheKey = cacheKey
            let source = result.reused ? "reused" : "created"
            debugLog("Background texture \(source): \(cgImage.width)x\(cgImage.height)")
            completeDeferredBackgroundPresentationIfNeeded()
            onBackgroundReady?()
        } catch {
            debugLog("Failed to create texture: \(error)")
            keepTransparentUntilBackgroundReady = false
            onBackgroundLoadFailed?("Failed to create texture: \(error.localizedDescription)")
        }
    }

    /// NSImageから背景テクスチャを読み込む
    func loadBackgroundImage(from image: NSImage) {
        releaseSharedStaticImageIfNeeded()
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            debugLog("Failed to get CGImage from NSImage")
            onBackgroundLoadFailed?("Failed to decode NSImage")
            return
        }

        let textureLoader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue,
            .SRGB: false
        ]

        do {
            backgroundTexture = try textureLoader.newTexture(cgImage: cgImage, options: options)
            debugLog("Background texture loaded: \(cgImage.width)x\(cgImage.height)")
            completeDeferredBackgroundPresentationIfNeeded()
            onBackgroundReady?()
        } catch {
            debugLog("Failed to create texture: \(error)")
            keepTransparentUntilBackgroundReady = false
            onBackgroundLoadFailed?("Failed to create texture: \(error.localizedDescription)")
        }
    }

    /// 背景画像をクリア
    func clearBackgroundImage() {
        stopVideo()
        stopGif()
        releaseSharedStaticImageIfNeeded()
        backgroundTexture = nil
        videoURL = nil
        gifURL = nil
        imageURL = nil
        keepTransparentUntilBackgroundReady = false
        debugLog("背景画像をクリア")
    }

    /// 透過モードを有効にして壁紙ウィンドウを透明にする（macOSデスクトップを表示）
    func enableTransparentMode() {
        stopVideo()
        stopGif()
        releaseSharedStaticImageIfNeeded()
        backgroundTexture = nil
        videoURL = nil
        gifURL = nil
        imageURL = nil
        keepTransparentUntilBackgroundReady = false
        isTransparentMode = true
        debugLog("透過モードに移行（macOSデスクトップを表示）")
    }

    // MARK: - Video Playback (動画再生)

    /// 動画ファイルを読み込んで再生
    func loadVideo(from url: URL) {
        stopVideo()
        releaseSharedStaticImageIfNeeded()
        hasSignaledCurrentVideoFirstFrame = false

        debugLog("[Renderer] Loading video from: \(url.path)")

        // ファイルの存在確認
        guard FileManager.default.fileExists(atPath: url.path) else {
            debugLog("[Renderer] Video file does not exist: \(url.path)")
            keepTransparentUntilBackgroundReady = false
            onVideoLoadFailed?("Video file does not exist: \(url.lastPathComponent)")
            return
        }

        videoURL = url
        gifURL = nil
        imageURL = nil
        hasAudioTrack = false
        let asset = AVURLAsset(url: url)

        // 音声トラックの有無を確認
        asset.loadTracks(withMediaType: .audio) { [weak self] audioTracks, _ in
            DispatchQueue.main.async {
                if let audioTracks = audioTracks, !audioTracks.isEmpty {
                    self?.hasAudioTrack = true
                    debugLog("[Renderer] Audio tracks found: \(audioTracks.count)")
                } else {
                    self?.hasAudioTrack = false
                    debugLog("[Renderer] No audio tracks found")
                }
            }
        }

        // アセットのトラック情報を非同期でロード
        asset.loadTracks(withMediaType: .video) { [weak self] tracks, error in
            guard let self = self else { return }

            DispatchQueue.main.async {
                if let error = error {
                    debugLog("[Renderer] Failed to load video tracks: \(error.localizedDescription)")
                    self.onVideoLoadFailed?("Failed to load video tracks: \(error.localizedDescription)")
                    return
                }

                guard let tracks = tracks, !tracks.isEmpty else {
                    debugLog("[Renderer] No video tracks found in asset")
                    self.onVideoLoadFailed?("No video tracks found in asset")
                    return
                }

                debugLog("[Renderer] Video tracks loaded: \(tracks.count) track(s)")

                let playerItem = AVPlayerItem(asset: asset)

                // ビデオ出力の設定
                let outputSettings: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferMetalCompatibilityKey as String: true
                ]
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: outputSettings)
                self.videoOutput = output
                playerItem.add(output)

                // プレイヤーを作成
                let player = AVPlayer(playerItem: playerItem)
                player.volume = self.volume
                self.videoPlayer = player

                // ループ再生の設定
                NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: playerItem,
                    queue: .main
                ) { [weak self] _ in
                    self?.videoPlayer?.seek(to: .zero)
                    self?.videoPlayer?.play()
                }

                // PlayerItemのステータスを監視
                self.playerItemStatusObservation = playerItem.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
                    DispatchQueue.main.async {
                        switch item.status {
                        case .readyToPlay:
                            debugLog("[Renderer] Video ready to play: \(url.lastPathComponent)")
                            self?.videoPlayer?.play()
                            // 再生開始を確認
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                if let player = self?.videoPlayer {
                                    debugLog("[Renderer] Player rate: \(player.rate), time: \(player.currentTime().seconds)")
                                }
                            }
                        case .failed:
                            debugLog("[Renderer] Video failed to load: \(item.error?.localizedDescription ?? "unknown error")")
                            self?.onVideoLoadFailed?(item.error?.localizedDescription ?? "Video failed to load")
                        case .unknown:
                            debugLog("[Renderer] Video status unknown")
                        @unknown default:
                            break
                        }
                    }
                }

                self.isVideoPlaying = true
                debugLog("[Renderer] Video player created and loading")
            }
        }
    }

    /// 動画の再生を一時停止（音声も含む）
    func pauseVideo() {
        // AVPlayerはスレッドセーフでないため、メインスレッドでアクセス
        DispatchQueue.main.async { [weak self] in
            self?.videoPlayer?.pause()
        }
    }

    /// 動画の再生を再開（音声も含む）
    func resumeVideo() {
        if isVideoPlaying {
            // AVPlayerはスレッドセーフでないため、メインスレッドでアクセス
            DispatchQueue.main.async { [weak self] in
                self?.videoPlayer?.play()
            }
        }
    }

    /// 動画を停止
    func stopVideo() {
        // レンダースレッドからのアクセスを先にブロック（isVideoPlayingはpropertyLockで保護済み）
        isVideoPlaying = false
        hasAudioTrack = false
        hasSignaledCurrentVideoFirstFrame = false

        playerItemStatusObservation?.invalidate()
        playerItemStatusObservation = nil
        // AVPlayerはスレッドセーフでないため、メインスレッドでアクセス
        DispatchQueue.main.async { [weak self] in
            self?.videoPlayer?.pause()
            self?.videoPlayer = nil
        }
        videoOutput = nil
        // CVMetalTextureの参照をクリア
        currentVideoTexture = nil
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
    }

    // MARK: - GIF Animation（フルフレームキャッシュ優先）

    /// GIFファイルを読み込んで再生。
    /// フレームは原則すべてテクスチャキャッシュに載せる（VRAM・容量多め・再生は滑らか優先）。
    func loadGif(from url: URL) {
        stopGif()
        stopVideo()
        releaseSharedStaticImageIfNeeded()

        debugLog("[Renderer] Loading GIF from: \(url.path)")
        gifURL = url
        videoURL = nil
        imageURL = nil

        let srcOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: true
        ]
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, srcOptions as CFDictionary) else {
            debugLog("[Renderer] Failed to create image source for GIF")
            onBackgroundLoadFailed?("Failed to open GIF: \(url.lastPathComponent)")
            return
        }

        let frameCount = CGImageSourceGetCount(imageSource)
        debugLog("[Renderer] GIF has \(frameCount) frames")

        guard frameCount > 0 else {
            debugLog("[Renderer] GIF has no frames")
            onBackgroundLoadFailed?("GIF has no frames: \(url.lastPathComponent)")
            return
        }

        // 最初のフレームから解像度を取得してバッファサイズを動的に計算
        var width = 0
        var height = 0
        if let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] {
            width = properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0
            height = properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        }
        gifFrameWidth = width
        gifFrameHeight = height

        // キャッシュ枠＝全フレーム（リングから追い出さないまで保持）
        gifRingBufferSize = max(3, frameCount)
        if frameCount > 600 {
            debugLog("[Renderer] GIF は \(frameCount) フレームあります。VRAM を大量に使う可能性があります。")
        }

        // フレーム遅延時間を先に全て取得（メタデータのみなので軽量）
        var delays: [Double] = []
        for i in 0..<frameCount {
            var delay: Double = 0.1 // デフォルト100ms
            if let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, i, nil) as? [String: Any],
               let gifProperties = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
                if let delayTime = gifProperties[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double, delayTime > 0 {
                    delay = delayTime
                } else if let delayTime = gifProperties[kCGImagePropertyGIFDelayTime as String] as? Double, delayTime > 0 {
                    delay = delayTime
                }
            }
            delays.append(delay)
        }

        // ストリーミング用の状態を初期化
        gifImageSource = imageSource
        gifTotalFrameCount = frameCount
        gifFrameDelays = delays
        gifCurrentFrame = 0
        gifLastFrameTime = CACurrentMediaTime()
        gifCacheLock.lock()
        gifTextureCache.removeAll()
        gifTextureCacheOrder.removeAll()
        gifCacheLock.unlock()
        gifPendingLock.lock()
        gifPendingFrames.removeAll()
        gifPendingLock.unlock()
        isGifPlaying = true

        // 最初のフレームを同期的にロード（表示開始のため）
        if let texture = loadGifFrameSync(at: 0) {
            backgroundTexture = texture
            completeDeferredBackgroundPresentationIfNeeded()
            onBackgroundReady?()
        } else {
            keepTransparentUntilBackgroundReady = false
            onBackgroundLoadFailed?("Failed to decode first GIF frame: \(url.lastPathComponent)")
            return
        }

        // 近傍を先に、続けて残りフレームをバックグラウンドで順次デコード
        prefetchGifFramesAsync(around: 0)
        prefetchRemainingGifFramesAsync()

        debugLog("[Renderer] GIF loaded (full-cache mode): \(frameCount) frames, buffer size: \(gifRingBufferSize), resolution: \(width)x\(height)")
    }

    /// 1 フレーム目以外を順にキャッシュへ載せる（初回以降のコマ落ちを減らす）。
    private func prefetchRemainingGifFramesAsync() {
        let total = gifTotalFrameCount
        guard total > 1 else { return }
        gifLoadQueue.async { [weak self] in
            guard let self else { return }
            for idx in 1..<total {
                guard self.isGifPlaying else { return }
                self.gifCacheLock.lock()
                let already = self.gifTextureCache[idx] != nil
                self.gifCacheLock.unlock()
                if already { continue }
                _ = self.loadGifFrameSync(at: idx)
            }
        }
    }

    /// 指定インデックスのGIFフレームをテクスチャとしてロード（同期版・初回表示用）
    private func loadGifFrameSync(at index: Int) -> MTLTexture? {
        gifCacheLock.lock()

        // キャッシュにあればそれを返す
        if let cached = gifTextureCache[index] {
            // LRU更新
            if let orderIndex = gifTextureCacheOrder.firstIndex(of: index) {
                gifTextureCacheOrder.remove(at: orderIndex)
            }
            gifTextureCacheOrder.append(index)
            gifCacheLock.unlock()
            return cached
        }
        gifCacheLock.unlock()

        // キャッシュにない場合は新規ロード（ロック外でテクスチャ生成）
        guard let imageSource = gifImageSource,
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, index, nil) else {
            return nil
        }

        let textureLoader = MTKTextureLoader(device: device)
        do {
            let texture = try textureLoader.newTexture(cgImage: cgImage, options: [
                .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                .textureStorageMode: MTLStorageMode.private.rawValue,
                .SRGB: false
            ])

            // キャッシュに追加
            gifCacheLock.lock()
            gifTextureCache[index] = texture
            gifTextureCacheOrder.append(index)

            // キャッシュサイズを超えたら最も古いものを削除
            while gifTextureCacheOrder.count > gifRingBufferSize {
                let oldestIndex = gifTextureCacheOrder.removeFirst()
                gifTextureCache.removeValue(forKey: oldestIndex)
            }
            gifCacheLock.unlock()

            return texture
        } catch {
            debugLog("[Renderer] GIFフレーム \(index) のテクスチャ作成に失敗: \(error)")
            return nil
        }
    }

    /// キャッシュからGIFフレームを取得（なければnil）
    private func getCachedGifFrame(at index: Int) -> MTLTexture? {
        gifCacheLock.lock()
        defer { gifCacheLock.unlock() }

        if let cached = gifTextureCache[index] {
            // LRU更新
            if let orderIndex = gifTextureCacheOrder.firstIndex(of: index) {
                gifTextureCacheOrder.remove(at: orderIndex)
            }
            gifTextureCacheOrder.append(index)
            return cached
        }
        return nil
    }

    /// 次のフレーム周辺を非同期で先読みしてキャッシュに入れる
    private func prefetchGifFramesAsync(around currentIndex: Int) {
        guard gifTotalFrameCount > 0 else { return }

        // 現在のフレームの前後をプリフェッチ（バッファが大きいときは広めに）
        let prefetchRange = min(max(3, gifRingBufferSize / 4), max(1, gifTotalFrameCount - 1))
        for offset in 1...prefetchRange {
            let nextIndex = (currentIndex + offset) % gifTotalFrameCount

            // 既にキャッシュにあるか、ロード中ならスキップ
            gifCacheLock.lock()
            let alreadyCached = gifTextureCache[nextIndex] != nil
            gifCacheLock.unlock()
            gifPendingLock.lock()
            let alreadyPending = gifPendingFrames.contains(nextIndex)
            if !alreadyCached && !alreadyPending {
                gifPendingFrames.insert(nextIndex)
            }
            gifPendingLock.unlock()

            if alreadyCached || alreadyPending {
                continue
            }

            // バックグラウンドで非同期ロード
            gifLoadQueue.async { [weak self] in
                guard let self = self,
                      self.isGifPlaying,
                      let imageSource = self.gifImageSource,
                      let cgImage = CGImageSourceCreateImageAtIndex(imageSource, nextIndex, nil) else {
                    self?.gifPendingLock.lock()
                    self?.gifPendingFrames.remove(nextIndex)
                    self?.gifPendingLock.unlock()
                    return
                }

                let textureLoader = MTKTextureLoader(device: self.device)
                do {
                    let texture = try textureLoader.newTexture(cgImage: cgImage, options: [
                        .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                        .textureStorageMode: MTLStorageMode.private.rawValue,
                        .SRGB: false
                    ])

                    // メインスレッドでキャッシュを更新
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, self.isGifPlaying else { return }

                        self.gifCacheLock.lock()
                        self.gifTextureCache[nextIndex] = texture
                        self.gifTextureCacheOrder.append(nextIndex)

                        // キャッシュサイズを超えたら最も古いものを削除
                        while self.gifTextureCacheOrder.count > self.gifRingBufferSize {
                            let oldestIndex = self.gifTextureCacheOrder.removeFirst()
                            self.gifTextureCache.removeValue(forKey: oldestIndex)
                        }
                        self.gifCacheLock.unlock()

                        self.gifPendingLock.lock()
                        self.gifPendingFrames.remove(nextIndex)
                        self.gifPendingLock.unlock()
                    }
                } catch {
                    self.gifPendingLock.lock()
                    self.gifPendingFrames.remove(nextIndex)
                    self.gifPendingLock.unlock()
                }
            }
        }
    }

    /// GIFを停止
    func stopGif() {
        isGifPlaying = false
        gifImageSource = nil
        gifTotalFrameCount = 0
        gifFrameDelays = []
        gifCurrentFrame = 0
        gifFrameWidth = 0
        gifFrameHeight = 0
        gifCacheLock.lock()
        gifTextureCache.removeAll()
        gifTextureCacheOrder.removeAll()
        gifCacheLock.unlock()
        gifPendingLock.lock()
        gifPendingFrames.removeAll()
        gifPendingLock.unlock()
        gifURL = nil
    }

    private func releaseSharedStaticImageIfNeeded() {
        guard let key = sharedStaticImageCacheKey else { return }
        SharedStaticImageTextureCache.shared.releaseTexture(for: key)
        sharedStaticImageCacheKey = nil
    }

    private func makeSharedStaticImageCacheKey(for url: URL) -> String {
        let normalizedURL = url.standardizedFileURL
        let values = try? normalizedURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        let fileSize = values?.fileSize ?? -1
        return "\(normalizedURL.path)#\(fileSize)#\(modified)"
    }

    /// GIFフレームを更新
    private func updateGifFrame() {
        guard isGifPlaying, gifTotalFrameCount > 0 else { return }

        let currentTime = CACurrentMediaTime()
        let elapsed = currentTime - gifLastFrameTime
        let delay = gifFrameDelays.isEmpty ? 0.1 : gifFrameDelays[gifCurrentFrame]

        if elapsed >= delay {
            let nextFrame = (gifCurrentFrame + 1) % gifTotalFrameCount

            // キャッシュからフレームを取得を試みる
            if let texture = getCachedGifFrame(at: nextFrame) {
                gifCurrentFrame = nextFrame
                backgroundTexture = texture
                gifLastFrameTime = currentTime

                // 次のフレーム周辺を非同期でプリフェッチ
                prefetchGifFramesAsync(around: gifCurrentFrame)
            } else {
                // キャッシュにない場合はフレームをスキップせず、同期ロードにフォールバック
                // これは稀なケース（プリフェッチが間に合わなかった場合）
                if let texture = loadGifFrameSync(at: nextFrame) {
                    gifCurrentFrame = nextFrame
                    backgroundTexture = texture
                    gifLastFrameTime = currentTime
                    prefetchGifFramesAsync(around: gifCurrentFrame)
                }
            }
        }
    }

    /// 動画フレームをテクスチャに更新
    /// 120FPS描画時でも動画のフレームレートに合わせて更新をスキップし、GPU負荷を軽減
    private func updateVideoFrame() {
        guard isVideoPlaying,
              let videoOutput = videoOutput,
              let textureCache = textureCache else {
            return
        }

        let currentTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())

        guard videoOutput.hasNewPixelBuffer(forItemTime: currentTime) else {
            return
        }

        guard let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: currentTime, itemTimeForDisplay: nil) else {
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )

        if result == kCVReturnSuccess, let cvTexture = cvTexture {
            // CVMetalTextureの参照を保持してバッキングメモリを維持
            currentVideoTexture = cvTexture
            backgroundTexture = CVMetalTextureGetTexture(cvTexture)
            if !hasSignaledCurrentVideoFirstFrame {
                hasSignaledCurrentVideoFirstFrame = true
                completeDeferredBackgroundPresentationIfNeeded()
                DispatchQueue.main.async { [weak self] in
                    self?.onVideoFirstFrameReady?()
                }
            }
        }

        // テクスチャキャッシュを時間ベースで定期的にフラッシュしてメモリを解放
        // フレームレートに依存せず、一定時間ごとにフラッシュ
        let now = CACurrentMediaTime()
        if now - lastTextureCacheFlushTime >= textureCacheFlushIntervalSeconds {
            CVMetalTextureCacheFlush(textureCache, 0)
            lastTextureCacheFlushTime = now
        }
    }

    /// 背景ファイルを読み込む（画像、動画、GIFを自動判別）
    func loadBackground(from url: URL, keepTransparentUntilReady: Bool = false) {
        self.keepTransparentUntilBackgroundReady = keepTransparentUntilReady
        isTransparentMode = keepTransparentUntilReady

        let ext = url.pathExtension.lowercased()
        let videoExtensions = ["mp4", "mov", "m4v"]
        let gifExtensions = ["gif"]

        if videoExtensions.contains(ext) {
            stopGif()
            loadVideo(from: url)
        } else if gifExtensions.contains(ext) {
            stopVideo()
            loadGif(from: url)
        } else {
            stopVideo()
            stopGif()
            loadBackgroundImage(from: url)
        }
    }

    private func completeDeferredBackgroundPresentationIfNeeded() {
        guard keepTransparentUntilBackgroundReady else { return }
        keepTransparentUntilBackgroundReady = false
        isTransparentMode = false
    }

    // MARK: - Mouse Interaction (マウスインタラクション)

    /// マウスクリックを処理
    func handleClick(at normalizedPosition: SIMD2<Float>) {
        mousePosition = normalizedPosition
        lastClickTime = CACurrentMediaTime()
        clickActive = true

        // 2秒後にクリックエフェクトを非アクティブに
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.clickActive = false
        }
    }

    // MARK: - MP4 Export (エクスポート)

    /// 現在のシェーダーエフェクトをMP4として書き出す
    /// - Parameters:
    ///   - url: 保存先のURL
    ///   - duration: 動画の長さ（秒）
    ///   - size: 出力解像度
    ///   - fps: フレームレート
    ///   - completion: 完了コールバック
    func exportToMP4(
        to url: URL,
        duration: Double = 10.0,
        size: CGSize = CGSize(width: 1920, height: 1080),
        fps: Int = 30,
        progress: ((Double) -> Void)? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        // エクスポート用のパイプラインを設定
        setupPipeline(pixelFormat: .bgra8Unorm)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                // 既存ファイルを削除
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }

                // AVAssetWriterの設定
                let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

                let videoSettings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: Int(size.width),
                    AVVideoHeightKey: Int(size.height),
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: 10_000_000,
                        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                    ]
                ]

                let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                writerInput.expectsMediaDataInRealTime = false

                let pixelBufferAttributes: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: Int(size.width),
                    kCVPixelBufferHeightKey as String: Int(size.height),
                    kCVPixelBufferMetalCompatibilityKey as String: true
                ]

                let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: writerInput,
                    sourcePixelBufferAttributes: pixelBufferAttributes
                )

                writer.add(writerInput)

                guard writer.startWriting() else {
                    throw writer.error ?? NSError(domain: "Renderer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to start writing"])
                }

                writer.startSession(atSourceTime: .zero)

                // オフスクリーンテクスチャを作成
                let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm,
                    width: Int(size.width),
                    height: Int(size.height),
                    mipmapped: false
                )
                textureDescriptor.usage = [.renderTarget, .shaderRead]
                textureDescriptor.storageMode = .managed

                guard let offscreenTexture = self.device.makeTexture(descriptor: textureDescriptor) else {
                    throw NSError(domain: "Renderer", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create offscreen texture"])
                }

                let totalFrames = Int(duration * Double(fps))
                let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))

                for frameIndex in 0..<totalFrames {
                    // 進捗を報告
                    let currentProgress = Double(frameIndex) / Double(totalFrames)
                    DispatchQueue.main.async {
                        progress?(currentProgress)
                    }

                    // フレームをレンダリング
                    let time = Float(frameIndex) / Float(fps)

                    autoreleasepool {
                        self.renderFrame(to: offscreenTexture, time: time, size: size)

                        // ピクセルバッファを作成してコピー
                        guard let pixelBufferPool = adaptor.pixelBufferPool else {
                            debugLog("Pixel buffer pool is nil at frame \(frameIndex)")
                            return
                        }

                        var pixelBuffer: CVPixelBuffer?
                        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBuffer)
                        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
                            debugLog("Failed to create pixel buffer: \(status)")
                            return
                        }

                        // テクスチャからピクセルバッファにコピー
                        CVPixelBufferLockBaseAddress(buffer, [])
                        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

                        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
                            return
                        }

                        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                        let region = MTLRegionMake2D(0, 0, Int(size.width), Int(size.height))
                        offscreenTexture.getBytes(baseAddress, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)

                        // フレームを書き込み
                        // ビジーウェイトにタイムアウトを設定（最大10秒）
                        var waitCount = 0
                        while !writerInput.isReadyForMoreMediaData {
                            Thread.sleep(forTimeInterval: 0.01)
                            waitCount += 1
                            if waitCount > 1000 { break }
                        }

                        let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))
                        adaptor.append(buffer, withPresentationTime: presentationTime)
                    }
                }

                // 完了処理
                writerInput.markAsFinished()

                let semaphore = DispatchSemaphore(value: 0)
                writer.finishWriting {
                    semaphore.signal()
                }
                semaphore.wait()

                if writer.status == .completed {
                    DispatchQueue.main.async {
                        progress?(1.0)
                        completion(.success(url))
                    }
                } else {
                    throw writer.error ?? NSError(domain: "Renderer", code: -3, userInfo: [NSLocalizedDescriptionKey: "Unknown error"])
                }

            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    /// オフスクリーンでフレームをレンダリング
    private func renderFrame(to texture: MTLTexture, time: Float, size: CGSize) {
        guard let pipelineState = pipelineState,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        let hasMask: Int32 = maskTexture != nil ? 1 : 0
        let spanConfig = displaySpanConfigurationSnapshot()

        var uniforms = Uniforms(
            time: time,
            resolution: SIMD2<Float>(Float(size.width), Float(size.height)),
            shaderType: Int32(currentShader.rawValue),
            hasBackgroundImage: backgroundTexture != nil ? 1 : 0,
            effectIntensity: effectIntensity,
            mousePosition: SIMD2<Float>(0.5, 0.5),
            clickTime: 100.0,  // クリックエフェクトなし
            clickActive: 0,
            octaveCount: 5,    // エクスポートは最高品質
            hasMaskTexture: hasMask,
            spanWallpaperAcrossDisplays: spanConfig.enabled,
            displayOrigin: spanConfig.origin,
            displaySize: spanConfig.size,
            canvasSize: spanConfig.canvasSize
        )

        logShaderDimensionsIfNeeded(context: "offscreen", resolution: uniforms.resolution, texture: backgroundTexture)

        // エフェクトUniformsを生成
        var effectUniforms = EffectUniforms(from: effectConfiguration)

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        renderEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 0)
        renderEncoder.setFragmentBytes(&effectUniforms, length: MemoryLayout<EffectUniforms>.size, index: 1)

        if let bgTexture = backgroundTexture {
            renderEncoder.setFragmentTexture(bgTexture, index: 0)
        }

        if let mask = maskTexture {
            renderEncoder.setFragmentTexture(mask, index: 1)
        }

        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()

        // 管理モードのテクスチャはsynchronizeが必要
        if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.synchronize(resource: texture)
            blitEncoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    // MARK: - 静止画エクスポート

    /// 現在のエフェクト状態を画面解像度の静止画としてエクスポート
    func exportAsImage(size: CGSize? = nil) -> NSImage? {
        let exportSize: CGSize
        if let size = size {
            exportSize = size
        } else if let screen = NSScreen.main {
            exportSize = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                                height: screen.frame.height * screen.backingScaleFactor)
        } else {
            exportSize = CGSize(width: 1920, height: 1080)
        }

        // エクスポート用のパイプラインを設定
        setupPipeline(pixelFormat: .bgra8Unorm)

        // オフスクリーンテクスチャを作成
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(exportSize.width),
            height: Int(exportSize.height),
            mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .managed

        guard let offscreenTexture = device.makeTexture(descriptor: textureDescriptor) else {
            debugLog("[Renderer] オフスクリーンテクスチャの作成に失敗しました")
            return nil
        }

        // 現在の時刻でフレームをレンダリング
        let currentTime = Float(CACurrentMediaTime() - startTime)
        renderFrame(to: offscreenTexture, time: currentTime, size: exportSize)

        // テクスチャからNSImageに変換
        let width = Int(exportSize.width)
        let height = Int(exportSize.height)
        let bytesPerRow = width * 4
        let totalBytes = bytesPerRow * height

        var pixelData = [UInt8](repeating: 0, count: totalBytes)
        let region = MTLRegionMake2D(0, 0, width, height)
        offscreenTexture.getBytes(&pixelData, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)

        // BGRAからRGBAに変換
        for i in stride(from: 0, to: totalBytes, by: 4) {
            let b = pixelData[i]
            pixelData[i] = pixelData[i + 2]      // R
            pixelData[i + 2] = b                   // B
        }

        guard let provider = CGDataProvider(data: Data(pixelData) as CFData),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            debugLog("[Renderer] CGImageの作成に失敗しました")
            return nil
        }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        return nsImage
    }

    /// 静止画をファイルに保存
    func exportToFile(url: URL, format: NSBitmapImageRep.FileType = .png, size: CGSize? = nil) -> Bool {
        guard let image = exportAsImage(size: size),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let data = bitmap.representation(using: format, properties: [:]) else {
            debugLog("[Renderer] 画像のファイル出力に失敗しました")
            return false
        }

        do {
            try data.write(to: url)
            debugLog("[Renderer] 画像をエクスポートしました: \(url.path)")
            return true
        } catch {
            debugLog("[Renderer] 画像の書き込みに失敗しました: \(error)")
            return false
        }
    }

    // MARK: - Effect Management (エフェクト管理)

    /// エフェクト設定を更新
    func updateEffectConfiguration(_ config: EffectConfiguration) {
        effectConfiguration = config
    }

    /// マスクテクスチャを更新
    func updateMaskTexture(from maskData: MaskData) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: maskData.width,
            height: maskData.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return
        }

        let region = MTLRegionMake2D(0, 0, maskData.width, maskData.height)
        texture.replace(region: region, mipmapLevel: 0, withBytes: maskData.data, bytesPerRow: maskData.width)

        maskTexture = texture
    }

    /// マスクテクスチャをクリア
    func clearMaskTexture() {
        maskTexture = nil
    }
}
