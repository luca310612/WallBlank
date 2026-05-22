import Foundation

// MARK: - PenToolKind ↔ BrushEngineID マッピング
// Why: 既存の PenToolKind enum（UI 上の選択肢）と新しい BrushEngine 抽象を
// 1ヶ所でつなぐ。enum を残したまま、利用側は brushEngineID 経由で
// Strategy 実装を取得できるようにする。
//
// パス系（standard / curvature / polygonal / pathSelect 等）は
// BrushEngine ではなくベクター編集経路に流すため、nil を返す。

extension PenToolKind {
    /// 対応する BrushEngine ID（パス系は nil）
    var brushEngineID: BrushEngineID? {
        switch self {
        case .freeform, .magneticPen:
            return .circle
        case .standard, .curvature, .polygonal,
             .pathSelect, .directSelect,
             .addAnchor, .deleteAnchor, .convertPoint:
            return nil
        }
    }
}
