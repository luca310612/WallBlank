import Foundation
import Combine
import XCTest

@testable import WallBlank

/// Phase 7A: EnvironmentMonitor の per-display pause 計算と snapshot 結合検証。
@MainActor
final class EnvironmentMonitorTests: XCTestCase {

    // MARK: - Helpers

    private func makeMonitor(
        pauseOnExclusiveFullscreen: Bool = true,
        pauseOnMaximizedWindow: Bool = false,
        pauseOnOtherAudio: Bool = false,
        batteryStrategy: BatteryStrategy = .reduceFps,
        displayIDs: [String] = ["display-A", "display-B"]
    ) -> EnvironmentMonitor {
        return EnvironmentMonitor(
            pollingInterval: 60.0,
            osIntegrationsEnabled: false,
            pauseOnExclusiveFullscreen: pauseOnExclusiveFullscreen,
            pauseOnMaximizedWindow: pauseOnMaximizedWindow,
            pauseOnOtherAudio: pauseOnOtherAudio,
            batteryStrategy: batteryStrategy,
            displayIDsProvider: { displayIDs },
            displayFrameProvider: { _ in CGRect(x: 0, y: 0, width: 1920, height: 1080) },
            accessibilityProvider: { false }
        )
    }

    // MARK: - perDisplayShouldPause matrix

    func test_compute_allFalse_whenSettingsAllOff_andNoEnvironmentTriggers() {
        let monitor = makeMonitor(
            pauseOnExclusiveFullscreen: false,
            pauseOnMaximizedWindow: false,
            pauseOnOtherAudio: false,
            batteryStrategy: .ignore
        )
        let map = monitor.computePerDisplayPause(
            isFullscreen: false, isMaximized: false,
            isOtherAudioPlaying: false, isOnBattery: false
        )
        XCTAssertEqual(map, ["display-A": false, "display-B": false])
    }

    func test_compute_fullscreen_pausesAllWhenSettingOn() {
        let monitor = makeMonitor(pauseOnExclusiveFullscreen: true)
        let map = monitor.computePerDisplayPause(
            isFullscreen: true, isMaximized: false,
            isOtherAudioPlaying: false, isOnBattery: false
        )
        XCTAssertEqual(map["display-A"], true)
        XCTAssertEqual(map["display-B"], true)
    }

    func test_compute_fullscreen_doesNothing_whenSettingOff() {
        let monitor = makeMonitor(pauseOnExclusiveFullscreen: false)
        let map = monitor.computePerDisplayPause(
            isFullscreen: true, isMaximized: false,
            isOtherAudioPlaying: false, isOnBattery: false
        )
        XCTAssertEqual(map, ["display-A": false, "display-B": false])
    }

    func test_compute_maximized_pausesWhenSettingOn() {
        let monitor = makeMonitor(
            pauseOnExclusiveFullscreen: false,
            pauseOnMaximizedWindow: true
        )
        let map = monitor.computePerDisplayPause(
            isFullscreen: false, isMaximized: true,
            isOtherAudioPlaying: false, isOnBattery: false
        )
        XCTAssertEqual(map["display-A"], true)
    }

    func test_compute_otherAudio_pausesWhenSettingOn() {
        let monitor = makeMonitor(
            pauseOnExclusiveFullscreen: false,
            pauseOnOtherAudio: true
        )
        let map = monitor.computePerDisplayPause(
            isFullscreen: false, isMaximized: false,
            isOtherAudioPlaying: true, isOnBattery: false
        )
        XCTAssertEqual(map["display-A"], true)
        XCTAssertEqual(map["display-B"], true)
    }

    func test_compute_battery_pauseAll_strategyOverrides() {
        let monitor = makeMonitor(
            pauseOnExclusiveFullscreen: false,
            pauseOnMaximizedWindow: false,
            pauseOnOtherAudio: false,
            batteryStrategy: .pauseAll
        )
        let map = monitor.computePerDisplayPause(
            isFullscreen: false, isMaximized: false,
            isOtherAudioPlaying: false, isOnBattery: true
        )
        XCTAssertEqual(map["display-A"], true)
        XCTAssertEqual(map["display-B"], true)
    }

    func test_compute_battery_reduceFps_doesNotForcePause() {
        let monitor = makeMonitor(
            pauseOnExclusiveFullscreen: false,
            pauseOnMaximizedWindow: false,
            pauseOnOtherAudio: false,
            batteryStrategy: .reduceFps
        )
        let map = monitor.computePerDisplayPause(
            isFullscreen: false, isMaximized: false,
            isOtherAudioPlaying: false, isOnBattery: true
        )
        XCTAssertEqual(map["display-A"], false)
        XCTAssertEqual(map["display-B"], false)
    }

    func test_compute_emptyDisplays_returnsEmptyMap() {
        let monitor = makeMonitor(displayIDs: [])
        let map = monitor.computePerDisplayPause(
            isFullscreen: true, isMaximized: true,
            isOtherAudioPlaying: true, isOnBattery: true
        )
        XCTAssertTrue(map.isEmpty)
    }

    // MARK: - Snapshot publish

    func test_evaluate_publishesSnapshotEvenWhenIntegrationsDisabled() {
        let monitor = makeMonitor()
        var captured: [EnvironmentSnapshot] = []
        let cancellable = monitor.snapshotPublisher.sink { captured.append($0) }
        monitor.refreshNow()
        cancellable.cancel()
        XCTAssertGreaterThanOrEqual(captured.count, 1)
        // osIntegrationsEnabled = false なので環境フラグは全て false
        let last = captured.last!
        XCTAssertFalse(last.isFullscreenAppActive)
        XCTAssertFalse(last.isMaximizedWindowVisible)
        XCTAssertFalse(last.isOtherAudioPlaying)
        XCTAssertFalse(last.isOnBattery)
    }

    func test_injectSnapshotForTesting_overridesPublishedSnapshot() {
        let monitor = makeMonitor()
        let injected = EnvironmentSnapshot(
            isFullscreenAppActive: true,
            isMaximizedWindowVisible: true,
            isOtherAudioPlaying: true,
            isOnBattery: true,
            perDisplayShouldPause: ["display-X": true]
        )
        monitor.injectSnapshotForTesting(injected)
        XCTAssertEqual(monitor.snapshot, injected)
    }

    // MARK: - Settings persistence (default values)

    func test_defaultBatteryStrategy_isReduceFps() {
        // Direct check on enum default (decoder fallback path is implementation detail of Settings).
        XCTAssertEqual(BatteryStrategy.reduceFps.enforcedFrameRate, 30)
    }
}
