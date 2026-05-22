import XCTest
import Foundation

@testable import Artia

/// Phase 9B: WidgetDataProvider の round-trip と Codable 検証。
final class WidgetDataProviderTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // 専用 suiteName で隔離 (App Group を実際に触らない)
        let suite = "test.widget.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        WidgetDataProvider.overrideDefaults = defaults
        WidgetDataProvider.resetForTesting()
    }

    override func tearDown() {
        WidgetDataProvider.resetForTesting()
        WidgetDataProvider.overrideDefaults = nil
        defaults = nil
        super.tearDown()
    }

    // MARK: - Codable

    func test_widgetWallpaperInfo_codable_roundTrip() throws {
        let info = WidgetWallpaperInfo(
            id: "wp-1",
            name: "夕焼け",
            thumbnailPath: "/tmp/sunset.jpg",
            type: "image"
        )
        let data = try JSONEncoder().encode(info)
        let back = try JSONDecoder().decode(WidgetWallpaperInfo.self, from: data)
        XCTAssertEqual(info, back)
    }

    // MARK: - 現在の壁紙

    func test_updateCurrentWallpaper_persistsAndReads() {
        WidgetDataProvider.updateCurrentWallpaper(
            name: "海",
            thumbnailPath: "/tmp/ocean.png",
            type: "video"
        )
        XCTAssertEqual(WidgetDataProvider.currentWallpaperName, "海")
        XCTAssertEqual(WidgetDataProvider.currentWallpaperThumbnailPath, "/tmp/ocean.png")
        XCTAssertEqual(WidgetDataProvider.currentWallpaperType, "video")
    }

    func test_updateCurrentWallpaper_nilThumbnail_clearsPriorValue() {
        WidgetDataProvider.updateCurrentWallpaper(name: "A", thumbnailPath: "/x", type: "image")
        WidgetDataProvider.updateCurrentWallpaper(name: "B", thumbnailPath: nil, type: "image")
        XCTAssertNil(WidgetDataProvider.currentWallpaperThumbnailPath)
    }

    // MARK: - お気に入り

    func test_updateFavorites_persistsArray() {
        let favs = [
            WidgetWallpaperInfo(id: "1", name: "α", thumbnailPath: nil, type: "image"),
            WidgetWallpaperInfo(id: "2", name: "β", thumbnailPath: "/tmp/b.png", type: "video"),
        ]
        WidgetDataProvider.updateFavorites(favs)
        let back = WidgetDataProvider.favoriteWallpapers
        XCTAssertEqual(back, favs)
    }

    func test_favorites_emptyByDefault() {
        XCTAssertTrue(WidgetDataProvider.favoriteWallpapers.isEmpty)
    }

    // MARK: - スケジュール

    func test_updateScheduleState_roundTripsAllFields() {
        let now = Date(timeIntervalSince1970: 1_730_000_000)
        WidgetDataProvider.updateScheduleState(
            isActive: true,
            nextRotation: now,
            scheduleName: "朝のローテーション"
        )
        XCTAssertTrue(WidgetDataProvider.isScheduleActive)
        XCTAssertEqual(WidgetDataProvider.nextRotationDate?.timeIntervalSince1970, now.timeIntervalSince1970)
        XCTAssertEqual(WidgetDataProvider.scheduleName, "朝のローテーション")
    }

    func test_updateScheduleState_nilDateClearsValue() {
        WidgetDataProvider.updateScheduleState(isActive: false, nextRotation: nil, scheduleName: nil)
        XCTAssertFalse(WidgetDataProvider.isScheduleActive)
        XCTAssertNil(WidgetDataProvider.nextRotationDate)
        XCTAssertNil(WidgetDataProvider.scheduleName)
    }

    // MARK: - reset

    func test_resetForTesting_removesAllKeys() {
        WidgetDataProvider.updateCurrentWallpaper(name: "x", thumbnailPath: "/y", type: "image")
        WidgetDataProvider.updateFavorites([
            WidgetWallpaperInfo(id: "1", name: "a", thumbnailPath: nil, type: "image")
        ])
        WidgetDataProvider.updateScheduleState(isActive: true, nextRotation: Date(), scheduleName: "s")
        WidgetDataProvider.resetForTesting()
        XCTAssertEqual(WidgetDataProvider.currentWallpaperName, "壁紙未設定")
        XCTAssertNil(WidgetDataProvider.currentWallpaperThumbnailPath)
        XCTAssertEqual(WidgetDataProvider.currentWallpaperType, "image")
        XCTAssertTrue(WidgetDataProvider.favoriteWallpapers.isEmpty)
        XCTAssertFalse(WidgetDataProvider.isScheduleActive)
        XCTAssertNil(WidgetDataProvider.nextRotationDate)
        XCTAssertNil(WidgetDataProvider.scheduleName)
    }
}
