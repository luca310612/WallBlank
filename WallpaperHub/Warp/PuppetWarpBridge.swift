import Foundation

// Phase 4C / 4C+: PuppetWarp Codable + Rust FFI ブリッジ。
// Why: Rust 側 `PuppetWarpDescriptor` / `PuppetWarpParams` と JSON 互換にし、
//      Swift 側で構築 → JSON 化 → C 文字列で FFI に渡す。
//      実際の draw pass 統合は後続フェーズで compositor に組み込む。
//
// ## 座標系契約 (Swift ↔ Rust 共通)
//
// - 推奨: **0..1 正規化座標**、原点 = 左上、+Y 下方向 (SwiftUI / AppKit と一致)
// - `normalized(canvasSize:)` ヘルパでクリック座標 (pixel) を正規化に統一する。
// - px そのままで渡しても数学的には正しいが、`layerSize` と単位を必ず一致させること。

/// Rust `HandleKind` と一致 (snake_case)。
enum PuppetWarpHandleKind: String, Codable, Equatable {
    case anchor
    case pin
}

/// Rust `HandleDescriptor` と一致。
struct PuppetWarpHandleDescriptor: Codable, Equatable {
    var kind: PuppetWarpHandleKind
    var source: [Float]
    var target: [Float]

    init(kind: PuppetWarpHandleKind, source: [Float], target: [Float]) {
        self.kind = kind
        self.source = source
        self.target = target
    }

    /// Anchor (固定点) を作成するヘルパ。
    static func anchor(at point: [Float]) -> Self {
        Self(kind: .anchor, source: point, target: point)
    }

    /// Pin (ドラッグ後位置を指定) を作成するヘルパ。
    static func pin(from source: [Float], to target: [Float]) -> Self {
        Self(kind: .pin, source: source, target: target)
    }
}

/// Rust `PuppetWarpDescriptor` と一致。
struct PuppetWarpDescriptor: Codable, Equatable {
    var sourceLayerId: String
    /// (cols, rows)
    var grid: [UInt32] = [16, 16]
    /// 0..1 正規化推奨 (デフォルト 1.0)。pixel で渡す場合は handle と同じ単位で。
    var layerSize: [Float] = [1.0, 1.0]
    var handles: [PuppetWarpHandleDescriptor] = []
    var idwPower: Float = 2.0
    var idwEpsilon: Float = 1e-3
    /// TPS 平滑化係数 (0.0 = 厳密補間)
    var tpsLambda: Float = 0.0
    /// pin のみで anchor 無しの場合に 4 隅 anchor を自動補完する。
    /// UI から作る場合は true 推奨 (右側 pin で左側が translate しない安全策)。
    var autoAnchorCorners: Bool = true

    enum CodingKeys: String, CodingKey {
        case sourceLayerId = "source_layer_id"
        case grid
        case layerSize = "layer_size"
        case handles
        case idwPower = "idw_power"
        case idwEpsilon = "idw_epsilon"
        case tpsLambda = "tps_lambda"
        case autoAnchorCorners = "auto_anchor_corners"
    }
}

/// Rust `PuppetWarpParams` と一致 (Optional フィールド)。
struct PuppetWarpParams: Codable, Equatable {
    var handles: [PuppetWarpHandleDescriptor]?
    var idwPower: Float?
    var idwEpsilon: Float?
    var tpsLambda: Float?
    var autoAnchorCorners: Bool?

    enum CodingKeys: String, CodingKey {
        case handles
        case idwPower = "idw_power"
        case idwEpsilon = "idw_epsilon"
        case tpsLambda = "tps_lambda"
        case autoAnchorCorners = "auto_anchor_corners"
    }
}

/// クリック位置 (pixel) を 0..1 正規化座標に変換するユーティリティ。
extension PuppetWarpHandleDescriptor {
    /// pixel 座標を canvas サイズで除算して 0..1 正規化したコピーを返す。
    /// - Parameter canvasSize: `(width, height)`。0 以下の成分は 1.0 にクランプ。
    func normalized(canvasSize: CGSize) -> PuppetWarpHandleDescriptor {
        let w = max(Float(canvasSize.width), 1.0)
        let h = max(Float(canvasSize.height), 1.0)
        return PuppetWarpHandleDescriptor(
            kind: kind,
            source: [source[0] / w, source[1] / h],
            target: [target[0] / w, target[1] / h]
        )
    }
}

