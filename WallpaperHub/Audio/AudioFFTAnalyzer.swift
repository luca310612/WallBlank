import Foundation
import Accelerate

/// Phase 6A: FFT 周波数解析。
/// Why: PCM (Float32) → 対数バンディング (Mel scale 風) → 0..1 正規化バンドへ落とし込み、
///      シェーダ / particle 連動に使える「音量の形」を得る。
public struct AudioBands: Equatable {
    public let values: [Float]
    public let sampleRate: Float
    public let time: TimeInterval

    public init(values: [Float], sampleRate: Float, time: TimeInterval) {
        self.values = values
        self.sampleRate = sampleRate
        self.time = time
    }
}

/// vDSP_DFT を使った FFT アナライザ。
/// - 入力: PCM Float32 (任意長, 内部で window length にパディング/ハニング適用)
/// - 出力: 64 / 128 etc. のバンド数で集約した 0..1 正規化スペクトル
public final class AudioFFTAnalyzer {

    /// バンド数 (64 or 128 を想定; 任意の偶数を受け付ける)。
    public let bandCount: Int

    /// FFT 長 (= window length)。2^n が必要。デフォルト 1024。
    public let fftLength: Int

    /// サンプリングレート (Hz)。
    public let sampleRate: Float

    /// 強度を dB に直すときの最小値 (これ以下を 0 として扱う閾値)。
    public let dbFloor: Float

    /// 強度を dB に直すときの最大値 (これを上限として 1.0 にクランプ)。
    public let dbCeiling: Float

    private let dftSetup: vDSP.DiscreteFourierTransform<Float>
    /// ハニング窓 (fftLength)。
    private let window: [Float]
    /// ログ周波数バンドのビン境界 (bandCount + 1 個の bin index)。
    private let bandBoundaries: [Int]

    public init(bandCount: Int = 128,
                fftLength: Int = 1024,
                sampleRate: Float = 48_000.0,
                dbFloor: Float = -80.0,
                dbCeiling: Float = -10.0) {
        precondition(fftLength.nonzeroBitCount == 1, "FFT 長は 2^n である必要があります")
        precondition(bandCount > 0, "bandCount は 1 以上")
        self.bandCount = bandCount
        self.fftLength = fftLength
        self.sampleRate = sampleRate
        self.dbFloor = dbFloor
        self.dbCeiling = dbCeiling

        // forward / complex DFT (実数入力, 複素数出力)。Accelerate 標準パターン。
        // Why: macOS 13.0+ で vDSP.DFT は deprecated。後継の vDSP.DiscreteFourierTransform は throws。
        do {
            self.dftSetup = try vDSP.DiscreteFourierTransform(
                count: fftLength,
                direction: .forward,
                transformType: .complexComplex,
                ofType: Float.self)
        } catch {
            fatalError("vDSP.DiscreteFourierTransform 初期化失敗 (length=\(fftLength)): \(error)")
        }

        // ハニング窓
        var w = [Float](repeating: 0, count: fftLength)
        vDSP_hann_window(&w, vDSP_Length(fftLength), Int32(vDSP_HANN_NORM))
        self.window = w

        self.bandBoundaries = AudioFFTAnalyzer.computeLogBandBoundaries(
            bandCount: bandCount, fftLength: fftLength)
    }

    /// 1 ブロックぶんの PCM を解析してバンド配列に変換する。
    /// - Parameters:
    ///   - samples: PCM Float32 (任意長, 不足ぶんはゼロパディング, 過剰ぶんは末尾切り捨て)
    ///   - time: 解析時刻 (秒)
    public func analyze(samples: [Float], time: TimeInterval) -> AudioBands {
        var input = [Float](repeating: 0, count: fftLength)
        let copyCount = min(samples.count, fftLength)
        if copyCount > 0 {
            input.replaceSubrange(0..<copyCount, with: samples[0..<copyCount])
        }
        // ハニング窓
        vDSP.multiply(input, window, result: &input)

        // DFT は real / imag を分けた配列を要求する。imaginary 入力は 0。
        let imagIn = [Float](repeating: 0, count: fftLength)
        var realOut = [Float](repeating: 0, count: fftLength)
        var imagOut = [Float](repeating: 0, count: fftLength)
        dftSetup.transform(inputReal: input, inputImaginary: imagIn,
                           outputReal: &realOut, outputImaginary: &imagOut)

        // パワースペクトル (片側 = N/2)。
        let halfN = fftLength / 2
        var power = [Float](repeating: 0, count: halfN)
        for i in 0..<halfN {
            let r = realOut[i]
            let im = imagOut[i]
            power[i] = r * r + im * im
        }

        // バンド集約: bandBoundaries[i]..bandBoundaries[i+1] の平均パワーを採用。
        var bands = [Float](repeating: 0, count: bandCount)
        for i in 0..<bandCount {
            let lo = bandBoundaries[i]
            let hi = max(bandBoundaries[i + 1], lo + 1)
            var sum: Float = 0
            for k in lo..<hi {
                sum += power[k]
            }
            let count = Float(hi - lo)
            let avgPower = sum / max(count, 1)
            // dB スケール (1e-12 で log0 ガード)
            let db = 10.0 * log10f(max(avgPower, 1e-12))
            // 0..1 正規化
            let normalized = (db - dbFloor) / (dbCeiling - dbFloor)
            bands[i] = max(0, min(1, normalized))
        }

        return AudioBands(values: bands, sampleRate: sampleRate, time: time)
    }

    /// バンド境界 (片側スペクトル `0..fftLength/2` を bandCount 個の対数等分割) を計算する。
    /// Why: 人間の聴覚は対数的なので、0..N/2 を等分すると低域が潰れて高域が膨らむ。
    static func computeLogBandBoundaries(bandCount: Int, fftLength: Int) -> [Int] {
        let halfN = fftLength / 2
        let lowBin = 1 // DC (0) は除外。
        let highBin = halfN
        let logLow = logf(Float(lowBin))
        let logHigh = logf(Float(highBin))
        var out = [Int](repeating: 0, count: bandCount + 1)
        for i in 0...bandCount {
            let t = Float(i) / Float(bandCount)
            let logBin = logLow + t * (logHigh - logLow)
            let bin = Int(roundf(expf(logBin)))
            out[i] = max(lowBin, min(highBin, bin))
        }
        // 同じビンが連続すると幅 0 になるので最低 1 ビンは確保する。
        for i in 1..<out.count {
            if out[i] <= out[i - 1] {
                out[i] = min(highBin, out[i - 1] + 1)
            }
        }
        return out
    }
}
