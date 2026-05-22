import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import Metal

// MARK: - VideoWallpaperRuntimeProtocol

/// 動画壁紙ランタイムの公開 API。
/// Why: 既存 Renderer の AVPlayer 経路と切り離し、Wallpaper Engine 互換の
///   多様な拡張子 (mp4/webm/mov/m4v/avi/wmv) を AVAssetReader で HW デコード
///   しつつ、出力フレームを WGPU レイヤー / MTKView の双方に供給するため。
protocol VideoWallpaperRuntimeProtocol: AnyObject {
    var url: URL { get }
    var size: CGSize { get }
    var duration: CMTime { get }
    /// 最新デコードフレームの Metal テクスチャ（描画スレッドから読み取り可）
    var currentFrameTexture: MTLTexture? { get }
    func play()
    func pause()
    func setVolume(_ value: Float)
    /// IOSurface 直接受け渡し用 (artia-wgpu との連携で利用)
    func currentFrameIOSurface() -> IOSurface?
}

// MARK: - 対応拡張子

/// Wallpaper Engine 互換の動画拡張子集合。
/// - Note: webm/avi/wmv は OS 標準コーデック未対応の場合があるが、AVURLAsset で
///         tracks(withMediaType:) を確認してフォールバック判定する。
enum VideoWallpaperFormat {
    static let supportedExtensions: Set<String> = [
        "mp4", "m4v", "mov", "webm", "avi", "wmv"
    ]

    static func isVideoURL(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}

// MARK: - 失敗種別

enum VideoWallpaperRuntimeError: Error, LocalizedError {
    case fileNotFound(URL)
    case unsupportedFormat(URL)
    case noVideoTrack(URL)
    case readerInitializationFailed(URL, Error?)
    case metalDeviceUnavailable

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "動画ファイルが見つかりません: \(url.lastPathComponent)"
        case .unsupportedFormat(let url):
            return "対応していない動画形式です: \(url.lastPathComponent)"
        case .noVideoTrack(let url):
            return "ビデオトラックが含まれていません: \(url.lastPathComponent)"
        case .readerInitializationFailed(let url, let error):
            return "AVAssetReader の初期化に失敗しました: \(url.lastPathComponent) (\(error?.localizedDescription ?? "unknown"))"
        case .metalDeviceUnavailable:
            return "Metal デバイスが利用できないためデコードを開始できません"
        }
    }
}

// MARK: - VideoWallpaperRuntime

/// AVAssetReader ベースの動画壁紙ランタイム。
/// - VideoToolbox HW デコードを CoreVideo Metal-compatible バッファ経由で受け取る。
/// - EOF 検知時に reader を再構築してシームレスループ。
/// - 1 ストリーム = 1 wgpu レイヤー想定。
final class VideoWallpaperRuntime: VideoWallpaperRuntimeProtocol {

    // MARK: 公開プロパティ
    let url: URL
    private(set) var size: CGSize = .zero
    private(set) var duration: CMTime = .zero

