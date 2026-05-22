import Foundation

// Phase 4B: Light レイヤー Codable + Rust FFI ブリッジ。
// Why: Rust 側 `LightLayerDescriptor` / `LightLayerParams` と JSON 互換にし、
//      Swift 側で構築 → JSON → C 文字列で FFI に渡す。
//      実際の draw pass は後続フェーズで compositor に統合する。

/// Rust `LightLayerDescriptor` と一致する Codable 構造体。
struct LightLayerDescriptor: Codable, Equatable {
    /// canvas pixel
    var position: [Float] = [0, 0]
    /// linear sRGB + alpha (alpha は合成用)
    var color: [Float] = [1, 1, 1, 1]
    /// 振幅倍率 (1.0 = base color と等価)
    var intensity: Float = 1.0
    /// 1/e 距離減衰 (px)
    var falloff: Float = 256.0
}

/// Rust `LightLayerParams` (Optional フィールドのみ) と一致。
struct LightLayerParams: Codable, Equatable {
    var position: [Float]?
    var color: [Float]?
    var intensity: Float?
    var falloff: Float?
}

/// Phase 4B: Light レイヤー用 Rust FFI ラッパー。
enum LightLayerBridge {

    /// JSON で descriptor を渡して Light レイヤーを作成する。
    /// - Returns: 0 でない `LightLayerId.0` (1 以上) / 失敗時 0。
    static func create(
        engine: UnsafeMutableRawPointer,
        descriptor: LightLayerDescriptor
    ) -> UInt32 {
        guard let json = encodeJSON(descriptor) else { return 0 }
        return json.withCString { cString in
            artia_light_create(engine, cString)
        }
    }

    /// 既存 Light レイヤーへパラメータを部分適用する。
    /// - Returns: 成功時 nil / 失敗時 Rust 側エラーメッセージ。
    static func update(
        engine: UnsafeMutableRawPointer,
        id: UInt32,
        params: LightLayerParams
    ) -> String? {
        guard let json = encodeJSON(params) else { return "Swift: encode params failed" }
        let result = json.withCString { cString -> UnsafeMutablePointer<CChar>? in
            artia_light_update(engine, id, cString)
        }
        guard let ptr = result else { return nil }
        let message = String(cString: ptr)
        artia_free_string(ptr)
        return message
    }

    /// Light レイヤーを破棄する。
    @discardableResult
    static func destroy(engine: UnsafeMutableRawPointer, id: UInt32) -> Bool {
        artia_light_destroy(engine, id) != 0
    }

    /// 現在登録されている Light レイヤー数 (テスト/メトリクス用)。
    static func count(engine: UnsafeMutableRawPointer) -> UInt32 {
        artia_light_count(engine)
    }

    // MARK: - Helpers

    private static func encodeJSON<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
