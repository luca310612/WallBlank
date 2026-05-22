import Foundation
import AppKit
import CoreFoundation

/// パフォーマンスプリセット
enum PerformancePreset: Int, CaseIterable {
    case low = 0       // 低負荷
    case balanced = 1  // バランス
    case high = 2      // 高品質
    case ultra = 3     // 最高品質

    var displayName: String {
        switch self {
        case .low: return "省電力"
        case .balanced: return "バランス"
        case .high: return "高品質"
        case .ultra: return "最高品質"
        }
    }

    var description: String {
        switch self {
        case .low: return "バッテリー駆動やGPU負荷を最小限に抑えたい時に"
        case .balanced: return "日常使用に最適な設定"
        case .high: return "滑らかなアニメーションを楽しみたい時に"
        case .ultra: return "最高の視覚体験（120FPS・最高品質シェーダー）"
        }
    }

    var icon: String {
        switch self {
        case .low: return "leaf"
        case .balanced: return "scale.3d"
        case .high: return "hare"
        case .ultra: return "sparkles"
        }
    }

    /// フレームレート
    var frameRate: Int {
        switch self {
        case .low: return 15
        case .balanced: return 30
        case .high: return 60
        case .ultra: return 120
        }
    }

    /// 解像度スケール (1.0 = フル解像度)
    var resolutionScale: Float {
        switch self {
        case .low: return 0.75
        case .balanced: return 1.0
        case .high: return 1.0
        case .ultra: return 1.0
        }
    }

    /// ノイズシェーダーのFBMオクターブ数
    var octaveCount: Int {
        switch self {
        case .low: return 2
        case .balanced: return 3
        case .high: return 4
        case .ultra: return 5
        }
    }
}

/// アプリ間で共有する設定キー
struct SharedSettingsKeys {
    static let suiteName = "group.com.artia.shared"

    static let currentShader = "currentShader"
    static let effectIntensity = "effectIntensity"
    static let backgroundImagePath = "backgroundImagePath"
    static let isPaused = "isPaused"

    // マルチディスプレイ設定
    static let enabledDisplayIDs = "enabledDisplayIDs"
    static let displayArrangement = "displayArrangement"
    static let spanWallpaperAcrossDisplays = "spanWallpaperAcrossDisplays"
    // ディスプレイごとの壁紙パス (Dictionary<DisplayID, Path>)
    static let displayBackgroundPaths = "displayBackgroundPaths"

    // パフォーマンス設定
    static let pauseWhenOtherAppActive = "pauseWhenOtherAppActive"
    static let pauseWhenFullscreen = "pauseWhenFullscreen"
    static let pauseOnBattery = "pauseOnBattery"
    static let pauseOnHighGPU = "pauseOnHighGPU"
    static let gpuThreshold = "gpuThreshold"

    // パフォーマンスプリセット
    static let performancePreset = "performancePreset"
    static let performanceFrameRate = "performanceFrameRate"
    static let performanceResolutionScale = "performanceResolutionScale"

    // 音量設定
    static let videoVolume = "videoVolume"
    static let webWallpaperScale = "webWallpaperScale"
    static let desktopItemsClickable = "desktopItemsClickable"
    static let webWallpaperDisplaySyncByRoot = "webWallpaperDisplaySyncByRoot"

    // エフェクト設定
    static let effectConfiguration = "effectConfiguration"

    // Phase 1.4+: ブラシマスクラスタライズの GPU 経路 (実験的)
    static let useGPUBrush = "useGPUBrush"

    // Phase 4B: パララックス強度 (0.0 = 無効, 1.0 = 強)
    static let parallaxStrength = "parallaxStrength"

    // Phase 6B: エフェクトチェイン DSL ("plasma -> bloom(0.4) -> vignette(0.8)")。
    // Why: 空文字なら旧 EffectManager 経路、非空文字なら EffectRegistry 経路を使う。
    static let effectChain = "effectChain"

