import Foundation

// MARK: - ブラシプリセット
// Why: EditorToolSettings(現在の作業状態)とは別に「ユーザーが切り替える保存ブラシ」を
// 表現するモデル。組み込み(`isBuiltIn = true`)とユーザー作成を区別する。

/// 保存可能なブラシプリセット 1 件
struct BrushPreset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var iconSystemName: String       // SF Symbol 名
    var stroke: EditorBrushStrokeSettings
    var maskPost: EditorMaskPostSettings
    var gradient: EditorMaskGradientSettings
    /// 組み込み（編集・削除不可）
    var isBuiltIn: Bool
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        iconSystemName: String = "paintbrush.pointed",
        stroke: EditorBrushStrokeSettings = .init(),
        maskPost: EditorMaskPostSettings = .init(),
        gradient: EditorMaskGradientSettings = .init(),
        isBuiltIn: Bool = false,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.iconSystemName = iconSystemName
        self.stroke = stroke
        self.maskPost = maskPost
        self.gradient = gradient
        self.isBuiltIn = isBuiltIn
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - 適用 / 取り込み

    /// 現在のツール設定にプリセットを流し込む
    func apply(to settings: inout EditorToolSettings) {
        settings.stroke = stroke
        settings.maskPost = maskPost
        settings.gradient = gradient
    }

    /// 現在のツール設定からプリセットを生成（保存用）
    static func capture(from settings: EditorToolSettings, name: String, icon: String = "paintbrush.pointed") -> BrushPreset {
        BrushPreset(
            name: name,
            iconSystemName: icon,
            stroke: settings.stroke,
            maskPost: settings.maskPost,
            gradient: settings.gradient,
            isBuiltIn: false
        )
    }

    /// このプリセットの内容と現在のツール設定が一致しているか
    func matches(_ settings: EditorToolSettings) -> Bool {
        stroke == settings.stroke
            && maskPost == settings.maskPost
            && gradient == settings.gradient
    }
}
