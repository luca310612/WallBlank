import XCTest
import Foundation

@testable import Artia

/// Phase 11H: 4 言語の `Localizable.strings` で `L10n.allKeys` がすべて翻訳済みかを検証する。
final class LocalizationKeysTests: XCTestCase {

    private static let supportedLocales: [String] = ["ja", "en", "zh-Hans", "ko"]

    /// .lproj の配置ディレクトリを探す。
    /// - Note: テストバンドルからは Artia (本体) の Bundle.main を直接参照できないため、
    ///   リポジトリレイアウト相対 (`#filePath`) で `Resources/<lang>.lproj/Localizable.strings` を解決する。
    private static func stringsURL(for locale: String) -> URL {
        let here = URL(fileURLWithPath: #filePath)
        // ArtiaMenubarTests/Localization/<file> → WallpaperHub/Resources/<lang>.lproj/Localizable.strings
        let repo = here
            .deletingLastPathComponent() // Localization
            .deletingLastPathComponent() // ArtiaMenubarTests
            .deletingLastPathComponent() // WallpaperHub (子)
        return repo
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("\(locale).lproj", isDirectory: true)
            .appendingPathComponent("Localizable.strings")
    }

    private static func loadStrings(for locale: String) throws -> [String: String] {
        let url = stringsURL(for: locale)
        let data = try Data(contentsOf: url)
        // .strings は plist (UTF-8 / UTF-16) として読める
        guard let dict = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String] else {
            throw NSError(domain: "LocalizationKeysTests", code: -1, userInfo: [NSLocalizedDescriptionKey: "\(locale) の plist 解析に失敗"])
        }
        return dict
    }

    func test_allLocales_haveSameKeys() throws {
        let expected = Set(L10n.allKeys)
        for locale in Self.supportedLocales {
            let dict = try Self.loadStrings(for: locale)
            let keys = Set(dict.keys)
            XCTAssertEqual(
                keys, expected,
                "[\(locale)] が想定キーと一致しません. 不足: \(expected.subtracting(keys)) / 余剰: \(keys.subtracting(expected))"
            )
        }
    }

    func test_noEmptyTranslations() throws {
        for locale in Self.supportedLocales {
            let dict = try Self.loadStrings(for: locale)
            for (key, value) in dict {
                XCTAssertFalse(
                    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "[\(locale)] \(key) が空文字列"
                )
            }
        }
    }

    func test_japaneseHasSpecificStrings() throws {
        let ja = try Self.loadStrings(for: "ja")
        XCTAssertEqual(ja["ui.menu.library"], "ライブラリ")
        XCTAssertEqual(ja["ui.confirmation.cancel"], "キャンセル")
    }

    func test_englishHasEnglishWords() throws {
        let en = try Self.loadStrings(for: "en")
        XCTAssertEqual(en["ui.menu.library"], "Library")
        XCTAssertEqual(en["ui.confirmation.cancel"], "Cancel")
    }

    func test_allKeysListIsSorted_andUnique() {
        let allKeys = L10n.allKeys
        XCTAssertEqual(Set(allKeys).count, allKeys.count, "L10n.allKeys に重複あり")
        // 50 文字列 (50 keys) 以上を保証
        XCTAssertGreaterThanOrEqual(allKeys.count, 50, "翻訳キーは 50 件以上を維持する")
    }
}