    // Phase 7A: パフォーマンス自動制御 (検知系)
    // Why: 既存 PerformanceMonitor の pauseWhen* と並存させるため別キー。
    //      EnvironmentMonitor が観測し、per-display で再生/停止を切り替える。
    static let pauseOnExclusiveFullscreen = "pauseOnExclusiveFullscreen"
    static let pauseOnMaximizedWindow     = "pauseOnMaximizedWindow"
    static let pauseOnOtherAudio          = "pauseOnOtherAudio"
    static let batteryStrategy            = "batteryStrategy"

    // Phase 7B: スパニング壁紙
    // Why: ON のとき複数ディスプレイをまたぐ 1 枚の仮想キャンバスで描画する。
    //      OFF (デフォルト) は既存の各ディスプレイ独立挙動。
    static let spanningEnabled            = "spanningEnabled"

    // Phase 8: ハードウェア連携
    // Why: Razer Chroma / Corsair iCUE / LED Boost の有効化と強度。
    //      iCUE は macOS 非対応のため Toggle はあるが ON にしても no-op。
    static let razerChromaEnabled         = "razerChromaEnabled"
    static let corsairCueEnabled          = "corsairCueEnabled"
    static let ledBoostIntensity          = "ledBoostIntensity"
}

/// Distributed Notification名
struct WallpaperNotifications {
    static let settingsChanged = Notification.Name("com.artia.settingsChanged")
    static let shaderChanged = Notification.Name("com.artia.shaderChanged")
    static let backgroundImageChanged = Notification.Name("com.artia.backgroundImageChanged")
    static let intensityChanged = Notification.Name("com.artia.intensityChanged")
    static let pauseStateChanged = Notification.Name("com.artia.pauseStateChanged")
    static let engineStatusRequest = Notification.Name("com.artia.engineStatusRequest")
    static let engineStatusResponse = Notification.Name("com.artia.engineStatusResponse")

    // マルチディスプレイ・パフォーマンス関連
    static let displaysChanged = Notification.Name("com.artia.displaysChanged")
    static let displayRemoved = Notification.Name("com.artia.displayRemoved")
    static let performanceSettingsChanged = Notification.Name("com.artia.performanceSettingsChanged")
    static let performancePresetChanged = Notification.Name("com.artia.performancePresetChanged")
    static let performanceTuningChanged = Notification.Name("com.artia.performanceTuningChanged")
    // 特定ディスプレイの壁紙変更
    static let displayBackgroundImageChanged = Notification.Name("com.artia.displayBackgroundImageChanged")
    static let displayArrangementChanged = Notification.Name("com.artia.displayArrangementChanged")
    static let spanWallpaperAcrossDisplaysChanged = Notification.Name("com.artia.spanWallpaperAcrossDisplaysChanged")

    // 音量関連
    static let videoVolumeChanged = Notification.Name("com.artia.videoVolumeChanged")
    static let webWallpaperScaleChanged = Notification.Name("com.artia.webWallpaperScaleChanged")
    static let desktopItemsClickableChanged = Notification.Name("com.artia.desktopItemsClickableChanged")
    static let webWallpaperDisplaySyncChanged = Notification.Name("com.artia.webWallpaperDisplaySyncChanged")

    // エフェクト関連
    static let effectConfigurationChanged = Notification.Name("com.artia.effectConfigurationChanged")
}

/// 共有設定マネージャー
class SharedSettingsManager: SettingsManagerProtocol {
    static let shared = SharedSettingsManager()

    /// 旧実装で残る可能性がある壁紙スケール系キー
    private static let legacyWallpaperScaleKeys: [String] = [
        "backgroundImageScale",
        "backgroundImageZoom",
        "wallpaperScale",
        "wallpaperZoom",
        "imageScale",
        "imageZoom",
        "videoScale",
        "videoZoom",
        "displayBackgroundScales",
        "displayBackgroundZooms",
        "perWallpaperScale",
        "perWallpaperZoom",
        "wallpaperContentMode"
    ]

    private let repository: SettingsRepositoryProtocol
    private let eventBus: EventBus
    /// DistributedNotificationCenterのオブザーバートークン（リーク防止用）
    private var distributedObservers: [NSObjectProtocol] = []

