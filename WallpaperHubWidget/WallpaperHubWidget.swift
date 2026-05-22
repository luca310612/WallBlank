import Foundation
import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Timeline Entry

struct WallpaperEntry: TimelineEntry {
    let date: Date
    let wallpaperName: String
    let wallpaperThumbnailPath: String?
    let wallpaperType: String
    let favorites: [WidgetWallpaperInfo]
    let isScheduleActive: Bool
    let nextRotationDate: Date?
    let scheduleName: String?
}

// MARK: - Timeline Provider

struct WallpaperTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> WallpaperEntry {
        WallpaperEntry(
            date: Date(),
            wallpaperName: "Artia",
            wallpaperThumbnailPath: nil,
            wallpaperType: "image",
            favorites: [],
            isScheduleActive: false,
            nextRotationDate: nil,
            scheduleName: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (WallpaperEntry) -> Void) {
        let entry = createEntry()
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WallpaperEntry>) -> Void) {
        let entry = createEntry()

        // 次の更新タイミング
        let nextUpdate: Date
        if let nextRotation = WidgetDataProvider.nextRotationDate,
           WidgetDataProvider.isScheduleActive {
            // スケジュールアクティブ時は次のローテーション時に更新
            nextUpdate = nextRotation
        } else {
            // 通常は15分後に更新
            nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        }

        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    private func createEntry() -> WallpaperEntry {
        WallpaperEntry(
            date: Date(),
            wallpaperName: WidgetDataProvider.currentWallpaperName,
            wallpaperThumbnailPath: WidgetDataProvider.currentWallpaperThumbnailPath,
            wallpaperType: WidgetDataProvider.currentWallpaperType,
            favorites: Array(WidgetDataProvider.favoriteWallpapers.prefix(6)),
            isScheduleActive: WidgetDataProvider.isScheduleActive,
            nextRotationDate: WidgetDataProvider.nextRotationDate,
            scheduleName: WidgetDataProvider.scheduleName
        )
    }
}

// MARK: - App Intents

/// 次の壁紙に切り替え
struct NextWallpaperIntent: AppIntent {
    static var title: LocalizedStringResource = "次の壁紙"
    static var description: IntentDescription = "スケジュールの次の壁紙に切り替えます"

    func perform() async throws -> some IntentResult {
        // メインアプリに通知を送信
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.artia.widget.nextWallpaper"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        return .result()
    }
}

/// 特定の壁紙に切り替え
struct SetWallpaperIntent: AppIntent {
    static var title: LocalizedStringResource = "壁紙を設定"
    static var description: IntentDescription = "指定した壁紙に切り替えます"

    @Parameter(title: "壁紙ID")
    var wallpaperID: String

    func perform() async throws -> some IntentResult {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.artia.widget.setWallpaper"),
            object: nil,
            userInfo: ["wallpaperID": wallpaperID],
            deliverImmediately: true
        )
        return .result()
    }
}

/// スケジュール切り替え
struct ToggleScheduleIntent: AppIntent {
    static var title: LocalizedStringResource = "スケジュール切替"
    static var description: IntentDescription = "壁紙ローテーションのオン/オフを切り替えます"

    func perform() async throws -> some IntentResult {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.artia.widget.toggleSchedule"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        return .result()
    }
}

// MARK: - Widget

@main
struct ArtiaWidgetBundle: WidgetBundle {
    var body: some Widget {
        ArtiaWidget()
    }
}

struct ArtiaWidget: Widget {
    let kind: String = "ArtiaWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WallpaperTimelineProvider()) { entry in
            WallpaperWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Artia")
        .description("現在の壁紙やお気に入りを表示します")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
