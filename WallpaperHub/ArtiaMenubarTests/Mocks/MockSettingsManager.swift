import Foundation
@testable import WallBlank

/// SettingsManagerProtocol の Mock 実装。
/// Why: テスト時に WallpaperEngine などへ注入し、書き込み履歴を spy として検証できるようにする。
final class MockSettingsManager: SettingsManagerProtocol {
    // MARK: - Spy

    /// 書き込まれたキーと値のシーケンス（最新が末尾）
    private(set) var writes: [(key: String, value: Any)] = []
    /// startObserving が呼ばれた回数
    private(set) var startObservingCallCount: Int = 0
    /// 直近の startObserving に渡されたハンドラ（テストから手動発火するため保持）
    private(set) var lastObserverHandler: ((Notification.Name, [AnyHashable: Any]?) -> Void)?

    // MARK: - Stored Properties

    var currentShader: Int = 0 { didSet { writes.append(("currentShader", currentShader)) } }
    var effectIntensity: Float = 0 { didSet { writes.append(("effectIntensity", effectIntensity)) } }
    var backgroundImagePath: String? = nil { didSet { writes.append(("backgroundImagePath", backgroundImagePath as Any)) } }
    var displayBackgroundPaths: [String: String] = [:] { didSet { writes.append(("displayBackgroundPaths", displayBackgroundPaths)) } }
    var isPaused: Bool = false { didSet { writes.append(("isPaused", isPaused)) } }
    var enabledDisplayIDs: [String] = [] { didSet { writes.append(("enabledDisplayIDs", enabledDisplayIDs)) } }
    var displayArrangement: [String: DisplayLayoutConfiguration] = [:] { didSet { writes.append(("displayArrangement", displayArrangement)) } }
    var spanWallpaperAcrossDisplays: Bool = false { didSet { writes.append(("spanWallpaperAcrossDisplays", spanWallpaperAcrossDisplays)) } }
    var pauseWhenOtherAppActive: Bool = false { didSet { writes.append(("pauseWhenOtherAppActive", pauseWhenOtherAppActive)) } }
    var pauseWhenFullscreen: Bool = false { didSet { writes.append(("pauseWhenFullscreen", pauseWhenFullscreen)) } }
    var pauseOnBattery: Bool = false { didSet { writes.append(("pauseOnBattery", pauseOnBattery)) } }
    var pauseOnHighGPU: Bool = false { didSet { writes.append(("pauseOnHighGPU", pauseOnHighGPU)) } }
    var gpuThreshold: Float = 0 { didSet { writes.append(("gpuThreshold", gpuThreshold)) } }
    var performancePreset: PerformancePreset = .balanced { didSet { writes.append(("performancePreset", performancePreset.rawValue)) } }
    var performanceFrameRate: Int = 60 { didSet { writes.append(("performanceFrameRate", performanceFrameRate)) } }
    var performanceResolutionScale: Float = 1.0 { didSet { writes.append(("performanceResolutionScale", performanceResolutionScale)) } }
    var videoVolume: Float = 1.0 { didSet { writes.append(("videoVolume", videoVolume)) } }
    var webWallpaperScale: Float = 1.0 { didSet { writes.append(("webWallpaperScale", webWallpaperScale)) } }
    var desktopItemsClickable: Bool = false { didSet { writes.append(("desktopItemsClickable", desktopItemsClickable)) } }
    var effectConfiguration: EffectConfiguration? = nil { didSet { writes.append(("effectConfiguration", effectConfiguration as Any)) } }
    var useGPUBrush: Bool = false { didSet { writes.append(("useGPUBrush", useGPUBrush)) } }

    // Phase 7A: パフォーマンス自動制御 (検知系)
    var pauseOnExclusiveFullscreen: Bool = true { didSet { writes.append(("pauseOnExclusiveFullscreen", pauseOnExclusiveFullscreen)) } }
    var pauseOnMaximizedWindow: Bool = false { didSet { writes.append(("pauseOnMaximizedWindow", pauseOnMaximizedWindow)) } }
    var pauseOnOtherAudio: Bool = false { didSet { writes.append(("pauseOnOtherAudio", pauseOnOtherAudio)) } }
    var batteryStrategy: BatteryStrategy = .reduceFps { didSet { writes.append(("batteryStrategy", batteryStrategy.rawValue)) } }

    // Phase 7B: スパニング壁紙
    var spanningEnabled: Bool = false { didSet { writes.append(("spanningEnabled", spanningEnabled)) } }

    // Phase 8: ハードウェア連携
    var razerChromaEnabled: Bool = false { didSet { writes.append(("razerChromaEnabled", razerChromaEnabled)) } }
    var corsairCueEnabled: Bool = false { didSet { writes.append(("corsairCueEnabled", corsairCueEnabled)) } }
    var ledBoostIntensity: Float = 0.3 { didSet { writes.append(("ledBoostIntensity", ledBoostIntensity)) } }

    private var displaySyncFlags: [String: Bool] = [:]

    // MARK: - Methods

    func backgroundImagePath(for displayID: String) -> String? {
        displayBackgroundPaths[displayID]
    }

    func setBackgroundImagePath(_ path: String?, for displayID: String) {
        if let path = path {
            displayBackgroundPaths[displayID] = path
        } else {
            displayBackgroundPaths.removeValue(forKey: displayID)
        }
    }

    func clearAllDisplayBackgroundPaths() {
        displayBackgroundPaths.removeAll()
    }

    func removeDisplay(_ displayID: String) {
        enabledDisplayIDs.removeAll { $0 == displayID }
        displayArrangement.removeValue(forKey: displayID)
        displayBackgroundPaths.removeValue(forKey: displayID)
    }

    func isWebWallpaperDisplaySyncEnabled(for rootURL: URL) -> Bool {
        displaySyncFlags[rootURL.path] ?? false
    }

    func setWebWallpaperDisplaySyncEnabled(_ enabled: Bool, for rootURL: URL) {
        displaySyncFlags[rootURL.path] = enabled
    }

    func startObserving(handler: @escaping (Notification.Name, [AnyHashable: Any]?) -> Void) {
        startObservingCallCount += 1
        lastObserverHandler = handler
    }

    /// テストヘルパ: 保持中の observer を任意の通知で発火させる
    func fireObserver(name: Notification.Name, userInfo: [AnyHashable: Any]? = nil) {
        lastObserverHandler?(name, userInfo)
    }

    /// テストヘルパ: 書き込みログをリセット
    func resetSpy() {
        writes.removeAll()
    }
}
