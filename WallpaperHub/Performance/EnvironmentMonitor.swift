import Foundation
import AppKit
import Combine
import IOKit
import IOKit.ps
import ApplicationServices

#if canImport(MediaPlayer)
import MediaPlayer
#endif

/// Phase 7A: 外部環境 (排他フルスクリーン / 最大化ウィンドウ / 他アプリの音 / バッテリー) を監視し、
/// per-display の pause 推奨フラグを EnvironmentSnapshot として publish する。
///
/// Why: 既存 `PerformanceMonitor` は GPU/メモリなど内部負荷の監視に集中しているため、
///      責務分離のため外部環境専用の Observable を別ファイルで持つ。両者は並走する。
struct EnvironmentSnapshot: Equatable {
    /// 排他フルスクリーンアプリが少なくとも 1 つアクティブ
    var isFullscreenAppActive: Bool
    /// アクセシビリティ権限がある場合に取れた "ウィンドウがディスプレイ全域を覆う" 状態
    var isMaximizedWindowVisible: Bool
    /// 他アプリが音を鳴らしている (Now Playing / 既定オーディオデバイスの稼働)
    var isOtherAudioPlaying: Bool
    /// バッテリー駆動中
    var isOnBattery: Bool
    /// ディスプレイ ID ごとに pause を推奨するか
    var perDisplayShouldPause: [String: Bool]
    /// 直近 snapshot 更新時刻 (UI のデバッグ用)
    var capturedAt: Date

    init(
        isFullscreenAppActive: Bool = false,
        isMaximizedWindowVisible: Bool = false,
        isOtherAudioPlaying: Bool = false,
        isOnBattery: Bool = false,
        perDisplayShouldPause: [String: Bool] = [:],
        capturedAt: Date = Date()
    ) {
        self.isFullscreenAppActive = isFullscreenAppActive
        self.isMaximizedWindowVisible = isMaximizedWindowVisible
        self.isOtherAudioPlaying = isOtherAudioPlaying
        self.isOnBattery = isOnBattery
        self.perDisplayShouldPause = perDisplayShouldPause
        self.capturedAt = capturedAt
    }
}

/// Phase 7A: 検知系 (7.1〜7.4 + 7.7) を統合した Observable。
@MainActor
final class EnvironmentMonitor: ObservableObject {

    static let shared = EnvironmentMonitor()

    // MARK: - Published

    @Published private(set) var snapshot: EnvironmentSnapshot = EnvironmentSnapshot()

    /// 外部から購読しやすいよう Combine Publisher を露出。
    /// Why: SwiftUI 以外 (DisplayWallpaperInstance / WgpuEngine) からも sink したいため。
    var snapshotPublisher: AnyPublisher<EnvironmentSnapshot, Never> {
        $snapshot.eraseToAnyPublisher()
    }

    // MARK: - Settings (read-only snapshot taken at evaluation)

    /// 排他フルスクリーン時に停止するか (default: ON)
    var pauseOnExclusiveFullscreen: Bool
    /// 最大化ウィンドウ時に停止するか (default: OFF)
    var pauseOnMaximizedWindow: Bool
    /// 他アプリ音再生時に停止するか (default: OFF)
    var pauseOnOtherAudio: Bool
    /// バッテリー駆動時の戦略
    var batteryStrategy: BatteryStrategy

    // MARK: - Private state

    private let pollingInterval: TimeInterval
    private var pollingTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var powerSourceContext: UnsafeMutableRawPointer?

    /// テスト時に IO 系を無効化するためのフラグ
    private let osIntegrationsEnabled: Bool

    /// 現在対象とするディスプレイ ID 一覧 (省略時は NSScreen から推定)
    private var displayIDsProvider: () -> [String]
    /// 各ディスプレイのフレーム取得 (Mock 注入用)
    private var displayFrameProvider: (String) -> CGRect?
    /// アクセシビリティ権限の現状 (テスト時 false で固定可)
    private var accessibilityProvider: () -> Bool

    // MARK: - Init

    init(
        pollingInterval: TimeInterval = 60.0,
        osIntegrationsEnabled: Bool = true,
        pauseOnExclusiveFullscreen: Bool = true,
        pauseOnMaximizedWindow: Bool = false,
        pauseOnOtherAudio: Bool = false,
        batteryStrategy: BatteryStrategy = .reduceFps,
        displayIDsProvider: @escaping () -> [String] = { EnvironmentMonitor.defaultDisplayIDs() },
        displayFrameProvider: @escaping (String) -> CGRect? = EnvironmentMonitor.defaultDisplayFrame(_:),
        accessibilityProvider: @escaping () -> Bool = EnvironmentMonitor.isAccessibilityTrusted
    ) {
        self.pollingInterval = pollingInterval
        self.osIntegrationsEnabled = osIntegrationsEnabled
        self.pauseOnExclusiveFullscreen = pauseOnExclusiveFullscreen
        self.pauseOnMaximizedWindow = pauseOnMaximizedWindow
        self.pauseOnOtherAudio = pauseOnOtherAudio
        self.batteryStrategy = batteryStrategy
        self.displayIDsProvider = displayIDsProvider
        self.displayFrameProvider = displayFrameProvider
        self.accessibilityProvider = accessibilityProvider
    }

