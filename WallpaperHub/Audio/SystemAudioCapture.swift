import Foundation
import AVFoundation
import Combine
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

/// Phase 6A: システムオーディオキャプチャ。
/// Why: 壁紙が「いま再生されている音」に同期して動くようにする。
///      macOS 13+ なら ScreenCaptureKit (`SCStreamConfiguration.capturesAudio = true`) を使い、
///      それ未満は no-op + WARN とする (マイク権限ではなく Info.plist 上は NSAudioCaptureUsageDescription)。
public final class SystemAudioCapture: NSObject {

    /// 配信される PCM (Float32, 48kHz, mono) の塊。
    public struct PCMChunk {
        /// 1024 サンプル単位を期待。
        public let samples: [Float]
        public let sampleRate: Double
        public let timestamp: TimeInterval
    }

    /// PCM を購読するための Combine subject (1024 サンプル単位)。
    public let pcmPublisher = PassthroughSubject<PCMChunk, Never>()

    /// 1 chunk のサンプル数 (FFT 入力長と合わせる)。
    public let chunkSize: Int

    /// 出力サンプリングレート。
    public let outputSampleRate: Double

    /// 起動可能かどうか (macOS 13+)。
    public static var isSupported: Bool {
        if #available(macOS 13.0, *) { return true } else { return false }
    }

    private var pendingSamples: [Float] = []
    private let queue = DispatchQueue(label: "com.artia.audio.capture")
    private var startedAt: Date?

    #if canImport(ScreenCaptureKit)
    @available(macOS 13.0, *)
    private var stream: SCStream?
    @available(macOS 13.0, *)
    private var streamOutput: AudioStreamOutput?
    #endif

    public init(chunkSize: Int = 1024, outputSampleRate: Double = 48_000.0) {
        self.chunkSize = chunkSize
        self.outputSampleRate = outputSampleRate
        super.init()
    }

    /// キャプチャを開始する。失敗時は WARN ログを出して publish しない。
    public func start() {
        if startedAt == nil { startedAt = Date() }
        #if canImport(ScreenCaptureKit)
        if #available(macOS 13.0, *) {
            startSCStreamCapture()
            return
        }
        #endif
        NSLog("[Audio] WARN: macOS 13+ 未満のため SystemAudioCapture は no-op で起動します")
    }

    /// キャプチャを停止する。
    public func stop() {
        #if canImport(ScreenCaptureKit)
        if #available(macOS 13.0, *) {
            stopSCStreamCapture()
        }
        #endif
        queue.sync { pendingSamples.removeAll(keepingCapacity: true) }
    }

    /// テスト / 既知サンプル流し込み用。Capture が無くても 1024 サンプル単位の publish 経路を起動できる。
    public func injectSamples(_ samples: [Float], at timestamp: TimeInterval) {
        queue.sync {
            pendingSamples.append(contentsOf: samples)
            flushChunksLocked(timestamp: timestamp)
        }
    }

    /// pendingSamples を chunkSize 単位で切り出して publish する (queue 内から呼ばれる前提)。
    private func flushChunksLocked(timestamp: TimeInterval) {
        while pendingSamples.count >= chunkSize {
            let chunk = Array(pendingSamples.prefix(chunkSize))
            pendingSamples.removeFirst(chunkSize)
            let pcm = PCMChunk(samples: chunk, sampleRate: outputSampleRate, timestamp: timestamp)
            // メインスレッドを汚さないが、PassthroughSubject はスレッドセーフ。
            pcmPublisher.send(pcm)
        }
    }

    // MARK: - SCStream 経路

    #if canImport(ScreenCaptureKit)
    @available(macOS 13.0, *)
    private func startSCStreamCapture() {
        let started = startedAt ?? Date()
        let chunkSize = self.chunkSize
        let outputSampleRate = self.outputSampleRate
        let queue = self.queue
        Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    NSLog("[Audio] WARN: SCShareableContent に display が無いため audio capture を諦めます")
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.sampleRate = Int(outputSampleRate)
                config.channelCount = 1
                // 画面の方は最小サイズ + 低 fps にして CPU 消費を抑える。
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                let output = AudioStreamOutput { samples, ts in
                    queue.sync {
                        self?.pendingSamples.append(contentsOf: samples)
                        self?.flushChunksLocked(timestamp: ts.timeIntervalSince(started))
                    }
                }
                _ = chunkSize  // capture for closure (未使用警告を抑制)
                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addStreamOutput(output, type: .audio,
                                           sampleHandlerQueue: DispatchQueue(label: "com.artia.audio.sc"))
                try await stream.startCapture()
                await MainActor.run { [weak self] in
                    self?.stream = stream
                    self?.streamOutput = output
                }
            } catch {
                NSLog("[Audio] WARN: SCStream audio capture 起動失敗: %@", String(describing: error))
            }
        }
    }

    @available(macOS 13.0, *)
    private func stopSCStreamCapture() {
        guard let stream = stream else { return }
        Task { [stream] in
            try? await stream.stopCapture()
        }
        self.stream = nil
        self.streamOutput = nil
    }
    #endif
}

// MARK: - SCStreamOutput 実装

#if canImport(ScreenCaptureKit)
@available(macOS 13.0, *)
final class AudioStreamOutput: NSObject, SCStreamOutput {
    private let onSamples: (_ samples: [Float], _ time: Date) -> Void

    init(onSamples: @escaping (_ samples: [Float], _ time: Date) -> Void) {
        self.onSamples = onSamples
    }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        // CMSampleBuffer から AVAudioPCMBuffer 相当の Float32 データを取得し、mono にダウンミックスする。
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
            return
        }
        let channelCount = Int(asbd.mChannelsPerFrame)
        let frameCount = Int(CMSampleBufferGetNumSamples(sampleBuffer))
        guard channelCount > 0, frameCount > 0 else { return }

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil))
        let bufferListSize = MemoryLayout<AudioBufferList>.size

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: bufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        guard status == noErr else { return }

        // 32 bit float 想定。non-float の場合はスキップ (互換のため)。
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        guard isFloat, bytesPerFrame > 0 else { return }

        let mono = withUnsafePointer(to: &audioBufferList) { ptr -> [Float] in
            let bufferPtr = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: ptr))
            guard let firstBuffer = bufferPtr.first,
                  let raw = firstBuffer.mData else { return [] }
            let samplePtr = raw.assumingMemoryBound(to: Float.self)
            var result = [Float](repeating: 0, count: frameCount)
            for f in 0..<frameCount {
                var acc: Float = 0
                for c in 0..<channelCount {
                    acc += samplePtr[f * channelCount + c]
                }
                result[f] = acc / Float(channelCount)
            }
            return result
        }
        onSamples(mono, Date())
    }
}
#endif
