import Foundation
import AppKit

/// ウィジェットとメインアプリ間のデータ共有
/// App Group "group.com.artia.shared" を使用
struct WidgetDataProvider {
    static let appGroupID = "group.com.artia.shared"

    /// テストから差し込み可能な UserDefaults。default は App Group。
    /// Why: WidgetDataProviderTests が個別 suiteName で隔離して回るため。
    nonisolated(unsafe) static var overrideDefaults: UserDefaults?

    /// 共有UserDefaults
    static var sharedDefaults: UserDefaults? {
        if let overrideDefaults { return overrideDefaults }
        return UserDefaults(suiteName: appGroupID)
    }

    // MARK: - Keys

    private enum Keys {
        static let currentWallpaperName = "widget_currentWallpaperName"
        static let currentWallpaperThumbnailPath = "widget_currentWallpaperThumbnailPath"
        static let currentWallpaperType = "widget_currentWallpaperType"
        static let favoriteWallpapers = "widget_favoriteWallpapers"
        static let isScheduleActive = "widget_isScheduleActive"
        static let nextRotationDate = "widget_nextRotationDate"
        static let scheduleName = "widget_scheduleName"
    }

    // MARK: - Current Wallpaper

    /// 現在の壁紙名を取得
    static var currentWallpaperName: String {
        sharedDefaults?.string(forKey: Keys.currentWallpaperName) ?? "壁紙未設定"
    }

    /// 現在の壁紙サムネイルパスを取得
    static var currentWallpaperThumbnailPath: String? {
        sharedDefaults?.string(forKey: Keys.currentWallpaperThumbnailPath)
    }

    /// 現在の壁紙タイプ
    static var currentWallpaperType: String {
        sharedDefaults?.string(forKey: Keys.currentWallpaperType) ?? "image"
    }

    /// 現在の壁紙サムネイル画像を取得
    static var currentWallpaperThumbnail: NSImage? {
        guard let path = currentWallpaperThumbnailPath else { return nil }
        return NSImage(contentsOfFile: path)
    }

    // MARK: - Favorites

    /// お気に入り壁紙リスト（ウィジェット用の軽量版）
    static var favoriteWallpapers: [WidgetWallpaperInfo] {
        guard let data = sharedDefaults?.data(forKey: Keys.favoriteWallpapers),
              let items = try? JSONDecoder().decode([WidgetWallpaperInfo].self, from: data) else {
            return []
        }
        return items
    }

    // MARK: - Schedule

    /// スケジュールがアクティブか
    static var isScheduleActive: Bool {
        sharedDefaults?.bool(forKey: Keys.isScheduleActive) ?? false
    }

    /// 次のローテーション日時
    static var nextRotationDate: Date? {
        sharedDefaults?.object(forKey: Keys.nextRotationDate) as? Date
    }

    /// アクティブスケジュール名
    static var scheduleName: String? {
        sharedDefaults?.string(forKey: Keys.scheduleName)
    }

    // MARK: - Write (メインアプリ側で使用)

    /// 現在の壁紙情報を更新
    static func updateCurrentWallpaper(name: String, thumbnailPath: String?, type: String) {
        sharedDefaults?.set(name, forKey: Keys.currentWallpaperName)
        sharedDefaults?.set(thumbnailPath, forKey: Keys.currentWallpaperThumbnailPath)
        sharedDefaults?.set(type, forKey: Keys.currentWallpaperType)
    }

    /// お気に入りリストを更新
    static func updateFavorites(_ favorites: [WidgetWallpaperInfo]) {
        do {
            let data = try JSONEncoder().encode(favorites)
            sharedDefaults?.set(data, forKey: Keys.favoriteWallpapers)
        } catch {
            print("[WidgetDataProvider] Failed to encode favorites: \(error)")
        }
    }

    /// スケジュール状態を更新
    static func updateScheduleState(isActive: Bool, nextRotation: Date?, scheduleName: String?) {
        sharedDefaults?.set(isActive, forKey: Keys.isScheduleActive)
        sharedDefaults?.set(nextRotation, forKey: Keys.nextRotationDate)
        sharedDefaults?.set(scheduleName, forKey: Keys.scheduleName)
    }

    // MARK: - テスト補助

    /// テスト間でクリーンスレートにするため全キー削除
    static func resetForTesting() {
        guard let d = sharedDefaults else { return }
        d.removeObject(forKey: Keys.currentWallpaperName)
        d.removeObject(forKey: Keys.currentWallpaperThumbnailPath)
        d.removeObject(forKey: Keys.currentWallpaperType)
        d.removeObject(forKey: Keys.favoriteWallpapers)
        d.removeObject(forKey: Keys.isScheduleActive)
        d.removeObject(forKey: Keys.nextRotationDate)
        d.removeObject(forKey: Keys.scheduleName)
    }
}

/// ウィジェット用の軽量壁紙情報
struct WidgetWallpaperInfo: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let thumbnailPath: String?
    let type: String

    /// サムネイル画像を取得
    var thumbnail: NSImage? {
        guard let path = thumbnailPath else { return nil }
        return NSImage(contentsOfFile: path)
    }
}
