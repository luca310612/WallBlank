import Foundation
import XCTest

@testable import WallBlank

/// Phase 7B: ApplicationRulesManager の発火 / 再発火抑制 / Codable 検証。
@MainActor
final class ApplicationRulesManagerTests: XCTestCase {

    /// 各テスト間で application_rules.json を共有しないように毎回削除する。
    /// Why: addRule が persistence ファイルへ書き込むため、テスト順序により
    ///      残留ルールがロードされてアサーションが揺れる。
    override func setUp() {
        super.setUp()
        clearPersistenceFile()
    }

    override func tearDown() {
        clearPersistenceFile()
        super.tearDown()
    }

    private func clearPersistenceFile() {
        let fm = FileManager.default
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let url = appSupport.appendingPathComponent("WallBlank/application_rules.json")
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - Codable

    func test_action_codable_roundTrip_allCases() throws {
        let cases: [ApplicationRuleAction] = [
            .switchProfile(presetID: 2),
            .switchPlaylist(playlistID: "p-1"),
            .switchWallpaper(wallpaperID: "w-1"),
            .pauseWallpaper
        ]
        for action in cases {
            let data = try JSONEncoder().encode(action)
            let back = try JSONDecoder().decode(ApplicationRuleAction.self, from: data)
            XCTAssertEqual(action, back)
        }
    }

    func test_rule_codable_roundTrip() throws {
        let rule = ApplicationRule(
            name: "ゲーム時に省電力",
            bundleIDs: ["com.valvesoftware.Steam", "com.epicgames.EpicGamesLauncher"],
            action: .switchProfile(presetID: 0)
        )
        let data = try JSONEncoder().encode(rule)
        let back = try JSONDecoder().decode(ApplicationRule.self, from: data)
        XCTAssertEqual(rule, back)
    }

    // MARK: - Trigger

    func test_evaluate_firesActionWhenBundleStarts() {
        var running: Set<String> = []
        let mgr = ApplicationRulesManager(
            pollingInterval: 60,
            runningBundleIDsProvider: { running }
        )
        let rule = ApplicationRule(
            name: "Steam",
            bundleIDs: ["com.valvesoftware.Steam"],
            action: .pauseWallpaper
        )
        mgr.addRule(rule)

        var firedActions: [ApplicationRuleAction] = []
        mgr.actionHandler = { firedActions.append($0) }

        mgr.evaluate()
        XCTAssertEqual(firedActions.count, 0, "未起動時は発火しない")

        running.insert("com.valvesoftware.Steam")
        mgr.evaluate()
        XCTAssertEqual(firedActions.count, 1)
        XCTAssertEqual(firedActions.first, .pauseWallpaper)
        XCTAssertEqual(mgr.lastTriggeredRuleID, rule.id)
    }

    func test_evaluate_doesNotRefire_whileBundleStillRunning() {
        var running: Set<String> = ["com.example.App"]
        let mgr = ApplicationRulesManager(
            pollingInterval: 60,
            runningBundleIDsProvider: { running }
        )
        mgr.addRule(ApplicationRule(
            name: "Test",
            bundleIDs: ["com.example.App"],
            action: .pauseWallpaper
        ))
        var firedCount = 0
        mgr.actionHandler = { _ in firedCount += 1 }

        mgr.evaluate()
        mgr.evaluate()
        mgr.evaluate()
        XCTAssertEqual(firedCount, 1, "起動中は再発火しない")

        running.removeAll()
        mgr.evaluate()
        running.insert("com.example.App")
        mgr.evaluate()
        XCTAssertEqual(firedCount, 2, "一度終了して再起動すれば再発火する")
    }

    func test_evaluate_disabledRule_doesNotFire() {
        let running: Set<String> = ["com.example.App"]
        let mgr = ApplicationRulesManager(
            pollingInterval: 60,
            runningBundleIDsProvider: { running }
        )
        mgr.addRule(ApplicationRule(
            name: "Disabled",
            bundleIDs: ["com.example.App"],
            action: .pauseWallpaper,
            isEnabled: false
        ))
        var fired = 0
        mgr.actionHandler = { _ in fired += 1 }
        mgr.evaluate()
        XCTAssertEqual(fired, 0)
    }

    func test_addUpdateRemove_persistInMemoryList() {
        let mgr = ApplicationRulesManager(
            pollingInterval: 60,
            runningBundleIDsProvider: { [] }
        )
        var rule = ApplicationRule(
            name: "Original",
            bundleIDs: ["a"],
            action: .pauseWallpaper
        )
        mgr.addRule(rule)
        XCTAssertEqual(mgr.rules.count, 1)

        rule.name = "Renamed"
        mgr.updateRule(rule)
        XCTAssertEqual(mgr.rules.first?.name, "Renamed")

        mgr.removeRule(id: rule.id)
        XCTAssertTrue(mgr.rules.isEmpty)
    }

    func test_evaluate_multipleRules_eachFireIndependently() {
        let running: Set<String> = ["com.app.A", "com.app.B"]
        let mgr = ApplicationRulesManager(
            pollingInterval: 60,
            runningBundleIDsProvider: { running }
        )
        let r1 = ApplicationRule(name: "A", bundleIDs: ["com.app.A"], action: .switchWallpaper(wallpaperID: "w-1"))
        let r2 = ApplicationRule(name: "B", bundleIDs: ["com.app.B"], action: .switchPlaylist(playlistID: "p-1"))
        mgr.addRule(r1)
        mgr.addRule(r2)

        var fired: [ApplicationRuleAction] = []
        mgr.actionHandler = { fired.append($0) }
        mgr.evaluate()
        XCTAssertEqual(fired.count, 2)
        XCTAssertTrue(fired.contains(.switchWallpaper(wallpaperID: "w-1")))
        XCTAssertTrue(fired.contains(.switchPlaylist(playlistID: "p-1")))
    }
}
