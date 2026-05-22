import Foundation
import XCTest

@testable import WallBlank

/// Phase 6A: AudioFFTAnalyzer の決定論的検証。
/// Why: マイク経路は実機依存だが、PCM 入力 → バンド出力の経路は計算式で保証できるためテストを書く。
final class AudioFFTAnalyzerTests: XCTestCase {

    /// 1024 サンプル, 48kHz, ターゲット周波数 (Hz) の純音 (sin wave) を生成する。
    private func makeSineWave(frequency: Float, sampleRate: Float = 48_000.0,
                              length: Int = 1024) -> [Float] {
        let dt = 1.0 / Double(sampleRate)
        return (0..<length).map { i -> Float in
            let t = Double(i) * dt
            return Float(sin(2.0 * Double.pi * Double(frequency) * t))
        }
    }

    func test_logBandBoundaries_areMonotonicallyIncreasing() {
        let bounds = AudioFFTAnalyzer.computeLogBandBoundaries(bandCount: 64, fftLength: 1024)
        XCTAssertEqual(bounds.count, 65)
        for i in 1..<bounds.count {
            XCTAssertGreaterThan(bounds[i], bounds[i - 1],
                                 "境界 \(i) が単調増加になっていない: \(bounds)")
        }
        XCTAssertLessThanOrEqual(bounds.last ?? 0, 512)
    }

    func test_logBandBoundaries_coverFullSpectrumWithinHalfN() {
        let bounds = AudioFFTAnalyzer.computeLogBandBoundaries(bandCount: 128, fftLength: 1024)
        XCTAssertEqual(bounds.count, 129)
        XCTAssertGreaterThanOrEqual(bounds.first ?? 0, 1)
        XCTAssertLessThanOrEqual(bounds.last ?? 0, 512)
    }

    func test_silence_yieldsAllZeroBands() {
        let analyzer = AudioFFTAnalyzer(bandCount: 64)
        let silence = [Float](repeating: 0, count: 1024)
        let result = analyzer.analyze(samples: silence, time: 0)
        XCTAssertEqual(result.values.count, 64)
        for v in result.values {
            XCTAssertEqual(v, 0, accuracy: 1e-3)
        }
    }

    func test_lowFrequency_peaksInLowBand() {
        let analyzer = AudioFFTAnalyzer(bandCount: 64)
        let wave = makeSineWave(frequency: 200) // 低域
        let result = analyzer.analyze(samples: wave, time: 0)
        // 低域 (band 0..15) に最大値があること
        let peakIndex = result.values.indices.max(by: { result.values[$0] < result.values[$1] }) ?? 0
        XCTAssertLessThan(peakIndex, result.values.count / 4,
                          "200Hz は最低 1/4 領域に peak が来るはずだが \(peakIndex) になった")
    }

    func test_highFrequency_peaksInHighBand() {
        let analyzer = AudioFFTAnalyzer(bandCount: 64)
        let wave = makeSineWave(frequency: 12_000) // 高域
        let result = analyzer.analyze(samples: wave, time: 0)
        let peakIndex = result.values.indices.max(by: { result.values[$0] < result.values[$1] }) ?? 0
        XCTAssertGreaterThan(peakIndex, result.values.count / 2,
                             "12kHz は上半分に peak が来るはずだが \(peakIndex) になった")
    }

    func test_outputBands_alwaysClampedTo01() {
        let analyzer = AudioFFTAnalyzer(bandCount: 128)
        // 振幅 10 倍 (clip 想定) でも 0..1 内に収まること
        let wave = makeSineWave(frequency: 1_000).map { $0 * 10 }
        let result = analyzer.analyze(samples: wave, time: 0)
        for v in result.values {
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThanOrEqual(v, 1)
        }
    }

    func test_shortInput_isZeroPadded_withoutCrash() {
        let analyzer = AudioFFTAnalyzer(bandCount: 32)
        let r = analyzer.analyze(samples: [0.5, -0.5, 0.5, -0.5], time: 0)
        XCTAssertEqual(r.values.count, 32)
    }

    func test_audioBands_carriesTimeAndSampleRate() {
        let analyzer = AudioFFTAnalyzer(bandCount: 64, sampleRate: 44_100.0)
        let r = analyzer.analyze(samples: [Float](repeating: 0, count: 1024), time: 1.25)
        XCTAssertEqual(r.sampleRate, 44_100.0, accuracy: 1e-3)
        XCTAssertEqual(r.time, 1.25, accuracy: 1e-9)
    }
}