    var currentFrameTexture: MTLTexture? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _currentFrameTexture
    }

    // MARK: 内部状態
    private let metalDevice: MTLDevice
    private let textureCache: CVMetalTextureCache
    private let asset: AVURLAsset
    private var assetReader: AVAssetReader?
    private var trackOutput: AVAssetReaderTrackOutput?
    private var displayLink: CVDisplayLink?

    /// 再生フラグ (UI スレッド以外からも更新される)
    private var _isPlaying: Bool = false
    /// 現在のフレーム (描画スレッド競合回避のためロック保護)
    private var _currentFrameTexture: MTLTexture?
    /// CVMetalTextureGetTexture の元参照を保持してバッキングを維持
    private var _currentCVTexture: CVMetalTexture?
    /// IOSurface 直送りを要求された場合の最新フレーム
    private var _currentIOSurface: IOSurface?
    /// 最後にデコード済みのプレゼンテーション時刻
    private var lastPresentationTime: CMTime = .invalid
    /// 音量 (将来の AVAudioEngine 連携用に保持。現状はフィールドのみ)
    private var volume: Float = 1.0

    /// 状態更新ロック (CADisplayLink callback と UI から共有される)
    private let stateLock = NSLock()
    /// ホストレート / videoTrack 情報のキャッシュ
    private var nominalFrameRate: Float = 30.0
    /// ループ用に readers を再生成する際の排他制御
    private var isRebuildingReader: Bool = false

    // MARK: 初期化

    /// 動画ファイルから初期化する。
    /// - throws: 拡張子未対応 / ファイル欠如 / ビデオトラック無し / Metal デバイス取得不可
    init(url: URL, metalDevice: MTLDevice? = nil) throws {
        self.url = url

        guard VideoWallpaperFormat.isVideoURL(url) else {
            throw VideoWallpaperRuntimeError.unsupportedFormat(url)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VideoWallpaperRuntimeError.fileNotFound(url)
        }
        guard let device = metalDevice ?? MTLCreateSystemDefaultDevice() else {
            throw VideoWallpaperRuntimeError.metalDeviceUnavailable
        }
        self.metalDevice = device

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let unwrappedCache = cache else {
            throw VideoWallpaperRuntimeError.metalDeviceUnavailable
        }
        self.textureCache = unwrappedCache

        // AVURLAsset を生成し、ビデオトラックの存在を同期確認する。
        // Why: ランタイム生成直後に呼び出し側が isVideo 判定済みである前提なので、
        //      ここで AVAsset レベルでも未対応コーデック (webm/avi 等) を捕捉する。
        self.asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
        let videoTracks = asset.tracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw VideoWallpaperRuntimeError.noVideoTrack(url)
        }
        let transformed = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        self.size = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        self.duration = asset.duration
        self.nominalFrameRate = videoTrack.nominalFrameRate > 0 ? videoTrack.nominalFrameRate : 30.0
    }

    deinit {
        stop()
    }

    // MARK: 再生制御

    func play() {
        stateLock.lock()
        let alreadyPlaying = _isPlaying
        stateLock.unlock()
        if alreadyPlaying { return }

        do {
            try startReaderIfNeeded()
        } catch {
            debugLog("[VideoWallpaperRuntime] reader 開始失敗: \(error.localizedDescription)")
            return
        }

        stateLock.lock()
        _isPlaying = true
        stateLock.unlock()

        ensureDisplayLink()
        if let link = displayLink, !CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStart(link)
        }
    }

    func pause() {
        stateLock.lock()
        _isPlaying = false
        stateLock.unlock()
        if let link = displayLink, CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStop(link)
        }
    }

    func setVolume(_ value: Float) {
        // 現状 AVAssetReader 経路は音声を扱わない。
        // Why: Phase 3A は映像のみ。AVAudioEngine 連携は後続フェーズで追加する。
        volume = max(0.0, min(value, 1.0))
    }

    func currentFrameIOSurface() -> IOSurface? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _currentIOSurface
    }

    /// 完全停止して内部リソースを解放する (deinit から呼ばれる)
    func stop() {
        if let link = displayLink {
            if CVDisplayLinkIsRunning(link) { CVDisplayLinkStop(link) }
            displayLink = nil
        }
        stateLock.lock()
        _isPlaying = false
        _currentFrameTexture = nil
        _currentCVTexture = nil
        _currentIOSurface = nil
        stateLock.unlock()
        if let reader = assetReader, reader.status == .reading {
            reader.cancelReading()
        }
        assetReader = nil
        trackOutput = nil
    }

    // MARK: 内部ヘルパー

    /// AVAssetReader を初期化（または使い終わったものを再構築）。
    private func startReaderIfNeeded() throws {
        if assetReader?.status == .reading { return }
        try rebuildReader()
    }

    /// EOF / cancel 後に reader を再構築する。
    /// - Note: 黒フレーム挿入を避けるため呼び出し側ではフレーム差し替えを行わない。
    private func rebuildReader() throws {
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw VideoWallpaperRuntimeError.noVideoTrack(url)
        }
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw VideoWallpaperRuntimeError.readerInitializationFailed(url, error)
        }
        guard reader.canAdd(output) else {
            throw VideoWallpaperRuntimeError.readerInitializationFailed(url, nil)
        }
        reader.add(output)
        if !reader.startReading() {
            throw VideoWallpaperRuntimeError.readerInitializationFailed(url, reader.error)
        }
        assetReader = reader
        trackOutput = output
        lastPresentationTime = .invalid
    }

    /// CVDisplayLink を確保し、コールバック経由でフレームを進める。
    /// Why: ディスプレイ refresh と同期することで 60fps 超でも余分な GPU を使わない。
    private func ensureDisplayLink() {
        if displayLink != nil { return }
        var link: CVDisplayLink?
        let status = CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard status == kCVReturnSuccess, let displayLink = link else { return }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(displayLink, { _, _, _, _, _, userInfo in
            guard let userInfo = userInfo else { return kCVReturnSuccess }
            let runtime = Unmanaged<VideoWallpaperRuntime>.fromOpaque(userInfo).takeUnretainedValue()
            runtime.tickFrame()
            return kCVReturnSuccess
        }, opaque)
        self.displayLink = displayLink
    }

    /// CVDisplayLink コールバックから呼ばれてフレームを 1 つ進める。
    private func tickFrame() {
        stateLock.lock()
        let playing = _isPlaying
        let rebuilding = isRebuildingReader
        stateLock.unlock()
        guard playing, !rebuilding, let output = trackOutput else { return }

        guard let sample = output.copyNextSampleBuffer() else {
            // EOF の場合は reader 再構築。失敗時は黙ってスキップする。
            handleEndOfStream()
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
        lastPresentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
        publishPixelBuffer(pixelBuffer)
    }

    private func handleEndOfStream() {
        stateLock.lock()
        if isRebuildingReader { stateLock.unlock(); return }
        isRebuildingReader = true
        stateLock.unlock()

        defer {
            stateLock.lock()
            isRebuildingReader = false
            stateLock.unlock()
        }
        do {
            try rebuildReader()
        } catch {
            debugLog("[VideoWallpaperRuntime] ループ再構築失敗: \(error.localizedDescription)")
        }
    }

    /// CVPixelBuffer を MTLTexture へ変換し、内部状態に publish する。
    private func publishPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
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
        guard result == kCVReturnSuccess, let cvTexture else { return }
        let texture = CVMetalTextureGetTexture(cvTexture)
        let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()

        stateLock.lock()
        _currentCVTexture = cvTexture
        _currentFrameTexture = texture
        _currentIOSurface = surface
        stateLock.unlock()

        // 一定時間ごとにテクスチャキャッシュを掃除する負荷は呼出側で吸収できる。
        // Renderer 側と同様、頻度は控えめでよい。
        CVMetalTextureCacheFlush(textureCache, 0)
    }
}