    // DI対応: デフォルト引数でシングルトンを使用しつつ、テスト時はモックを注入可能
    init(
        repository: SettingsRepositoryProtocol = UserDefaultsSettingsRepository(suiteName: SharedSettingsKeys.suiteName),
        eventBus: EventBus = EventBus.shared
    ) {
        self.repository = repository
        self.eventBus = eventBus

        migrateLegacyWallpaperScaleSettings()

        // デフォルト値を登録
        repository.register(defaults: [
            SharedSettingsKeys.pauseOnHighGPU: true,
            SharedSettingsKeys.gpuThreshold: 80.0,
            SharedSettingsKeys.performanceFrameRate: PerformancePreset.balanced.frameRate,
            SharedSettingsKeys.performanceResolutionScale: PerformancePreset.balanced.resolutionScale,
            SharedSettingsKeys.webWallpaperScale: 1.0,
            SharedSettingsKeys.desktopItemsClickable: false,
            SharedSettingsKeys.spanWallpaperAcrossDisplays: false
        ])
    }

    private func migrateLegacyWallpaperScaleSettings() {
        var stores: [UserDefaults] = [UserDefaults.standard]
        if let groupDefaults = UserDefaults(suiteName: SharedSettingsKeys.suiteName) {
            stores.append(groupDefaults)
        }

        for defaults in stores {
            for key in Self.legacyWallpaperScaleKeys where defaults.object(forKey: key) != nil {
                defaults.removeObject(forKey: key)
                debugLog("[Settings] Removed legacy wallpaper scale key: \(key)")
            }
        }

        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        CFPreferencesAppSynchronize(SharedSettingsKeys.suiteName as CFString)
    }

    // MARK: - Shader

    var currentShader: Int {
        get { repository.integer(forKey: SharedSettingsKeys.currentShader) }
        set {
            repository.set(newValue, forKey: SharedSettingsKeys.currentShader)
            dispatch(.shaderChanged(shader: newValue), ipc: WallpaperNotifications.shaderChanged, userInfo: ["shader": newValue])
        }
    }

    // MARK: - Effect Intensity

    var effectIntensity: Float {
        get { Float(repository.double(forKey: SharedSettingsKeys.effectIntensity)) }
        set {
            repository.set(Double(newValue), forKey: SharedSettingsKeys.effectIntensity)
            dispatch(.intensityChanged(intensity: newValue), ipc: WallpaperNotifications.intensityChanged, userInfo: ["intensity": newValue])
        }
    }

    // MARK: - Background Image

    var backgroundImagePath: String? {
        get {
            let path = repository.string(forKey: SharedSettingsKeys.backgroundImagePath)
            // URLエンコードされている場合はデコード
            let decodedPath = path?.removingPercentEncoding ?? path
            debugLog("[Settings] Reading global background path: \(decodedPath ?? "none")")
            return decodedPath
        }
        set {
            debugLog("[Settings] Saving global background path: \(newValue ?? "none")")
            repository.set(newValue, forKey: SharedSettingsKeys.backgroundImagePath)
            dispatch(.backgroundImageChanged(path: newValue ?? "", displayID: nil), ipc: WallpaperNotifications.backgroundImageChanged, userInfo: ["path": newValue ?? ""])
        }
    }

    // MARK: - Display-Specific Background Images

