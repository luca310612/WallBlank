import Foundation
import AppKit

/// Phase 11B: アクセシビリティ設定の検出と効果反映ヘルパー。
///
/// 目的:
///   - VoiceOver: 画像/ボタンに `accessibilityLabel` / `accessibilityHint` を統一付与する API
///   - Reduce Motion: ユーザがシステム設定で動きを減らしている場合の効果スケーリング
///   - High Contrast: NSAppearance の `.accessibilityHighContrast` バリアント検知
///
/// 既存 UI を破壊的に書き換えるのではなく、必要箇所で参照できる pure helper として提供する。
enum AccessibilityHelpers {

    /// システム環境で「視差効果を減らす」が有効か。
    /// Why: パララックスや揺れエフェクトの強度を 0 にする判定に使う。
    static var reduceMotion: Bool {
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// 「透明度を減らす」が有効か (背景ブラーを切り替える用途)。
    static var reduceTransparency: Bool {
        return NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    /// 「コントラストを上げる」が有効か。
    static var increaseContrast: Bool {
        return NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// 現在 NSApp が High Contrast 系 NSAppearance になっているか。
    /// SwiftUI 内では colorSchemeContrast 経由が望ましいが、AppKit 側用の補助。
    static var isHighContrastAppearance: Bool {
        let names: [NSAppearance.Name] = [
            .accessibilityHighContrastAqua,
            .accessibilityHighContrastDarkAqua,
            .accessibilityHighContrastVibrantLight,
            .accessibilityHighContrastVibrantDark,
        ]
        let current = NSApp?.effectiveAppearance.bestMatch(from: names)
        return current != nil
    }

    /// パララックス強度を Reduce Motion を尊重してスケールする。
    /// - Parameter intensity: 0.0〜1.0 の元強度
    /// - Returns: Reduce Motion が ON なら 0、それ以外は intensity をそのまま返す
    static func motionScaledIntensity(_ intensity: Double) -> Double {
        return reduceMotion ? 0.0 : intensity
    }

    /// VoiceOver / その他の支援技術が有効なときのみ操作を行うラッパー。
    static func ifAssistiveTechnologyEnabled(_ block: () -> Void) {
        if NSWorkspace.shared.isVoiceOverEnabled {
            block()
        }
    }

    /// `NSImage` ラッパービュー (NSImageView) に統一フォーマットの label / hint を付ける。
    /// - Parameters:
    ///   - view: 対象 NSImageView (壁紙サムネイル等)
    ///   - label: VoiceOver が読み上げる短い名前
    ///   - hint: 操作のヒント (任意)
    static func decorate(_ view: NSAccessibilityElement, label: String, hint: String? = nil) {
        view.setAccessibilityLabel(label)
        if let hint { view.setAccessibilityHelp(hint) }
    }

    /// 高コントラスト時に枠線を強調するための NSColor を返す。
    /// - Parameter base: 通常時の枠線色
    static func contrastedBorder(base: NSColor) -> NSColor {
        if increaseContrast || isHighContrastAppearance {
            // テキスト色相当のシステム前景色で強調する
            return NSColor.labelColor
        }
        return base
    }
}

#if canImport(SwiftUI)
import SwiftUI

extension View {
    /// SwiftUI ビューに統一フォーマットの VoiceOver ラベル/ヒントを付ける。
    /// - Parameters:
    ///   - label: スクリーンリーダーが読み上げる短い名前
    ///   - hint: 操作のヒント
    /// - Note: NSAccessibilityElement とインタフェースを揃える狙い。
    func artiaAccessibility(
        label: String,
        hint: String? = nil
    ) -> some View {
        let view = self.accessibilityLabel(Text(label))
        if let hint {
            return AnyView(view.accessibilityHint(Text(hint)))
        }
        return AnyView(view)
    }
}
#endif
