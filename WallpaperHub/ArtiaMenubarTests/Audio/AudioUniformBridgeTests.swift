import Foundation
import XCTest

@testable import WallBlank

/// Phase 6A: AudioUniformBridge / EmitterAudioBinding の検証。
/// Why: WgpuEngine の生成は環境依存 (Metal adapter) のため、可能な範囲は engine なしで検証し、
///      engine 取得できる場合に限り FFI ラウンドトリップを試す。
final class AudioUniformBridgeTests: XCTestCase {

    func test_emitterAudioBinding_codableRoundTrip_snakeCase() throws {
        let bind = EmitterAudioBinding(bandIndex: 5, scale: 12.5)
        let data = try JSONEncoder().encode(bind)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"band_index\":5"))
        XCTAssertTrue(json.contains("\"scale\":12.5"))
        let back = try JSONDecoder().decode(EmitterAudioBinding.self, from: data)
        XCTAssertEqual(back, bind)
    }

    func test_bassMidTrebleHelpers_useDistinctBandIndices() {
        XCTAssertNotEqual(EmitterAudioBinding.bass(scale: 1).bandIndex,
                          EmitterAudioBinding.mid(scale: 1).bandIndex)
        XCTAssertNotEqual(EmitterAudioBinding.mid(scale: 1).bandIndex,
                          EmitterAudioBinding.treble(scale: 1).bandIndex)
        XCTAssertLessThan(EmitterAudioBinding.bass(scale: 1).bandIndex,
                          EmitterAudioBinding.mid(scale: 1).bandIndex)
        XCTAssertLessThan(EmitterAudioBinding.mid(scale: 1).bandIndex,
                          EmitterAudioBinding.treble(scale: 1).bandIndex)
    }

    func test_update_summary_engineRoundTrip() throws {
        guard let engine = RustCore.createWgpuEngine(width: 64, height: 64) else {
            throw XCTSkip("Metal adapter 未取得のため engine round-trip をスキップ")
        }
        defer { RustCore.destroyWgpuEngine(engine) }

        // 6 バンド: bass(0,1)=1, mid(2,3)=0, treble(4,5)=1
        let bands: [Float] = [1.0, 1.0, 0.0, 0.0, 1.0, 1.0]
        AudioUniformBridge.update(engine: engine, bands: bands, time: 2.5)
        guard let summary = AudioUniformBridge.summary(engine: engine) else {
            XCTFail("summary 取得失敗"); return
        }
        XCTAssertEqual(summary.bass, 1.0, accuracy: 1e-3)
        XCTAssertEqual(summary.mid, 0.0, accuracy: 1e-3)
        XCTAssertEqual(summary.treble, 1.0, accuracy: 1e-3)
        XCTAssertEqual(summary.time, 2.5, accuracy: 1e-3)
        XCTAssertEqual(summary.activeBands, 6)
    }

    func test_update_emptyBandsResetsSummary() throws {
        guard let engine = RustCore.createWgpuEngine(width: 64, height: 64) else {
            throw XCTSkip("Metal adapter 未取得のためスキップ")
        }
        defer { RustCore.destroyWgpuEngine(engine) }

        AudioUniformBridge.update(engine: engine, bands: [0.5, 0.5, 0.5], time: 1.0)
        AudioUniformBridge.update(engine: engine, bands: [], time: 1.5)

        let summary = try XCTUnwrap(AudioUniformBridge.summary(engine: engine))
        XCTAssertEqual(summary.bass, 0, accuracy: 1e-6)
        XCTAssertEqual(summary.mid, 0, accuracy: 1e-6)
        XCTAssertEqual(summary.treble, 0, accuracy: 1e-6)
        XCTAssertEqual(summary.activeBands, 0)
        XCTAssertEqual(summary.time, 1.5, accuracy: 1e-3)
    }

    func test_unbindEmitter_failsForUnknownId() throws {
        guard let engine = RustCore.createWgpuEngine(width: 64, height: 64) else {
            throw XCTSkip("Metal adapter 未取得のためスキップ")
        }
        defer { RustCore.destroyWgpuEngine(engine) }
        XCTAssertFalse(AudioUniformBridge.unbindEmitter(engine: engine, systemId: 9999))
    }

    func test_summary_returnsNilForNullEngine() {
        XCTAssertNil(AudioUniformBridge.summary(engine: nil))
    }

    func test_update_nullEngineIsSafe() {
        // Crash しないこと
        AudioUniformBridge.update(engine: nil, bands: [0.5], time: 0)
    }
}
