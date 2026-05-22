import Foundation
import AppKit
import IOKit
import IOKit.ps
import Darwin

/// パフォーマンス監視と自動一時停止制御
class PerformanceMonitor: ObservableObject {
    static let shared = PerformanceMonitor()

    // MARK: - Published State

    /// 他アプリがアクティブ時に一時停止（ディスプレイごとに判定）
    @Published var pauseWhenOtherAppActive: Bool = false {
        didSet { saveSettings(); updatePauseState() }
    }

    /// フルスクリーンアプリ使用時に一時停止
    @Published var pauseWhenFullscreen: Bool = false {
        didSet { saveSettings(); updatePauseState() }
    }

    /// バッテリー駆動時に一時停止
    @Published var pauseOnBattery: Bool = false {
        didSet { saveSettings(); updatePauseState() }
    }

    /// GPU使用率が閾値を超えた時に一時停止
    @Published var pauseOnHighGPU: Bool = true {
        didSet { saveSettings(); restartGPUMonitoringIfNeeded() }
    }

    /// GPU使用率閾値 (0-100)
    @Published var gpuThreshold: Float = 80.0 {
        didSet { saveSettings() }
    }

    // MARK: - Current Status

    /// 現在バッテリー駆動中か
    @Published private(set) var isOnBattery: Bool = false

    /// 現在のGPU使用率
    @Published private(set) var currentGPUUsage: Float = 0.0

    /// 現在のメモリ使用率
    @Published private(set) var currentMemoryUsage: Float = 0.0

    /// フルスクリーンアプリが実行中か
    @Published private(set) var isFullscreenAppRunning: Bool = false

    /// 他のアプリがアクティブか
    @Published private(set) var isOtherAppActive: Bool = false

    /// 現在のフォアグラウンドアプリ名
    @Published private(set) var frontmostAppName: String = ""

    /// パフォーマンスモニターによる一時停止中か
    @Published private(set) var isPausedByMonitor: Bool = false

    /// 一時停止の理由
    @Published private(set) var pauseReasons: Set<PauseReason> = []

    // MARK: - Types

    enum PauseReason: String, CaseIterable {
        case otherAppActive = "他のアプリがアクティブ"
        case fullscreenApp = "フルスクリーンアプリ使用中"
        case batteryPower = "バッテリー駆動中"
        case highGPUUsage = "GPU使用率が高い"
    }

    // MARK: - Private

    private let settings: SettingsManagerProtocol
    private var gpuMonitorTimer: Timer?
    private var fullscreenCheckTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var powerSourceRunLoopSource: CFRunLoopSource?
    /// IOPSコールバックに渡したselfのポインタ（release用に保持）
    private var powerSourceContext: UnsafeMutableRawPointer?
    private var isUserManuallyPaused: Bool = false

    // MARK: - Initialization

    private init(settings: SettingsManagerProtocol = SharedSettingsManager.shared) {
        self.settings = settings
        loadSettings()
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Settings Persistence

    private func loadSettings() {
        pauseWhenOtherAppActive = settings.pauseWhenOtherAppActive
        pauseWhenFullscreen = settings.pauseWhenFullscreen
        pauseOnBattery = settings.pauseOnBattery
        pauseOnHighGPU = settings.pauseOnHighGPU
        gpuThreshold = settings.gpuThreshold
    }

    private func saveSettings() {
        settings.pauseWhenOtherAppActive = pauseWhenOtherAppActive
        settings.pauseWhenFullscreen = pauseWhenFullscreen
        settings.pauseOnBattery = pauseOnBattery
        settings.pauseOnHighGPU = pauseOnHighGPU
        settings.gpuThreshold = gpuThreshold
    }

    // MARK: - Monitoring Control

    func startMonitoring() {
        observeFrontmostApp()
        observePowerSource()
        startFullscreenCheckTimer()
        restartGPUMonitoringIfNeeded()
        debugLog("[PerformanceMonitor] Started monitoring")
    }

    func stopMonitoring() {
        // ワークスペースオブザーバーを削除
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        // タイマー停止
        gpuMonitorTimer?.invalidate()
        gpuMonitorTimer = nil
        fullscreenCheckTimer?.invalidate()
        fullscreenCheckTimer = nil

        // 電源監視を停止
        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSourceRunLoopSource = nil
        }

        // passRetainedで保持したselfの参照カウントを解放
        if let context = powerSourceContext {
            Unmanaged<PerformanceMonitor>.fromOpaque(context).release()
            powerSourceContext = nil
        }

        debugLog("[PerformanceMonitor] 監視を停止しました")
    }

    // MARK: - Frontmost App Monitoring

    private func observeFrontmostApp() {
        let activateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleAppActivation(notification)
        }
        workspaceObservers.append(activateObserver)

