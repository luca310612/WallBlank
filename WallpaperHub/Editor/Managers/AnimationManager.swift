import Foundation
import AVFoundation
import CoreMedia
import Combine
import QuartzCore

/// アニメーション制御マネージャー
/// コマ送り・キーフレーム補間・タイムラインを管理
class AnimationManager: ObservableObject {

    // MARK: - Published Properties

    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var totalDuration: Double = 5.0
    @Published var fps: Double = 24
    @Published var currentFrameIndex: Int = 0

    // MARK: - キーフレーム管理

    /// レイヤーごとのアニメーションデータ
    @Published var layerAnimations: [UUID: LayerAnimation] = [:]

    // MARK: - タイマー

    private var displayTimer: Timer?
    private var lastUpdateTime: TimeInterval = 0

    // MARK: - コールバック

    /// フレーム更新時のコールバック
    var onFrameUpdate: ((Double) -> Void)?

    // MARK: - 計算プロパティ

    /// 現在のフレーム番号
    var currentFrame: Int {
        Int(currentTime * fps)
    }

    /// 総フレーム数
    var totalFrames: Int {
        Int(totalDuration * fps)
    }

    /// フレームごとの時間（秒）
    var frameDuration: Double {
        1.0 / fps
    }

    // MARK: - 再生制御

    /// 再生開始
    func play() {
        guard !isPlaying else { return }
        isPlaying = true
        lastUpdateTime = CACurrentMediaTime()

        displayTimer = Timer.scheduledTimer(
            withTimeInterval: frameDuration,
            repeats: true
        ) { [weak self] _ in
            self?.updateFrame()
        }

        print("[AnimationManager] 再生開始 (FPS: \(fps))")
    }

    /// 一時停止
    func pause() {
        isPlaying = false
        displayTimer?.invalidate()
        displayTimer = nil
        print("[AnimationManager] 一時停止")
    }

    /// 停止（先頭に戻る）
    func stop() {
        pause()
        currentTime = 0
        currentFrameIndex = 0
        onFrameUpdate?(0)
    }

    /// 指定時刻にシーク
    func seekTo(_ time: Double) {
        currentTime = max(0, min(time, totalDuration))
        currentFrameIndex = Int(currentTime * fps)
        onFrameUpdate?(currentTime)
    }

    /// 次のフレームに進む
    func nextFrame() {
        let nextTime = currentTime + frameDuration
        if nextTime > totalDuration {
            seekTo(0) // ループ
        } else {
            seekTo(nextTime)
        }
    }

    /// 前のフレームに戻る
    func previousFrame() {
        let prevTime = currentTime - frameDuration
        if prevTime < 0 {
            seekTo(totalDuration - frameDuration)
        } else {
            seekTo(prevTime)
        }
    }

    // MARK: - フレーム更新

    private func updateFrame() {
        let now = CACurrentMediaTime()
        let deltaTime = now - lastUpdateTime
        lastUpdateTime = now

        currentTime += deltaTime

        // ループ再生
        if currentTime >= totalDuration {
            currentTime = currentTime.truncatingRemainder(dividingBy: totalDuration)
        }

        currentFrameIndex = Int(currentTime * fps)
        onFrameUpdate?(currentTime)
    }

    // MARK: - キーフレーム操作

    /// レイヤーにキーフレームを追加
    func addKeyframe(
        layerID: UUID,
        propertyName: String,
        time: Double,
        value: Float,
        interpolation: InterpolationType = .linear
    ) {
        var animation = layerAnimations[layerID] ?? LayerAnimation(layerID: layerID)
        var track = animation.getOrCreateTrack(for: propertyName)
        let keyframe = Keyframe(time: time, value: value, interpolation: interpolation)
        track.addKeyframe(keyframe)

        // トラックを更新
        if let trackIndex = animation.tracks.firstIndex(where: { $0.propertyName == propertyName }) {
            animation.tracks[trackIndex] = track
        }

        layerAnimations[layerID] = animation
    }

    /// キーフレームを削除
    func removeKeyframe(layerID: UUID, propertyName: String, keyframeID: UUID) {
        guard var animation = layerAnimations[layerID] else { return }
        if let trackIndex = animation.tracks.firstIndex(where: { $0.propertyName == propertyName }) {
            animation.tracks[trackIndex].removeKeyframe(id: keyframeID)
            layerAnimations[layerID] = animation
        }
    }

    /// 指定時刻でのLayerTransformを評価
    func evaluateTransform(for layerID: UUID, at time: Double, base: LayerTransform) -> LayerTransform {
        guard let animation = layerAnimations[layerID] else { return base }
        return animation.evaluateTransform(at: time, base: base)
    }

    /// 指定時刻でのImageAdjustmentsを評価
    func evaluateAdjustments(for layerID: UUID, at time: Double, base: ImageAdjustments) -> ImageAdjustments {
        guard let animation = layerAnimations[layerID] else { return base }
        return animation.evaluateAdjustments(at: time, base: base)
    }

