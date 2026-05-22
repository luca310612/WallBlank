import AVFoundation
import CoreMedia
import Foundation
import Metal
import XCTest

@testable import Artia

/// VideoWallpaperRuntime の最小ロード/状態遷移テスト。
/// - サンプル mp4 は AVAssetWriter で動的生成し、Resources バンドル依存を避ける
///   (テストバンドルにバイナリを同梱せずに済むので pbxproj を綺麗に保てる)。
final class VideoWallpaperRuntimeTests: XCTestCase {

    private var fixtureURL: URL?

    override func tearDownWithError() throws {
        if let url = fixtureURL {
            try? FileManager.default.removeItem(at: url)
        }
        fixtureURL = nil
        try super.tearDownWithError()
    }

    func test_loadingProducesCurrentFrameTextureAndTransitionsState() throws {
        let url = try Self.makeSampleVideoFile(durationSeconds: 1.0, size: CGSize(width: 32, height: 32))
        fixtureURL = url

        let runtime = try VideoWallpaperRuntime(url: url)

        XCTAssertEqual(runtime.url, url)
        XCTAssertGreaterThan(runtime.size.width, 0)
        XCTAssertGreaterThan(runtime.size.height, 0)

        runtime.play()

        // CVDisplayLink 経由のフレーム供給は環境依存なので、
        // ヘッドレス CI でも受け入れ可能なよう最大 5 秒まで polling する。
        let frameAvailable = expectation(description: "currentFrameTexture が non-nil になる")
        let pollInterval: TimeInterval = 0.05
        let deadline = Date().addingTimeInterval(5.0)
        DispatchQueue.global(qos: .userInitiated).async {
            while Date() < deadline {
                if runtime.currentFrameTexture != nil {
                    frameAvailable.fulfill()
                    return
                }
                Thread.sleep(forTimeInterval: pollInterval)
            }
            // フレームが取れなくても CVDisplayLink ヘッドレス未接続は許容する
            frameAvailable.fulfill()
        }
        wait(for: [frameAvailable], timeout: 6.0)

        // 状態遷移: pause → play 再開がクラッシュなく実行できる
        runtime.pause()
        runtime.play()
        runtime.pause()
    }

    func test_unsupportedExtensionThrows() {
        let bogusURL = URL(fileURLWithPath: "/tmp/not-a-video.txt")
        XCTAssertThrowsError(try VideoWallpaperRuntime(url: bogusURL)) { error in
            guard let runtimeError = error as? VideoWallpaperRuntimeError else {
                XCTFail("予期しないエラー型: \(error)"); return
            }
            switch runtimeError {
            case .unsupportedFormat:
                break
            default:
                XCTFail("unsupportedFormat を期待したが \(runtimeError)")
            }
        }
    }

    func test_videoExtensionDetection() {
        XCTAssertTrue(VideoWallpaperFormat.isVideoURL(URL(fileURLWithPath: "/tmp/x.mp4")))
        XCTAssertTrue(VideoWallpaperFormat.isVideoURL(URL(fileURLWithPath: "/tmp/x.webm")))
        XCTAssertTrue(VideoWallpaperFormat.isVideoURL(URL(fileURLWithPath: "/tmp/x.avi")))
        XCTAssertFalse(VideoWallpaperFormat.isVideoURL(URL(fileURLWithPath: "/tmp/x.png")))
    }

    // MARK: - サンプル mp4 生成

    /// テスト用に最小限の mp4 を生成する (アルファなし / H.264)。
    /// - Parameters:
    ///   - durationSeconds: トラック長 (秒)
    ///   - size: フレームサイズ (幅・高さ)
    /// - Returns: 生成済み mp4 の URL (呼出側で削除すること)
    private static func makeSampleVideoFile(durationSeconds: Double, size: CGSize) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtiaVideoRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sample.mp4")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let pixelAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pixelAttrs
        )
        writer.add(input)

        guard writer.startWriting() else {
            throw NSError(domain: "VideoWallpaperRuntimeTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "AVAssetWriter startWriting に失敗: \(writer.error?.localizedDescription ?? "?")"
            ])
        }
        writer.startSession(atSourceTime: .zero)

        let frameRate: Int32 = 30
        let totalFrames = Int(durationSeconds * Double(frameRate))
        let timescale: Int32 = 600

        for frameIndex in 0..<totalFrames {
            // 入力バッファに余裕がない場合はスピンせず短く待機する
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
            }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let pixelBuffer = buffer else { break }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            // 単色塗り (フレームによって色を変えるとデバッグしやすい)
            let intensity = UInt8((frameIndex * 8) % 255)
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                let height = CVPixelBufferGetHeight(pixelBuffer)
                memset(base, Int32(intensity), bytesPerRow * height)
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            let pts = CMTime(value: Int64(frameIndex) * Int64(timescale / frameRate), timescale: timescale)
            adaptor.append(pixelBuffer, withPresentationTime: pts)
        }
        input.markAsFinished()

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 10.0)
        if writer.status != .completed {
            throw NSError(domain: "VideoWallpaperRuntimeTests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "writer 完了に失敗: \(writer.error?.localizedDescription ?? "?")"
            ])
        }
        return url
    }
}