        // 初期状態を取得
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            updateFrontmostApp(frontmost)
        }
    }

    private func handleAppActivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        updateFrontmostApp(app)
    }

    private func updateFrontmostApp(_ app: NSRunningApplication) {
        frontmostAppName = app.localizedName ?? "不明"

        // 自分のアプリかどうかチェック
        let isOurApp = app.bundleIdentifier == Bundle.main.bundleIdentifier
        isOtherAppActive = !isOurApp

        // Note: pauseWhenOtherAppActive の実際の一時停止は
        // 各 DisplayWallpaperInstance が個別に判定するため、
        // ここでは updatePauseState() を呼ばない（グローバル一時停止しない）
    }

    // MARK: - Fullscreen Detection

    private func startFullscreenCheckTimer() {
        fullscreenCheckTimer = Timer.scheduledTimer(withTimeInterval: AppConstants.TimerIntervals.fullscreenCheck, repeats: true) { [weak self] _ in
            self?.checkFullscreenState()
        }
        checkFullscreenState()
    }

    private func checkFullscreenState() {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            isFullscreenAppRunning = false
            return
        }

        var hasFullscreen = false

        for windowInfo in windowList {
            guard let layer = windowInfo[kCGWindowLayer as String] as? Int,
                  let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? Int32 else {
                continue
            }

            // レイヤー0のウィンドウ（通常のアプリウィンドウ）をチェック
            if layer == 0 {
                // 自分のアプリは除外
                if ownerPID == ProcessInfo.processInfo.processIdentifier {
                    continue
                }

                // ウィンドウの境界を取得
                if let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat] {
                    let windowBounds = CGRect(
                        x: boundsDict["X"] ?? 0,
                        y: boundsDict["Y"] ?? 0,
                        width: boundsDict["Width"] ?? 0,
                        height: boundsDict["Height"] ?? 0
                    )

                    // いずれかの画面全体をカバーしているかチェック
                    for screen in NSScreen.screens {
                        if windowBounds.width >= screen.frame.width &&
                           windowBounds.height >= screen.frame.height {
                            hasFullscreen = true
                            break
                        }
                    }
                }
            }

            if hasFullscreen { break }
        }

        if isFullscreenAppRunning != hasFullscreen {
            isFullscreenAppRunning = hasFullscreen
            updatePauseState()
        }
    }

    // MARK: - Power Source Monitoring

    private func observePowerSource() {
        // 初期状態を取得
        updatePowerSourceStatus()

        // 電源状態の変更を監視
        // passRetainedで保持カウントを増やし、コールバック中のダングリングポインタを防止。
        // 対応するreleaseはstopMonitoring()内で行う。
        let context = Unmanaged.passRetained(self).toOpaque()
        powerSourceContext = context

        guard let runLoopSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context = context else { return }
            let monitor = Unmanaged<PerformanceMonitor>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                monitor.updatePowerSourceStatus()
            }
        }, context)?.takeRetainedValue() else {
            debugLog("[PerformanceMonitor] 電源通知の作成に失敗しました")
            // コールバック登録に失敗した場合、passRetainedで増やした参照カウントを解放
            Unmanaged<PerformanceMonitor>.fromOpaque(context).release()
            powerSourceContext = nil
            return
        }

        powerSourceRunLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
    }

    private func updatePowerSourceStatus() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return
        }

        for source in sources {
            if let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] {
                if let powerSource = description[kIOPSPowerSourceStateKey as String] as? String {
                    let wasOnBattery = isOnBattery
                    isOnBattery = (powerSource == kIOPSBatteryPowerValue as String)

                    if wasOnBattery != isOnBattery {
                        debugLog("[PerformanceMonitor] Power source changed: \(isOnBattery ? "Battery" : "AC")")
                        updatePauseState()
                    }
                }
            }
        }
    }

    // MARK: - GPU Monitoring

    private func restartGPUMonitoringIfNeeded() {
        gpuMonitorTimer?.invalidate()
        gpuMonitorTimer = nil

        gpuMonitorTimer = Timer.scheduledTimer(withTimeInterval: AppConstants.TimerIntervals.gpuMonitoring, repeats: true) { [weak self] _ in
            self?.updateResourceUsage()
        }
        updateResourceUsage()
    }

    private func updateResourceUsage() {
        currentGPUUsage = queryGPUUsage()
        currentMemoryUsage = queryMemoryUsage()
        updatePauseState()
    }

    /// GPU使用率の取得キー候補（優先順）
    private static let gpuUsageKeys = [
        "Device Utilization %",
        "GPU Activity(%)",
        "GPU Core Utilization",
        "gpuCoreUtilizationPercent"
    ]

    private func queryGPUUsage() -> Float {
        var maxUsage: Float = 0.0
        var foundAnyGPU = false

        let matchDict = IOServiceMatching("IOAccelerator")
        var iterator: io_iterator_t = 0

        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator) == KERN_SUCCESS else {
            return queryGPUUsageFallback()
        }

        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = properties?.takeRetainedValue() as? [String: Any] else {
                continue
            }

            foundAnyGPU = true

            if let perfStats = props["PerformanceStatistics"] as? [String: Any] {
                for key in Self.gpuUsageKeys {
                    if let gpuUsage = perfStats[key] as? Int {
                        maxUsage = max(maxUsage, Float(gpuUsage))
                        break
                    } else if let gpuUsage = perfStats[key] as? Double {
                        maxUsage = max(maxUsage, Float(gpuUsage))
                        break
                    }
                }
            }
        }

        if !foundAnyGPU {
            return queryGPUUsageFallback()
        }

        return maxUsage
    }

    let totalMemory = ProcessInfo.processInfo.physicalMemory

    func getSystemMemoryInfo() -> (free: UInt64, active: UInt64, wired: UInt64, compressed: UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return (0, 0, 0, 0) }
        let pageSize: UInt64 = UInt64(vm_kernel_page_size)
        return(
            free: UInt64(stats.free_count) * pageSize,
            active: UInt64(stats.active_count) * pageSize,
            wired: UInt64(stats.wire_count) * pageSize,
            compressed: UInt64(stats.compressor_page_count) * pageSize
        )
    }

    private func queryMemoryUsage() -> Float {
        let memoryInfo = getSystemMemoryInfo()
        guard totalMemory > 0 else { return 0.0 }

        let usedBytes = min(totalMemory, memoryInfo.active + memoryInfo.wired + memoryInfo.compressed)
        return Float(usedBytes) / Float(totalMemory) * 100.0
    }

    /// Apple Silicon用フォールバック（AGXAccelerator）
    private func queryGPUUsageFallback() -> Float {
        let matchDict = IOServiceMatching("AGXAccelerator")
        var iterator: io_iterator_t = 0

        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator) == KERN_SUCCESS else {
            return 0.0
        }

        defer { IOObjectRelease(iterator) }

        var maxUsage: Float = 0.0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = properties?.takeRetainedValue() as? [String: Any] else {
                continue
            }

            if let perfStats = props["PerformanceStatistics"] as? [String: Any] {
                for key in Self.gpuUsageKeys {
                    if let gpuUsage = perfStats[key] as? Int {
                        maxUsage = max(maxUsage, Float(gpuUsage))
                        break
                    } else if let gpuUsage = perfStats[key] as? Double {
                        maxUsage = max(maxUsage, Float(gpuUsage))
                        break
                    }
                }
            }
        }

        return maxUsage
    }

    // MARK: - Pause State Management

    private func updatePauseState() {
        var newReasons: Set<PauseReason> = []

        // Note: otherAppActive と fullscreenApp はディスプレイごとに
        // DisplayWallpaperInstance が個別に判定・制御するため、
        // グローバル一時停止の対象外とする

        if pauseOnBattery && isOnBattery {
            newReasons.insert(.batteryPower)
        }

        if pauseOnHighGPU && currentGPUUsage > gpuThreshold {
            newReasons.insert(.highGPUUsage)
        }

        // UI表示用にフルスクリーン/アクティブアプリの理由も追跡（実際の一時停止はDisplayWallpaperInstanceが個別に判定）
        if pauseWhenOtherAppActive && isOtherAppActive {
            newReasons.insert(.otherAppActive)
        }
        if pauseWhenFullscreen && isFullscreenAppRunning {
            newReasons.insert(.fullscreenApp)
        }

        // グローバル一時停止はバッテリーとGPUのみで判定
        let globalPauseReasons: Set<PauseReason> = newReasons.intersection([.batteryPower, .highGPUUsage])
        let shouldPause = !globalPauseReasons.isEmpty

        // 状態が変わった場合のみ更新
        if pauseReasons != newReasons {
            pauseReasons = newReasons
        }

        if isPausedByMonitor != shouldPause {
            isPausedByMonitor = shouldPause

            // ユーザーが手動で一時停止していない場合のみ、エンジンの状態を変更
            if !isUserManuallyPaused {
                settings.isPaused = shouldPause
                debugLog("[PerformanceMonitor] Auto-pause: \(shouldPause), reasons: \(globalPauseReasons.map { $0.rawValue })")
            }
        }
    }

    /// ユーザーの手動一時停止状態を設定
    func setUserManuallyPaused(_ paused: Bool) {
        isUserManuallyPaused = paused
        if !paused {
            // 手動一時停止解除時、現在の条件を再評価
            updatePauseState()
        }
    }

    // MARK: - Status Text

    /// 現在の一時停止理由をテキストで取得
    var pauseReasonText: String? {
        guard !pauseReasons.isEmpty else { return nil }
        return pauseReasons.map { $0.rawValue }.joined(separator: ", ")
    }
}