/// パペットワープのストローク端で粒子バーストを起こすための差し込み点。
/// - Why: Wallpaper Engine 的な「揺らした瞬間にキラキラ」演出を後段で実装するための
///   noop デフォルトのフック。本物の Particle System は Phase 12 で実装するため
///   ここでは callback だけ用意する。
struct PuppetWarpParticleBurst {
    /// バースト位置 (normalized 0..1, 原点左上)。
    var position: [Float]
    /// 粒子数 (推奨 16〜64)。
    var count: Int

    static let `default` = PuppetWarpParticleBurst(position: [0.5, 0.5], count: 30)
}

/// PuppetWarp ストロークの開始/終了で呼び出される副作用ハンドラ。
/// - Note: 本体ロジックは副作用フリー。production はこの enum 経由で差し替える。
enum PuppetWarpEffectHooks {
    /// バースト要求。デフォルトは no-op。テスト/プレビューで `_burstHandler` を差し替えて使う。
    nonisolated(unsafe) static var _burstHandler: (@Sendable (PuppetWarpParticleBurst) -> Void)? = nil

    /// ストロークが開始したことを通知する。
    static func notifyStrokeBegan(at normalizedPosition: [Float]) {
        let burst = PuppetWarpParticleBurst(position: normalizedPosition, count: 16)
        _burstHandler?(burst)
    }

    /// ストロークが完了したことを通知する。
    static func notifyStrokeEnded(at normalizedPosition: [Float]) {
        let burst = PuppetWarpParticleBurst(position: normalizedPosition, count: 30)
        _burstHandler?(burst)
    }
}

/// Phase 4C: PuppetWarp 用 Rust FFI ラッパー。
enum PuppetWarpBridge {

    /// JSON で descriptor を渡して PuppetWarp を作成する。
    static func create(
        engine: UnsafeMutableRawPointer,
        descriptor: PuppetWarpDescriptor
    ) -> UInt32 {
        guard let json = encodeJSON(descriptor) else { return 0 }
        return json.withCString { cString in
            artia_warp_create(engine, cString)
        }
    }

    /// 既存 PuppetWarp のパラメータを部分適用する。
    static func update(
        engine: UnsafeMutableRawPointer,
        id: UInt32,
        params: PuppetWarpParams
    ) -> String? {
        guard let json = encodeJSON(params) else { return "Swift: encode params failed" }
        let result = json.withCString { cString -> UnsafeMutablePointer<CChar>? in
            artia_warp_update(engine, id, cString)
        }
        guard let ptr = result else { return nil }
        let message = String(cString: ptr)
        artia_free_string(ptr)
        return message
    }

    /// PuppetWarp を破棄する。
    @discardableResult
    static func destroy(engine: UnsafeMutableRawPointer, id: UInt32) -> Bool {
        artia_warp_destroy(engine, id) != 0
    }

    /// 現在登録されている PuppetWarp 数 (テスト/メトリクス用)。
    static func count(engine: UnsafeMutableRawPointer) -> UInt32 {
        artia_warp_count(engine)
    }

    /// Engine を介さない疎通確認: descriptor の JSON ラウンドトリップを Rust 側で実行。
    static func validateDescriptor(_ descriptor: PuppetWarpDescriptor) -> String? {
        guard let json = encodeJSON(descriptor) else { return nil }
        let resultPtr = json.withCString { cString -> UnsafeMutablePointer<CChar>? in
            artia_warp_validate_descriptor(cString)
        }
        guard let ptr = resultPtr else { return nil }
        let message = String(cString: ptr)
        artia_free_string(ptr)
        if message.contains("\"error\"") { return nil }
        return message
    }

    // MARK: - Helpers

    private static func encodeJSON<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
