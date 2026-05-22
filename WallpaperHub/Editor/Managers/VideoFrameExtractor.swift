import AVFoundation
import Metal
import MetalKit
import CoreVideo

// MARK: - LRUキャッシュ

/// 簡易LRUキャッシュ（外部依存なし）
/// 末尾が最新、先頭が最古のエントリ
class LRUCache<Key: Hashable, Value> {

    private var dict: [Key: Value] = [:]
    private var order: [Key] = []
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    subscript(key: Key) -> Value? {
        get {
            guard let value = dict[key] else { return nil }
            order.removeAll { $0 == key }
            order.append(key)
            return value
        }
        set {
            if let value = newValue {
                dict[key] = value
                order.removeAll { $0 == key }
                order.append(key)
                while order.count > capacity {
                    let oldest = order.removeFirst()
                    dict.removeValue(forKey: oldest)
                }
            } else {
                dict.removeValue(forKey: key)
                order.removeAll { $0 == key }
            }
        }
    }

    func removeAll() {
        dict.removeAll()
        order.removeAll()
    }
}

// MARK: - 動画フレーム抽出エンジン

/// MP4/MOV動画からフレームを抽出してMTLTextureに変換する
/// LRUキャッシュ付きで、タイムライン再生時のパフォーマンスを確保する
class VideoFrameExtractor {

    // MARK: - プロパティ

    /// 動画アセット
    let asset: AVURLAsset

    /// 動画ファイルパス
    let videoPath: String

    /// 動画メタデータ
    let duration: Double
    let fps: Double
    let videoSize: CGSize

    /// Metal連携
    private let device: MTLDevice

    /// フレーム生成用
    private let imageGenerator: AVAssetImageGenerator

    /// LRUフレームキャッシュ（フレームインデックス→MTLTexture）
    private let frameCache = LRUCache<Int, MTLTexture>(capacity: 30)

    /// スレッドセーフ用ロック
    private let lock = NSLock()

    // MARK: - 初期化

    /// 同期的な初期化（メタデータをセマフォで待機して取得）
    init?(url: URL, device: MTLDevice) {
        self.videoPath = url.path
        self.device = device

        let localAsset = AVURLAsset(url: url)
        self.asset = localAsset

        // AVAssetImageGenerator 設定
        let generator = AVAssetImageGenerator(asset: localAsset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.02, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.02, preferredTimescale: 600)
        self.imageGenerator = generator

        // async APIからメタデータを同期的に取得（メインスレッドブロックを回避するためdetached Taskを使用）
        let semaphore = DispatchSemaphore(value: 0)
        var loadedDuration: Double = 0
        var loadedFPS: Double = 0
        var loadedSize: CGSize = .zero
        var loadFailed = false

        Task.detached {
            do {
                let durationValue = try await localAsset.load(.duration)
                loadedDuration = CMTimeGetSeconds(durationValue)

                let tracks = try await localAsset.loadTracks(withMediaType: .video)
                guard let videoTrack = tracks.first else {
                    print("[VideoFrameExtractor] 動画トラックが見つかりません: \(url.path)")
                    loadFailed = true
                    semaphore.signal()
                    return
                }

                loadedFPS = Double(try await videoTrack.load(.nominalFrameRate))
                let naturalSize = try await videoTrack.load(.naturalSize)
                let transform = try await videoTrack.load(.preferredTransform)
                let transformedSize = naturalSize.applying(transform)
                loadedSize = CGSize(
                    width: abs(transformedSize.width),
                    height: abs(transformedSize.height)
                )
            } catch {
                print("[VideoFrameExtractor] メタデータ読み込み失敗: \(error.localizedDescription)")
                loadFailed = true
            }
            semaphore.signal()
        }

        semaphore.wait()

        guard !loadFailed, loadedDuration > 0, loadedFPS > 0 else {
            print("[VideoFrameExtractor] 無効な動画メタデータ: duration=\(loadedDuration), fps=\(loadedFPS)")
            return nil
        }

        self.duration = loadedDuration
        self.fps = loadedFPS
        self.videoSize = loadedSize

        print("[VideoFrameExtractor] 初期化完了: \(url.lastPathComponent)")
        print("  デュレーション: \(String(format: "%.2f", duration))秒")
        print("  FPS: \(String(format: "%.1f", fps))")
        print("  解像度: \(Int(videoSize.width))x\(Int(videoSize.height))")
    }

    // MARK: - フレーム取得

    /// 指定時刻のフレームをMTLTextureとして取得（キャッシュ付き）
    func frameTexture(at time: Double) -> MTLTexture? {
        let clampedTime = max(0, min(time, duration - 0.001))
        let frameIndex = Int(clampedTime * fps)

        lock.lock()
        defer { lock.unlock() }

        // キャッシュヒットチェック
        if let cached = frameCache[frameIndex] {
            return cached
        }

        // キャッシュミス: フレームをデコード
        let cmTime = CMTime(seconds: clampedTime, preferredTimescale: 600)

        var cgImage: CGImage?
        let semaphore = DispatchSemaphore(value: 0)

        imageGenerator.generateCGImagesAsynchronously(
            forTimes: [NSValue(time: cmTime)]
        ) { _, image, _, _, _ in
            cgImage = image
            semaphore.signal()
        }

        semaphore.wait()

        guard let image = cgImage else {
            print("[VideoFrameExtractor] フレーム取得失敗: time=\(String(format: "%.3f", clampedTime))")
            return nil
        }

        // CGImage → MTLTexture 変換
        guard let texture = createTexture(from: image) else {
            return nil
        }

        // キャッシュに追加
        frameCache[frameIndex] = texture

        return texture
    }

    /// サムネイル用: 先頭フレームのテクスチャを取得
    func thumbnailTexture() -> MTLTexture? {
        return frameTexture(at: 0)
    }

    /// キャッシュをクリア
    func clearCache() {
        lock.lock()
        frameCache.removeAll()
        lock.unlock()
    }

    // MARK: - テクスチャ変換

    /// CGImageからMTLTextureを生成
    private func createTexture(from cgImage: CGImage) -> MTLTexture? {
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue,
            .SRGB: false
        ]
        return try? loader.newTexture(cgImage: cgImage, options: options)
    }

    // MARK: - ヘルパー

    /// 総フレーム数
    var totalFrames: Int {
        Int(duration * fps)
    }

    /// フレームインデックスから時刻を計算
    func time(forFrame index: Int) -> Double {
        Double(index) / fps
    }
}