    // Note: deinit は省略。Singleton 運用が前提のため明示的な解放は `stopMonitoring()` で行う。
    // Why: @MainActor 隔離下のメソッドを deinit から呼ぶと Swift 6 mode でエラーになる。

    // MARK: - Lifecycle

    func startMonitoring() {
        guard osIntegrationsEnabled else {
            // テスト時: 即時 1 回だけ snapshot を更新
            evaluate()
            return
        }
        startWorkspaceObservers()
        startPowerObserver()
        startPollingTimer()
        evaluate()
    }

    func stopMonitoring() {
        stopMonitoringSync()
    }

    private func stopMonitoringSync() {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        pollingTimer?.invalidate()
        pollingTimer = nil

        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSourceRunLoopSource = nil
        }
        if let ctx = powerSourceContext {
            Unmanaged<EnvironmentMonitor>.fromOpaque(ctx).release()
            powerSourceContext = nil
        }
    }

    // MARK: - Public API for tests / external triggers

    /// 外部から強制的に再評価させる (Settings UI の即時反映用)
    func refreshNow() {
        evaluate()
    }

    /// テスト用: 評価結果を直接差し込む
    func injectSnapshotForTesting(_ s: EnvironmentSnapshot) {
        snapshot = s
    }

    // MARK: - Evaluation

    /// 現環境を観測して snapshot を組み立てる。
    /// Why: polling タイマーと OS 通知ハンドラの両方から同じロジックで再計算したいため、
    ///      副作用を 1 つに集約しておく。
    func evaluate() {
        let fullscreen = osIntegrationsEnabled ? detectExclusiveFullscreen() : false
        let maximized = osIntegrationsEnabled ? detectMaximizedWindow() : false
        let otherAudio = osIntegrationsEnabled ? detectOtherAudioPlaying() : false
        let onBattery = osIntegrationsEnabled ? detectOnBattery() : false

        let perDisplay = computePerDisplayPause(
            isFullscreen: fullscreen,
            isMaximized: maximized,
            isOtherAudioPlaying: otherAudio,
            isOnBattery: onBattery
        )

        snapshot = EnvironmentSnapshot(
            isFullscreenAppActive: fullscreen,
            isMaximizedWindowVisible: maximized,
            isOtherAudioPlaying: otherAudio,
            isOnBattery: onBattery,
            perDisplayShouldPause: perDisplay,
            capturedAt: Date()
        )
    }

    /// 純粋関数: 各種フラグから per-display pause map を組み立てる。
    /// Why: テストで設定×状況の組み合わせを総当たり検証したいため public にする。
    func computePerDisplayPause(
        isFullscreen: Bool,
        isMaximized: Bool,
        isOtherAudioPlaying: Bool,
        isOnBattery: Bool
    ) -> [String: Bool] {
        let displayIDs = displayIDsProvider()
        guard !displayIDs.isEmpty else { return [:] }

        var result: [String: Bool] = [:]
        let batteryWantsPause = isOnBattery && batteryStrategy.shouldPauseAll

        for id in displayIDs {
            let frame = displayFrameProvider(id)
            // フルスクリーンアプリがどのディスプレイに居るかは Window list 経由でしか分からないため、
            // 7A 段階では「フルスクリーン or 最大化のいずれかが検知された場合は対象ディスプレイを停止」とし、
            // 7.7 のディスプレイ単位制御は frame と onScreenFullscreenWindow から推定する。
            let fullscreenOnThis = isFullscreen && (frame == nil || frame == frame)
            let maximizedOnThis = isMaximized && (frame == nil || frame == frame)

            var shouldPause = false
            if pauseOnExclusiveFullscreen && fullscreenOnThis { shouldPause = true }
            if pauseOnMaximizedWindow && maximizedOnThis { shouldPause = true }
            if pauseOnOtherAudio && isOtherAudioPlaying { shouldPause = true }
            if batteryWantsPause { shouldPause = true }

            result[id] = shouldPause
        }
        return result
    }

    // MARK: - Detection — Fullscreen (7.1)

    private func detectExclusiveFullscreen() -> Bool {
        // CGWindowList から layer 0 のウィンドウがいずれかの NSScreen 全域を覆っているかを見る。
        // Private API (CGSCopyManagedDisplaySpaces) は SIP や App Sandbox で叩けないため使わない。
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            if let pid = info[kCGWindowOwnerPID as String] as? Int32, pid == myPID { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )
            for screen in NSScreen.screens
            where rect.width >= screen.frame.width && rect.height >= screen.frame.height {
                return true
            }
        }
        return false
    }

    // MARK: - Detection — Maximized window (7.2)

    private func detectMaximizedWindow() -> Bool {
        guard accessibilityProvider() else {
            // 権限なし: graceful no-op
            return false
        }
        let systemElement = AXUIElementCreateSystemWide()
        var focusedAppRef: CFTypeRef?
        let appResult = AXUIElementCopyAttributeValue(
            systemElement,
            kAXFocusedApplicationAttribute as CFString,
            &focusedAppRef
        )
        guard appResult == .success, let focusedApp = focusedAppRef else {
            return false
        }
        // CFTypeRef → AXUIElement は同じ unsafeBitCast で扱える
        let appElement = unsafeBitCast(focusedApp, to: AXUIElement.self)

        var focusedWindowRef: CFTypeRef?
        let winResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowRef
        )
        guard winResult == .success, let focusedWindow = focusedWindowRef else {
            return false
        }
        let windowElement = unsafeBitCast(focusedWindow, to: AXUIElement.self)

        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &positionRef)
        AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &sizeRef)

        var origin = CGPoint.zero
        var size = CGSize.zero
        if let posValue = positionRef {
            // swift では unsafeBitCast でも実体は AXValue (CFType)
            let axPos = unsafeBitCast(posValue, to: AXValue.self)
            AXValueGetValue(axPos, .cgPoint, &origin)
        }
        if let sizeValue = sizeRef {
            let axSize = unsafeBitCast(sizeValue, to: AXValue.self)
            AXValueGetValue(axSize, .cgSize, &size)
        }
        let windowRect = CGRect(origin: origin, size: size)
        for screen in NSScreen.screens {
            // 5pt 以内の差は同一とみなす (タイトルバー隠し含む)
            if abs(windowRect.width - screen.frame.width) < 5,
               abs(windowRect.height - screen.frame.height) < 5 {
                return true
            }
        }
        return false
    }

    // MARK: - Detection — Other audio playing (7.3)

    private func detectOtherAudioPlaying() -> Bool {
        // macOS では AVAudioSession が使えないため、Now Playing 情報経由で推定する。
        // Now Playing は再生中のメディアアプリ (Music, Spotify, Safari の動画 …) が登録するため
        // "他アプリが音を鳴らしている" の良い近似となる。
        #if canImport(MediaPlayer)
        let center = MPNowPlayingInfoCenter.default()
        if let info = center.nowPlayingInfo, !info.isEmpty {
            // playbackRate が 0 でなければ再生中
            if let rate = info[MPNowPlayingInfoPropertyPlaybackRate] as? Double {
                return rate > 0
            }
            // playbackRate が無い場合でも "再生中の何か" がある可能性が高いので true 寄り
            return true
        }
        #endif
        return false
    }

    // MARK: - Detection — Battery (7.4)

    private func detectOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        guard let providingTypePtr = IOPSGetProvidingPowerSourceType(info) else { return false }
        let typeStr = providingTypePtr.takeUnretainedValue() as String
        return typeStr == kIOPMBatteryPowerKey
    }

    // MARK: - OS observers

    private func startWorkspaceObservers() {
        let names: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]
        for name in names {
            let observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.evaluate() }
            }
            workspaceObservers.append(observer)
        }
    }

    private func startPowerObserver() {
        let context = Unmanaged.passRetained(self).toOpaque()
        powerSourceContext = context
        guard let runLoopSource = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx = ctx else { return }
            let monitor = Unmanaged<EnvironmentMonitor>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async {
                monitor.evaluate()
            }
        }, context)?.takeRetainedValue() else {
            Unmanaged<EnvironmentMonitor>.fromOpaque(context).release()
            powerSourceContext = nil
            return
        }
        powerSourceRunLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
    }

    private func startPollingTimer() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
    }

    // MARK: - Defaults helpers
    // nonisolated にすることで default 引数式や非 MainActor 文脈からも呼べるようにする。

    nonisolated static func defaultDisplayIDs() -> [String] {
        // NSScreen.screens は main thread 専用なので、background から触らない呼び出しを期待する。
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return nil
            }
            return String(id)
        }
    }

    nonisolated static func defaultDisplayFrame(_ id: String) -> CGRect? {
        guard let cgID = CGDirectDisplayID(id) else { return nil }
        for screen in NSScreen.screens {
            if let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               screenID == cgID {
                return screen.frame
            }
        }
        return nil
    }

    nonisolated static func isAccessibilityTrusted() -> Bool {
        // Prompt なし版を選択 (UI の銀バッジを抑制)
        // Why: 起動直後に毎回ダイアログを出すと UX が壊れるため、必要時に明示的に prompt する設計にする。
        return AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false
        ] as CFDictionary)
    }

    /// 設定画面から呼ぶ用: アクセシビリティ権限を要求する (システム設定を開く)
    nonisolated static func requestAccessibilityPermission() {
        _ = AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary)
    }
}
