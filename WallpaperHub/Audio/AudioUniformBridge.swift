import Foundation

/// Phase 6A: Audio uniform を Rust エンジンへ流すブリッジ。
/// Why: Swift 側の `AudioFFTAnalyzer` 出力 (= 0..1 正規化バンド) を
///      `artia_audio_update` で Rust の `AudioUniform` に書き込む。
public enum AudioUniformBridge {

    /// audio uniform を更新する。
    /// - Parameters:
    ///   - engine: WgpuEngine ポインタ (RustCore 経由で得るもの)。
    ///   - bands: 0..1 正規化済みのバンド配列。最大 128 件まで採用される。
    ///   - time: 経過時間 (秒, シェーダ位相用)。
    public static func update(engine: UnsafeMutableRawPointer?,
                              bands: [Float],
                              time: Float) {
        guard let engine = engine else { return }
        bands.withUnsafeBufferPointer { ptr in
            artia_audio_update(engine, ptr.baseAddress, UInt(ptr.count), time)
        }
    }

    /// audio uniform の要約 (bass / mid / treble / time / activeBands) を取得する。
    /// - Returns: 取得失敗時は nil。
    public static func summary(engine: UnsafeMutableRawPointer?) -> AudioSummary? {
        guard let engine = engine else { return nil }
        var out = [Float](repeating: 0, count: 5)
        let ok = out.withUnsafeMutableBufferPointer { ptr -> UInt32 in
            guard let base = ptr.baseAddress else { return 0 }
            return artia_audio_summary(engine, base)
        }
        guard ok == 1 else { return nil }
        return AudioSummary(bass: out[0], mid: out[1], treble: out[2],
                            time: out[3], activeBands: Int(out[4]))
    }

    /// 指定 ParticleSystem に audio binding を設定する。
    /// - Returns: 該当 ID が見つかれば true。
    @discardableResult
    public static func bindEmitter(engine: UnsafeMutableRawPointer?,
                                   systemId: UInt32,
                                   bandIndex: UInt32,
                                   scale: Float) -> Bool {
        guard let engine = engine else { return false }
        return artia_audio_bind_emitter(engine, systemId, bandIndex, scale) == 1
    }

    /// 指定 ParticleSystem の audio binding を解除する。
    @discardableResult
    public static func unbindEmitter(engine: UnsafeMutableRawPointer?,
                                     systemId: UInt32) -> Bool {
        guard let engine = engine else { return false }
        return artia_audio_unbind_emitter(engine, systemId) == 1
    }
}

/// audio_summary の Swift ラッパ。
public struct AudioSummary: Equatable {
    public let bass: Float
    public let mid: Float
    public let treble: Float
    public let time: Float
    public let activeBands: Int
}

/// パーティクル emitter に紐付ける audio binding の Codable 表現。
/// Why: Phase 4A の ParticleSystemBridge と JSON 整合性を取り、Rust 側 `EmitterAudioBinding` と一致させる。
public struct EmitterAudioBinding: Codable, Equatable {
    /// 参照する band index (0..127)。
    public var bandIndex: UInt32
    /// 振幅 → spawn rate 加算量の倍率。
    public var scale: Float

    public init(bandIndex: UInt32, scale: Float) {
        self.bandIndex = bandIndex
        self.scale = scale
    }

    /// 低域 (bass) を band 0 にバインドする想定の便利コンストラクタ。
    public static func bass(scale: Float) -> EmitterAudioBinding {
        EmitterAudioBinding(bandIndex: 4, scale: scale)
    }

    /// 中域 (mid) 想定。
    public static func mid(scale: Float) -> EmitterAudioBinding {
        EmitterAudioBinding(bandIndex: 48, scale: scale)
    }

    /// 高域 (treble) 想定。
    public static func treble(scale: Float) -> EmitterAudioBinding {
        EmitterAudioBinding(bandIndex: 110, scale: scale)
    }

    enum CodingKeys: String, CodingKey {
        case bandIndex = "band_index"
        case scale
    }
}