    /// ディスプレイごとの壁紙パスを取得
    var displayBackgroundPaths: [String: String] {
        get {
            guard let data = repository.data(forKey: SharedSettingsKeys.displayBackgroundPaths),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
                debugLog("[Settings] No display-specific background paths found")
                return [:]
            }
            // URLエンコードされている場合はデコード
            let decodedDict = dict.mapValues { $0.removingPercentEncoding ?? $0 }
            debugLog("[Settings] Reading display background paths: \(decodedDict)")
            return decodedDict
        }
        set {
            debugLog("[Settings] Saving display background paths: \(newValue)")
            do {
                let data = try JSONEncoder().encode(newValue)
                repository.set(data, forKey: SharedSettingsKeys.displayBackgroundPaths)
                flushSharedDefaultsForIPC()
            } catch {
                debugLog("[Settings] Failed to encode display background paths: \(error)")
            }
        }
    }

    /// 特定のディスプレイの壁紙パスを取得
    func backgroundImagePath(for displayID: String) -> String? {
        return displayBackgroundPaths[displayID]
    }

    /// 特定のディスプレイの壁紙パスを設定
    func setBackgroundImagePath(_ path: String?, for displayID: String) {
        debugLog("[Settings] Setting background path for display \(displayID): \(path ?? "none")")
        var paths = displayBackgroundPaths
        if let path = path, !path.isEmpty {
            paths[displayID] = path
        } else {
            paths.removeValue(forKey: displayID)
        }
        displayBackgroundPaths = paths

        dispatch(.backgroundImageChanged(path: path ?? "", displayID: displayID), ipc: WallpaperNotifications.displayBackgroundImageChanged, userInfo: [
            "path": path ?? "",
            "displayID": displayID
        ])
    }

    /// 全ディスプレイの壁紙をクリア
    func clearAllDisplayBackgroundPaths() {
        displayBackgroundPaths = [:]
        backgroundImagePath = nil
    }

    // MARK: - Pause State

    var isPaused: Bool {
        get { repository.bool(forKey: SharedSettingsKeys.isPaused) }
        set {
            repository.set(newValue, forKey: SharedSettingsKeys.isPaused)
            dispatch(.pauseStateChanged(paused: newValue), ipc: WallpaperNotifications.pauseStateChanged, userInfo: ["paused": newValue])
        }
    }

    // MARK: - Multi-Display Settings

    var enabledDisplayIDs: [String] {
        get { repository.stringArray(forKey: SharedSettingsKeys.enabledDisplayIDs) ?? [] }
        set {
            repository.set(newValue, forKey: SharedSettingsKeys.enabledDisplayIDs)
            flushSharedDefaultsForIPC()
            dispatch(.displaysChanged(displays: newValue), ipc: WallpaperNotifications.displaysChanged, userInfo: ["displays": newValue])
        }
    }

    var displayArrangement: [String: DisplayLayoutConfiguration] {
        get {
            guard let data = repository.data(forKey: SharedSettingsKeys.displayArrangement),
                  let arrangement = try? JSONDecoder().decode([String: DisplayLayoutConfiguration].self, from: data) else {
                return [:]
            }
            return arrangement
        }
        set {
            do {
                let data = try JSONEncoder().encode(newValue)
                repository.set(data, forKey: SharedSettingsKeys.displayArrangement)
                flushSharedDefaultsForIPC()
                notifyChange(WallpaperNotifications.displayArrangementChanged)
            } catch {
                debugLog("[Settings] Failed to encode display arrangement: \(error)")
            }
        }
    }

    var spanWallpaperAcrossDisplays: Bool {
        get { repository.bool(forKey: SharedSettingsKeys.spanWallpaperAcrossDisplays) }
        set {
            repository.set(newValue, forKey: SharedSettingsKeys.spanWallpaperAcrossDisplays)
            flushSharedDefaultsForIPC()
            notifyChange(
                WallpaperNotifications.spanWallpaperAcrossDisplaysChanged,
                userInfo: ["enabled": newValue]
            )
        }
    }

    /// ディスプレイを削除（明示的な削除通知を送信）
    func removeDisplay(_ displayID: String) {
        var current = enabledDisplayIDs
        current.removeAll { $0 == displayID }
        repository.set(current, forKey: SharedSettingsKeys.enabledDisplayIDs)
        flushSharedDefaultsForIPC()
        dispatch(.displayRemoved(displayID: displayID), ipc: WallpaperNotifications.displayRemoved, userInfo: ["displayID": displayID])
    }

    // MARK: - Performance Settings

    var pauseWhenOtherAppActive: Bool {
        get { repository.bool(forKey: SharedSettingsKeys.pauseWhenOtherAppActive) }
        set {
            repository.set(newValue, forKey: SharedSettingsKeys.pauseWhenOtherAppActive)
            dispatch(.performanceSettingsChanged, ipc: WallpaperNotifications.performanceSettingsChanged)
        }
    }

    var pauseWhenFullscreen: Bool {
        get { repository.bool(forKey: SharedSettingsKeys.pauseWhenFullscreen) }
        set {
            repository.set(newValue, forKey: SharedSettingsKeys.pauseWhenFullscreen)
            dispatch(.performanceSettingsChanged, ipc: WallpaperNotifications.performanceSettingsChanged)
        }
    }

    var pauseOnBattery: Bool {
        get { repository.bool(forKey: SharedSettingsKeys.pauseOnBattery) }
        set {
            repository.set(newValue, forKey: SharedSettingsKeys.pauseOnBattery)
            dispatch(.performanceSettingsChanged, ipc: WallpaperNotifications.performanceSettingsChanged)
        }
    }

    var pauseOnHighGPU: Bool {
        get {
            // キーが登録されていない場合はデフォルトtrueを返す
            if repository.object(forKey: SharedSettingsKeys.pauseOnHighGPU) == nil {
                return true
            }
            return repository.bool(forKey: SharedSettingsKeys.pauseOnHighGPU)
        }
        set {
            repository.set(newValue, forKey: SharedSettingsKeys.pauseOnHighGPU)
            dispatch(.performanceSettingsChanged, ipc: WallpaperNotifications.performanceSettingsChanged)
        }
    }

    var gpuThreshold: Float {
        get {
            let value = repository.float(forKey: SharedSettingsKeys.gpuThreshold)
            return value > 0 ? value : AppConstants.Performance.defaultGPUThreshold
        }
        set {
            repository.set(newValue, forKey: SharedSettingsKeys.gpuThreshold)
            dispatch(.performanceSettingsChanged, ipc: WallpaperNotifications.performanceSettingsChanged)
        }
    }

    // MARK: - Performance Preset

    var performancePreset: PerformancePreset {
        get {
            let value = repository.integer(forKey: SharedSettingsKeys.performancePreset)
            return PerformancePreset(rawValue: value) ?? .balanced
        }
        set {
            repository.set(newValue.rawValue, forKey: SharedSettingsKeys.performancePreset)
            repository.set(newValue.frameRate, forKey: SharedSettingsKeys.performanceFrameRate)
            repository.set(newValue.resolutionScale, forKey: SharedSettingsKeys.performanceResolutionScale)
            dispatch(.performancePresetChanged(preset: newValue), ipc: WallpaperNotifications.performancePresetChanged, userInfo: [
                "preset": newValue.rawValue,
                "frameRate": newValue.frameRate,
                "resolutionScale": newValue.resolutionScale
            ])
        }
    }

    var performanceFrameRate: Int {
        get {
            if repository.object(forKey: SharedSettingsKeys.performanceFrameRate) == nil {
                return performancePreset.frameRate
            }
            return max(15, min(repository.integer(forKey: SharedSettingsKeys.performanceFrameRate), 144))
        }
        set {
            let clamped = max(15, min(newValue, 144))
            repository.set(clamped, forKey: SharedSettingsKeys.performanceFrameRate)
            notifyChange(WallpaperNotifications.performanceTuningChanged, userInfo: [
                "frameRate": clamped,
                "resolutionScale": performanceResolutionScale
            ])
        }
    }

    var performanceResolutionScale: Float {
        get {
            if repository.object(forKey: SharedSettingsKeys.performanceResolutionScale) == nil {
                return performancePreset.resolutionScale
            }
            let value = repository.float(forKey: SharedSettingsKeys.performanceResolutionScale)
            return max(0.01, min(value, 1.0))
        }
        set {
            let clamped = max(0.01, min(newValue, 1.0))
            repository.set(clamped, forKey: SharedSettingsKeys.performanceResolutionScale)
            notifyChange(WallpaperNotifications.performanceTuningChanged, userInfo: [
                "frameRate": performanceFrameRate,
                "resolutionScale": clamped
            ])
        }
    }

    // MARK: - GPU ブラシラスタライズ (Phase 1.4+ Feature Flag)

    /// ブラシマスクのラスタライズを Metal compute (GPU) 経路で行うか。
    /// - 既定値: false (従来の Rust 同期実装と完全互換)
    /// - true:   MetalBrushMaskRasterizer を Strategy で選択 (実験的)
    var useGPUBrush: Bool {
        get { repository.bool(forKey: SharedSettingsKeys.useGPUBrush) }
        set { repository.set(newValue, forKey: SharedSettingsKeys.useGPUBrush) }
    }

    // MARK: - パララックス強度 (Phase 4B)
    /// 0.0 で無効 (壁紙が全く動かない)、1.0 で標準的な視差量。
    /// Why: マウス位置に応じたレイヤーオフセットの強度倍率を Settings 経由で永続化する。
    var parallaxStrength: Float {
        get {
            if repository.object(forKey: SharedSettingsKeys.parallaxStrength) == nil {
                return 0.0
            }
            return max(0.0, min(repository.float(forKey: SharedSettingsKeys.parallaxStrength), 1.0))
        }
        set {
            let clamped = max(0.0, min(newValue, 1.0))
            repository.set(clamped, forKey: SharedSettingsKeys.parallaxStrength)
        }
    }

    // MARK: - Phase 6B: エフェクトチェイン DSL
    /// 空文字: 旧 EffectManager 経路。非空: EffectRegistry/EffectChainDSL 経路。
    var effectChain: String {
        get { repository.string(forKey: SharedSettingsKeys.effectChain) ?? "" }
        set { repository.set(newValue, forKey: SharedSettingsKeys.effectChain) }
    }

    // MARK: - Phase 7A: パフォーマンス自動制御 (検知系)

    /// 排他フルスクリーン時に壁紙を一時停止する (default: ON)
    /// Why: ゲーム/動画の全画面再生は他のアプリの背面を見ない前提なので、停止で電力節約のメリットが大きい。
    var pauseOnExclusiveFullscreen: Bool {
        get {
            if repository.object(forKey: SharedSettingsKeys.pauseOnExclusiveFullscreen) == nil {
                return true
            }
            return repository.bool(forKey: SharedSettingsKeys.pauseOnExclusiveFullscreen)
        }
        set {
            repository.set(newValue, forKey: SharedSettingsKeys.pauseOnExclusiveFullscreen)
            notifyChange(WallpaperNotifications.performanceSettingsChanged)
        }
    }

    /// 最大化ウィンドウ時に壁紙を一時停止する (default: OFF)
    /// Why: アクセシビリティ権限が必要なため、初期は無効にしておきユーザに明示的にオンにさせる。
    var pauseOnMaximizedWindow: Bool {
        get { repository.bool(forKey: SharedSettingsKeys.pauseOnMaximizedWindow) }
        set {
            repository.set(newValue, forKey: SharedSettingsKeys.pauseOnMaximizedWindow)
            notifyChange(WallpaperNotifications.performanceSettingsChanged)
        }
    }

    /// 他アプリが音再生中に壁紙を一時停止する (default: OFF)
    /// Why: 音壁紙が他アプリの音と重なる場合に活用。誤検知の影響が大きいため OFF を初期値にする。
    var pauseOnOtherAudio: Bool {
        get { repository.bool(forKey: SharedSettingsKeys.pauseOnOtherAudio) }
        set {
            repository.set(newValue, forKey: SharedSettingsKeys.pauseOnOtherAudio)
            notifyChange(WallpaperNotifications.performanceSettingsChanged)
        }
    }

    /// バッテリー駆動時の戦略 (default: .reduceFps)
    /// Why: MacBook ユーザの主流デバイス事情を踏まえ、停止より「FPS 30 抑制」をデフォルトとする。
    var batteryStrategy: BatteryStrategy {
        get {
            guard let raw = repository.string(forKey: SharedSettingsKeys.batteryStrategy),
                  let value = BatteryStrategy(rawValue: raw) else {
                return .reduceFps
            }
            return value
        }
        set {
            repository.set(newValue.rawValue, forKey: SharedSettingsKeys.batteryStrategy)
            notifyChange(WallpaperNotifications.performanceSettingsChanged)
        }
    }

    // MARK: - Phase 7B: スパニング壁紙
    /// 単一壁紙が複数ディスプレイをまたぐかどうか (default: false)
    var spanningEnabled: Bool {
        get { repository.bool(forKey: SharedSettingsKeys.spanningEnabled) }
        set {
            repository.set(newValue, forKey: SharedSettingsKeys.spanningEnabled)
            notifyChange(WallpaperNotifications.spanWallpaperAcrossDisplaysChanged, userInfo: ["enabled": newValue])
        }
    }

    // MARK: - Phase 8: ハードウェア連携

    /// Razer Chroma 連動 (default: false)。Synapse 3 が起動していなければ無視。
    var razerChromaEnabled: Bool {
        get { repository.bool(forKey: SharedSettingsKeys.razerChromaEnabled) }
        set { repository.set(newValue, forKey: SharedSettingsKeys.razerChromaEnabled) }
    }

    /// Corsair iCUE 連動 (default: false)。macOS 非対応のため UI は disabled。
    var corsairCueEnabled: Bool {
        get { repository.bool(forKey: SharedSettingsKeys.corsairCueEnabled) }
        set { repository.set(newValue, forKey: SharedSettingsKeys.corsairCueEnabled) }
    }

    /// LED Boost 強度 (0..1, default: 0.3)。彩度ブーストの倍率。
    var ledBoostIntensity: Float {
        get {
            if repository.object(forKey: SharedSettingsKeys.ledBoostIntensity) == nil {
                return 0.3
            }
            return repository.float(forKey: SharedSettingsKeys.ledBoostIntensity)
        }
        set {
            let clamped = max(0.0, min(1.0, newValue))
            repository.set(clamped, forKey: SharedSettingsKeys.ledBoostIntensity)
        }
    }

    // MARK: - Video Volume

    var videoVolume: Float {
        get {
            let value = repository.float(forKey: SharedSettingsKeys.videoVolume)
            // 未設定の場合はデフォルト1.0（最大音量）
            if repository.object(forKey: SharedSettingsKeys.videoVolume) == nil {
                return 1.0
            }
            return value
        }
        set {
            repository.set(newValue, forKey: SharedSettingsKeys.videoVolume)
            notifyChange(WallpaperNotifications.videoVolumeChanged, userInfo: ["volume": newValue])
        }
    }

    // MARK: - Web Wallpaper Scale

    var webWallpaperScale: Float {
        get {
            let value = repository.float(forKey: SharedSettingsKeys.webWallpaperScale)
            if repository.object(forKey: SharedSettingsKeys.webWallpaperScale) == nil {
                return 1.0
            }
            return max(0.5, min(value, 2.0))
        }
        set {
            let clamped = max(0.5, min(newValue, 2.0))
            repository.set(clamped, forKey: SharedSettingsKeys.webWallpaperScale)
            notifyChange(WallpaperNotifications.webWallpaperScaleChanged, userInfo: ["scale": clamped])
        }
    }

    var desktopItemsClickable: Bool {
        get { repository.bool(forKey: SharedSettingsKeys.desktopItemsClickable) }
        set {
            repository.set(newValue, forKey: SharedSettingsKeys.desktopItemsClickable)
            notifyChange(
                WallpaperNotifications.desktopItemsClickableChanged,
                userInfo: ["enabled": newValue]
            )
        }
    }

    private var webWallpaperDisplaySyncByRoot: [String: Bool] {
        get {
            guard let data = repository.data(forKey: SharedSettingsKeys.webWallpaperDisplaySyncByRoot),
                  let dict = try? JSONDecoder().decode([String: Bool].self, from: data) else {
                return [:]
            }
            return dict
        }
        set {
            do {
                let data = try JSONEncoder().encode(newValue)
                repository.set(data, forKey: SharedSettingsKeys.webWallpaperDisplaySyncByRoot)
            } catch {
                debugLog("[Settings] Failed to encode web wallpaper display sync map: \(error)")
            }
        }
    }

    private func normalizedWebWallpaperRootKey(for rootURL: URL) -> String {
        let canonical = WallpaperEngineWebResolver.canonicalFilesystemURL(matching: rootURL) ?? rootURL.standardizedFileURL
        return canonical.path
    }

    func isWebWallpaperDisplaySyncEnabled(for rootURL: URL) -> Bool {
        let key = normalizedWebWallpaperRootKey(for: rootURL)
        return webWallpaperDisplaySyncByRoot[key] ?? true
    }

    func setWebWallpaperDisplaySyncEnabled(_ enabled: Bool, for rootURL: URL) {
        let key = normalizedWebWallpaperRootKey(for: rootURL)
        var mapping = webWallpaperDisplaySyncByRoot
        mapping[key] = enabled
        webWallpaperDisplaySyncByRoot = mapping
        notifyChange(
            WallpaperNotifications.webWallpaperDisplaySyncChanged,
            userInfo: [
                "rootPath": key,
                "enabled": enabled
            ]
        )
    }

    // MARK: - Effect Configuration

    var effectConfiguration: EffectConfiguration? {
        get {
            guard let data = repository.data(forKey: SharedSettingsKeys.effectConfiguration) else {
                return nil
            }
            return try? JSONDecoder().decode(EffectConfiguration.self, from: data)
        }
        set {
            if let config = newValue {
                do {
                    let data = try JSONEncoder().encode(config)
                    repository.set(data, forKey: SharedSettingsKeys.effectConfiguration)
                } catch {
                    debugLog("[Settings] Failed to encode effect configuration: \(error)")
                }
            } else {
                repository.removeObject(forKey: SharedSettingsKeys.effectConfiguration)
            }
            dispatch(.effectConfigurationChanged(config: newValue), ipc: WallpaperNotifications.effectConfigurationChanged)
        }
    }

    // MARK: - Unified Notification Dispatch

    /// 統一通知ディスパッチ: EventBus（プロセス内）と DistributedNotification（プロセス間 IPC）を一括発行
    /// Why: --controller-only / --engine-only 起動時は別プロセスとなるため EventBus だけでは届かない。
    private func dispatch(_ event: WallpaperEvent, ipc name: Notification.Name, userInfo: [String: Any]? = nil) {
        eventBus.publish(event)
        DistributedNotificationCenter.default().postNotificationName(
            name,
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }

    /// IPC のみ通知（対応する WallpaperEvent がないケース用）
    /// Why: controller↔engine の別プロセス IPC が必須のため DNC を保持。
    private func notifyChange(_ name: Notification.Name, userInfo: [String: Any]? = nil) {
        DistributedNotificationCenter.default().postNotificationName(
            name,
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }

    /// controller / engine 分割時に、別プロセスが直後に同じ値を読めるよう共有 prefs を同期する
    func flushSharedDefaultsForIPC() {
        #if UNSIGNED_BUILD
        if let bid = Bundle.main.bundleIdentifier {
            CFPreferencesAppSynchronize(bid as CFString)
        }
        #else
        CFPreferencesAppSynchronize(SharedSettingsKeys.suiteName as CFString)
        #endif
    }

    /// 設定変更の監視を開始（後方互換性のため維持）
    /// 新しいコードではEventBusを直接使用することを推奨
    func startObserving(handler: @escaping (Notification.Name, [AnyHashable: Any]?) -> Void) {
        // 既存のオブザーバーを解除してから再登録（重複防止）
        stopObserving()

        let center = DistributedNotificationCenter.default()

        let notifications: [Notification.Name] = [
            WallpaperNotifications.shaderChanged,
            WallpaperNotifications.backgroundImageChanged,
            WallpaperNotifications.intensityChanged,
            WallpaperNotifications.videoVolumeChanged,
            WallpaperNotifications.pauseStateChanged,
            WallpaperNotifications.displaysChanged,
            WallpaperNotifications.displayRemoved,
            WallpaperNotifications.performanceSettingsChanged,
            WallpaperNotifications.performancePresetChanged,
            WallpaperNotifications.performanceTuningChanged,
            WallpaperNotifications.webWallpaperScaleChanged,
            WallpaperNotifications.desktopItemsClickableChanged,
            WallpaperNotifications.webWallpaperDisplaySyncChanged,
            WallpaperNotifications.effectConfigurationChanged,
            WallpaperNotifications.displayBackgroundImageChanged,
            WallpaperNotifications.displayArrangementChanged,
            WallpaperNotifications.spanWallpaperAcrossDisplaysChanged
        ]

        for name in notifications {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { notification in
                handler(name, notification.userInfo)
            }
            distributedObservers.append(observer)
        }
    }

    /// 設定変更の監視を停止（オブザーバーリーク防止）
    func stopObserving() {
        let center = DistributedNotificationCenter.default()
        for observer in distributedObservers {
            center.removeObserver(observer)
        }
        distributedObservers.removeAll()
    }
}
