import Foundation

/// Phase 11A: ローカライズキーへの安全なアクセサ。
/// `Localizable.strings` に存在するキーだけを enum で公開する。
/// Why: 文字列リテラルの綴り間違いを防ぎ、`LocalizationKeysTests` で 4 言語の網羅性を検証する。
enum L10n {

    /// すべての本体ローカライズキー (テストで網羅性検証に使う)。
    /// 並びは `Resources/<lang>.lproj/Localizable.strings` のセクション順に揃える。
    static let allKeys: [String] = [
        // メニュー
        "ui.menu.library", "ui.menu.gallery", "ui.menu.collections",
        "ui.menu.schedule", "ui.menu.settings", "ui.menu.about",
        "ui.menu.quit", "ui.menu.preferences",
        // 設定
        "ui.settings.general", "ui.settings.appearance", "ui.settings.performance",
        "ui.settings.audio", "ui.settings.hardware", "ui.settings.update",
        "ui.settings.beta", "ui.settings.crashReports", "ui.settings.license",
        "ui.settings.checkNow",
        // ギャラリー
        "ui.gallery.title", "ui.gallery.featured", "ui.gallery.community",
        "ui.gallery.publish", "ui.gallery.unpublish", "ui.gallery.download",
        "ui.gallery.search", "ui.gallery.tags",
        // エディタ
        "ui.editor.layers", "ui.editor.brush", "ui.editor.mask",
        "ui.editor.effects", "ui.editor.export", "ui.editor.save",
        "ui.editor.undo", "ui.editor.redo",
        // エラー
        "ui.error.generic", "ui.error.network", "ui.error.notSignedIn",
        "ui.error.fileNotFound", "ui.error.unsupportedFormat", "ui.error.permissionDenied",
        // 確認
        "ui.confirmation.delete", "ui.confirmation.unpublish", "ui.confirmation.cancel",
        "ui.confirmation.confirm", "ui.confirmation.discardChanges",
        // ライセンス
        "ui.license.pro", "ui.license.free", "ui.license.trial",
        "ui.license.invalid", "ui.license.activate",
    ]

    /// バンドルから安全に取得するヘルパー。
    /// - Parameter key: Localizable.strings に登録済みのキー
    /// - Returns: 該当言語の翻訳文字列。見つからなければ key 自体。
    static func string(_ key: String, bundle: Bundle = .main) -> String {
        return NSLocalizedString(key, tableName: nil, bundle: bundle, value: key, comment: "")
    }

    /// 体験版残り日数フォーマット用。
    static func trialRemaining(days: Int, bundle: Bundle = .main) -> String {
        let template = string("ui.license.trial", bundle: bundle)
        return String(format: template, days)
    }
}