    /// 指定時刻での不透明度を評価
    func evaluateOpacity(for layerID: UUID, at time: Double, base: Float) -> Float {
        guard let animation = layerAnimations[layerID] else { return base }
        return animation.evaluateOpacity(at: time, base: base)
    }

    /// 指定レイヤーにアニメーションがあるか
    func hasAnimation(for layerID: UUID) -> Bool {
        guard let animation = layerAnimations[layerID] else { return false }
        return !animation.tracks.isEmpty
    }

    /// 指定レイヤーのキーフレームをすべて削除
    func clearAnimation(for layerID: UUID) {
        layerAnimations.removeValue(forKey: layerID)
    }

    /// すべてのアニメーションをクリア
    func clearAllAnimations() {
        layerAnimations.removeAll()
    }

    // MARK: - コマ送りフレーム管理

    /// レイヤーのフレームアニメーションを更新
    func updateFrameAnimation(for layer: EditorLayer, at time: Double) {
        // 動画レイヤーの場合: 専用のフレーム更新処理
        if layer.isVideoLayer {
            updateVideoFrame(for: layer, at: time)
            return
        }

        guard !layer.frames.isEmpty else { return }

        // 経過時間に基づいてフレームを計算
        var accumulatedTime: Double = 0
        for (index, frame) in layer.frames.enumerated() {
            accumulatedTime += frame.duration
            if time < accumulatedTime {
                layer.currentFrameIndex = index
                return
            }
        }

        // ループ
        let totalFrameTime = layer.frames.reduce(0) { $0 + $1.duration }
        if totalFrameTime > 0 {
            let loopedTime = time.truncatingRemainder(dividingBy: totalFrameTime)
            var acc: Double = 0
            for (index, frame) in layer.frames.enumerated() {
                acc += frame.duration
                if loopedTime < acc {
                    layer.currentFrameIndex = index
                    return
                }
            }
        }
    }

    // MARK: - 動画レイヤーフレーム管理

    /// 動画レイヤーのフレーム更新
    private func updateVideoFrame(for layer: EditorLayer, at time: Double) {
        guard layer.isVideoLayer,
              layer.videoDuration > 0,
              layer.videoFPS > 0 else { return }

        // タイムラインの時刻を動画デュレーション内にループマッピング
        let videoTime: Double
        if time >= layer.videoDuration {
            videoTime = time.truncatingRemainder(dividingBy: layer.videoDuration)
        } else {
            videoTime = time
        }

        // フレームインデックスを計算
        let newFrameIndex = Int(videoTime * layer.videoFPS)

        // フレームが変わった場合のみWGPUエンジンにテクスチャ更新を通知
        if newFrameIndex != layer.currentFrameIndex {
            layer.currentFrameIndex = newFrameIndex
            updateWgpuVideoTexture(for: layer, at: videoTime)
        }
    }

    /// 動画フレームをRGBA化してWGPUエンジンに転送する
    private func updateWgpuVideoTexture(for layer: EditorLayer, at videoTime: Double) {
        guard let rustID = layer.rustLayerID,
              let engine = ImageEditorManager.shared.wgpuEngine,
              let extractor = layer.videoFrameExtractor else { return }

        // AVAssetImageGeneratorで該当時刻のCGImageを取得
        let generator = AVAssetImageGenerator(asset: extractor.asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.02, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.02, preferredTimescale: 600)

        let cmTime = CMTime(seconds: videoTime, preferredTimescale: 600)
        var cgImage: CGImage?
        let semaphore = DispatchSemaphore(value: 0)

        generator.generateCGImagesAsynchronously(
            forTimes: [NSValue(time: cmTime)]
        ) { _, image, _, _, _ in
            cgImage = image
            semaphore.signal()
        }
        semaphore.wait()

        guard let image = cgImage else { return }

        // CGImage → RGBA8バイト列
        let w = image.width
        let h = image.height
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
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }

        // Rust WGPUエンジンにテクスチャ更新を通知
        RustCore.wgpuUpdateLayerTexture(
            engine,
            layerId: rustID,
            width: UInt32(w),
            height: UInt32(h),
            rgbaData: data
        )
    }

    /// 動画レイヤーのデュレーションに合わせてタイムラインを更新
    func adjustDurationForVideoLayer(_ layer: EditorLayer) {
        guard layer.isVideoLayer, layer.videoDuration > 0 else { return }

        if layer.videoDuration > totalDuration {
            totalDuration = layer.videoDuration
            print("[AnimationManager] タイムラインデュレーション更新: \(String(format: "%.2f", totalDuration))秒")
        }
    }

    // MARK: - クリーンアップ

    deinit {
        displayTimer?.invalidate()
    }
}
