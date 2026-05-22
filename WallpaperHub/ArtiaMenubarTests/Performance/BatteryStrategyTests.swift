import Foundation
import XCTest

@testable import Artia

/// Phase 7A: BatteryStrategy の Codable / 適用ロジック検証。
final class BatteryStrategyTests: XCTestCase {

    func test_codable_roundTrip_preservesAllCases() throws {
        for strategy in BatteryStrategy.allCases {
            let data = try JSONEncoder().encode(strategy)
            let back = try JSONDecoder().decode(BatteryStrategy.self, from: data)
            XCTAssertEqual(strategy, back, "BatteryStrategy.\(strategy) のラウンドトリップに失敗")
        }
    }

    func test_rawValue_isStableString() {
        XCTAssertEqual(BatteryStrategy.ignore.rawValue, "ignore")
        XCTAssertEqual(BatteryStrategy.reduceFps.rawValue, "reduceFps")
        XCTAssertEqual(BatteryStrategy.lowQuality.rawValue, "lowQuality")
        XCTAssertEqual(BatteryStrategy.pauseAll.rawValue, "pauseAll")
    }

    func test_enforcedFrameRate_only_for_reduceFps() {
        XCTAssertEqual(BatteryStrategy.reduceFps.enforcedFrameRate, 30)
        XCTAssertNil(BatteryStrategy.ignore.enforcedFrameRate)
        XCTAssertNil(BatteryStrategy.lowQuality.enforcedFrameRate)
        XCTAssertNil(BatteryStrategy.pauseAll.enforcedFrameRate)
    }

    func test_apply_lowQuality_demotesPresetByOne() {
        XCTAssertEqual(BatteryStrategy.lowQuality.apply(to: .ultra), .high)
        XCTAssertEqual(BatteryStrategy.lowQuality.apply(to: .high), .balanced)
        XCTAssertEqual(BatteryStrategy.lowQuality.apply(to: .balanced), .low)
        // low はそれ以上下がらない
        XCTAssertEqual(BatteryStrategy.lowQuality.apply(to: .low), .low)
    }

    func test_apply_otherStrategies_keepPresetAsIs() {
        for preset in [PerformancePreset.low, .balanced, .high, .ultra] {
            XCTAssertEqual(BatteryStrategy.ignore.apply(to: preset), preset)
            XCTAssertEqual(BatteryStrategy.reduceFps.apply(to: preset), preset)
            XCTAssertEqual(BatteryStrategy.pauseAll.apply(to: preset), preset)
        }
    }

    func test_shouldPauseAll_only_for_pauseAll() {
        XCTAssertTrue(BatteryStrategy.pauseAll.shouldPauseAll)
        XCTAssertFalse(BatteryStrategy.ignore.shouldPauseAll)
        XCTAssertFalse(BatteryStrategy.reduceFps.shouldPauseAll)
        XCTAssertFalse(BatteryStrategy.lowQuality.shouldPauseAll)
    }

    func test_displayName_isJapaneseAndDistinct() {
        let names = Set(BatteryStrategy.allCases.map { $0.displayName })
        XCTAssertEqual(names.count, BatteryStrategy.allCases.count, "displayName は重複してはならない")
        for s in BatteryStrategy.allCases {
            XCTAssertFalse(s.displayName.isEmpty, "displayName が空: \(s)")
        }
    }
}
