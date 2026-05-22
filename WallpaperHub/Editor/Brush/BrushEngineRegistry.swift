import Foundation

// MARK: - ブラシエンジンレジストリ
// Why: 全 BrushEngine 実装を ID で引ける1ヶ所に集約。新エンジン追加は
// `register(_:)` 1 行で済むようにし、利用側の switch 文を不要にする。

/// ブラシエンジンの中央レジストリ
final class BrushEngineRegistry {
    static let shared = BrushEngineRegistry()

    private var engines: [BrushEngineID: BrushEngine] = [:]

    private init() {
        bootstrap()
    }

    /// 起動時に組み込みエンジンを登録
    private func bootstrap() {
        register(CircleBrushEngine())
        register(EraserBrushEngine())
        register(AirBrushEngine())
        register(TextureBrushEngine())
        register(SmudgeBrushEngine())
    }

    /// エンジンを登録
    func register(_ engine: BrushEngine) {
        engines[engine.id] = engine
    }

    /// ID からエンジンを取得（未登録時は nil）
    func engine(for id: BrushEngineID) -> BrushEngine? {
        engines[id]
    }

    /// ID からエンジンを取得（未登録時は CircleBrush にフォールバック）
    func engineOrFallback(for id: BrushEngineID) -> BrushEngine {
        engines[id] ?? engines[.circle] ?? CircleBrushEngine()
    }

    /// 全エンジン一覧（UI 用）
    var allEngines: [BrushEngine] {
        BrushEngineID.allCases.compactMap { engines[$0] }
    }
}
