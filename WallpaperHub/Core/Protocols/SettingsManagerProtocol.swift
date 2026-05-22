import Foundation

/// 設定管理のプロトコル
/// テスト時にモックを注入できるようにするための抽象化
protocol SettingsManagerProtocol: AnyObject {
    // MARK: - Shader
    var currentShader: Int { get set }

    // MARK: - Effect Intensity
    var effectIntensity: Float { get set }

    // MARK: - Background Image
    var backgroundImagePath: String? { get set }

    // MARK: - Display-Specific Background Images
    var displayBackgroundPaths: [String: String] { get set }
    func backgroundImagePath(for displayID: String) -> String?
    func setBackgroundImagePath(_ path: String?, for displayID: String)
    func clearAllDisplayBackgroundPaths()

    // MARK: - Pause State
    var isPaused: Bool { get set }

    // MARK: - Multi-Display Settings
    var enabledDisplayIDs: [String] { get set }
    var displayArrangement: [String: DisplayLayoutConfiguration] { get set }
    var spanWallpaperAcrossDisplays: Bool { get set }
    func removeDisplay(_ displayID: String)

    // MARK: - Performance Settings
    var pauseWhenOtherAppActive: Bool { get set }
    var pauseWhenFullscreen: Bool { get set }
    var pauseOnBattery: Bool { get set }
    var pauseOnHighGPU: Bool { get set }
    var gpuThreshold: Float { get set }

    // MARK: - Performance Preset
    var performancePreset: PerformancePreset { get set }
    var performanceFrameRate: Int { get set }
    var performanceResolutionScale: Float { get set }

    // MARK: - Video Volume
    var videoVolume: Float { get set }

    // MARK: - Web Wallpaper
    var webWallpaperScale: Float { get set }
    var desktopItemsClickable: Bool { get set }
    func isWebWallpaperDisplaySyncEnabled(for rootURL: URL) -> Bool
    func setWebWallpaperDisplaySyncEnabled(_ enabled: Bool, for rootURL: URL)

    // MARK: - Effect Configuration
    var effectConfiguration: EffectConfiguration? { get set }

    // MARK: - Editor (Phase 1.4+ Feature Flag)
    /// ブラシマスクラスタライズを GPU 経路で実行するか (実験的)
    var useGPUBrush: Bool { get set }

    // MARK: - Phase 7A: Performance Auto-Control
    /// EnvironmentMonitor 連動のフラグ群。既存 pauseWhen* と並存する。
    var pauseOnExclusiveFullscreen: Bool { get set }
    var pauseOnMaximizedWindow: Bool { get set }
    var pauseOnOtherAudio: Bool { get set }
    var batteryStrategy: BatteryStrategy { get set }

    // MARK: - Phase 7B: スパニング壁紙
    /// 単一壁紙を全ディスプレイにまたがって描画するか (default: false)
    var spanningEnabled: Bool { get set }

    // MARK: - Phase 8: Hardware Integration
    /// Razer Chroma 連動 (default: false)
    var razerChromaEnabled: Bool { get set }
    /// Corsair iCUE 連動 (default: false; macOS では効かない)
    var corsairCueEnabled: Bool { get set }
    /// LED Boost 強度 0..1 (default: 0.3)
    var ledBoostIntensity: Float { get set }

    // MARK: - Notifications
    func startObserving(handler: @escaping (Notification.Name, [AnyHashable: Any]?) -> Void)
}
