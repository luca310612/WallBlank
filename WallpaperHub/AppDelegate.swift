import Cocoa
import MetalKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import WidgetKit

/// 動作モード
enum AppMode {
    case controller  // 設定UIのみ（メニューバーアプリ）
    case engine      // 壁紙描画のみ（バックグラウンド）
    case combined    // 両方（開発用・従来動作）
}

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    // MARK: - Properties

    // 動作モード（起動引数で決定）
    var appMode: AppMode = .combined

    // 壁紙エンジン（engine/combinedモードで使用）
    var wallpaperEngine: WallpaperEngine?

    // プレビューウィンドウ用（controller/combinedモードで使用）
    var previewWindow: NSWindow?
    var previewRenderer: Renderer?

    // メインHubウィンドウ
    var mainHubWindow: NSWindow?
    var hubPreviewRenderer: Renderer?

    // ロック画面ウィンドウ
    var lockScreenWindow: NSWindow?
    var lockScreenRenderer: Renderer?

    // 設定マネージャー
    let settings: SettingsManagerProtocol

    // ディスプレイ・パフォーマンス管理
    let displayManager: DisplayManager
    let performanceMonitor: PerformanceMonitor

    // UI用の状態（@Publishedで監視可能）
    @Published var isPaused = false
    @Published var currentShader: ShaderType = .transparent
    @Published var backgroundImageURL: URL?
    @Published var displayBackgroundPaths: [String: String] = [:]
    @Published var effectIntensity: Float = 0.0
    @Published var videoVolume: Float = 1.0
    @Published var effectConfiguration: EffectConfiguration = .default

    // エフェクトマネージャー
    let effectManager: EffectManager

    /// エフェクト変更通知のObserverトークン（解除用）
    private var effectObserverToken: NSObjectProtocol?

    /// 壁紙の明示的な変更ごとに進む（非同期シーン展開の古い完了を無視する）
    private var wallpaperSelectionEpoch: UInt64 = 0

    // MARK: - Initialization

    override init() {
        self.settings = SharedSettingsManager.shared
        self.displayManager = DisplayManager.shared
        self.performanceMonitor = PerformanceMonitor.shared
        self.effectManager = EffectManager.shared
        super.init()
    }

    // MARK: - NSApplicationDelegate Lifecycle

    /// スリープ/復帰/ロック監視用Observerトークン
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var screensSleepObserver: NSObjectProtocol?
    private var screensWakeObserver: NSObjectProtocol?
    private var sessionResignObserver: NSObjectProtocol?
    private var sessionBecomeActiveObserver: NSObjectProtocol?

    /// スリープ/ロック前にエディターが再生中だったか（復帰時に再開するため）
    private var editorWasPlayingBeforeSuspend: Bool = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ユニットテスト実行中は AppKit/Metal/Rust の重い初期化を一切行わない。
        // Why: TEST_HOST=WallBlank.app で ArtiaMenubarTests を起動するため、tests 用に最小起動状態を維持する。
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        NSWindow.allowsAutomaticWindowTabbing = false
        // Rustコアの初期化
        RustCore.initialize()
        // Rust 製 Firebase クライアントの初期化 (失敗しても既存 SDK パスへフォールバックするため非致命)
        // Why: Phase 2D 段階移行 — GalleryManager は Rust 経路を試行し、失敗時に SDK へ落ちる。
        _ = RustFirebase.initializeFromBundleIfPossible()

        UNUserNotificationCenter.current().delegate = self

        // 起動引数からモードを決定
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--engine-only") {
            appMode = .engine
        } else if arguments.contains("--controller-only") {
            appMode = .controller
        } else {
            appMode = .combined
        }

        debugLog("[WallBlank] \(appMode)モードで起動中...")

        switch appMode {
        case .engine:
            // 壁紙エンジンのみ起動
            wallpaperEngine = WallpaperEngine()

        case .controller:
            // 設定UIのみ - 壁紙エンジンを別プロセスで起動
            loadSettingsFromStorage()
            launchEngineIfNeeded()

        case .combined:
            // 両方（従来動作）- 壁紙エンジンを自動起動
            wallpaperEngine = WallpaperEngine()
            loadSettingsFromStorage()
            syncSettingsToEngine()
        }

        // スリープ/復帰の監視を開始
        setupSleepWakeObservers()

        // ウィジェット連携の初期化
        startObservingWidgetIntents()
        refreshWidgetData()

        // Phase 8E: artia:// URL Scheme の AppleEvent ハンドラを登録
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        // 認証マネージャー初期化
        AuthManager.shared.configure()

        // Steam Workshop 用マネージャー初期化（App ID 設定時のみ有効化）
        _ = SteamManager.shared

        // スケジュール・環境連動マネージャーに壁紙適用ハンドラを設定
        let wallpaperHandler: (WallpaperItem, WallpaperLibrary) -> Void = { [weak self] wallpaper, library in
            guard let self = self,
                  let url = library.getWallpaperURL(for: wallpaper) else { return }
            self.setBackgroundImage(url: url)
        }
        ScheduleManager.shared.applyWallpaperHandler = wallpaperHandler

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            MacOSDesktopClickRevealAdvice.scheduleLocalReminderIfAppropriate(appMode: self.appMode)
        }

        debugLog("[WallBlank] 起動完了")
    }

    /// ウィンドウを閉じてもアプリを終了しない
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // ウィンドウが表示されていない場合、メインウィンドウを表示
        if !flag {
            // WindowGroupのウィンドウを探す
            var foundWindow = false
            for window in NSApp.windows {
                if window.identifier?.rawValue == "main" || window.title == "WallBlank" {
                    window.tabbingMode = .disallowed
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    foundWindow = true
                    break
                }
            }

            // ウィンドウが見つからない場合、SwiftUIのWindowGroupを開く
            if !foundWindow {
                // SwiftUIのEnvironment経由でウィンドウを開くため、通知を送信
                NotificationCenter.default.post(name: NSNotification.Name("OpenMainWindow"), object: nil)
            }
        } else {
            // 既にウィンドウが表示されている場合、それを前面に持ってくる
            for window in NSApp.windows {
                if window.identifier?.rawValue == "main" || window.title == "WallBlank" {
                    window.tabbingMode = .disallowed
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    break
                }
            }
        }
        return true
    }
}

// MARK: - artia:// URL Scheme

extension AppDelegate {

    /// NSAppleEventManager から呼ばれる artia:// URL ハンドラ。
    /// AppleEvent は main thread で配信されるが、PlaylistManager 等が @MainActor 隔離なので
    /// MainActor 環境で改めて呼び直す。
    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else {
            debugLog("[ArtiaURL] パラメータが取得できません")
            return
        }
        Task { @MainActor in
            self.dispatchArtiaURL(url)
        }
    }

    /// 解析してから対応する Manager を呼び出す
    @MainActor
    func dispatchArtiaURL(_ url: URL) {
        let parsed = ArtiaURLHandler.parse(url)
        debugLog("[ArtiaURL] \(url.absoluteString) → \(parsed)")
        switch parsed {
        case .wallpaperSet(let target):
            applyWallpaperFromURLTarget(target)
        case .wallpaperNext:
            ScheduleManager.shared.advanceNow()
        case .wallpaperPrev:
            // 既存のスケジュール巻き戻し API は無いので、直前の壁紙を WallpaperLibrary 順で探して適用する
            applyAdjacentWallpaper(forward: false)
        case .wallpaperRandom:
            applyRandomWallpaper()
        case .playlistSwitch(let id):
            switchPlaylist(idString: id)
        case .profileSwitch(let id):
            switchProfile(idString: id)
        case .propertySet(let key, let value):
            applyPropertySet(key: key, value: value)
        case .unknown(let reason):
            debugLog("[ArtiaURL] WARN 未解釈: \(reason)")
        }
    }

    @MainActor
    private func applyWallpaperFromURLTarget(_ target: String) {
        // id 一致を優先、ファイルパスとしても受け入れる
        if let item = WallpaperLibrary.shared.wallpapers.first(where: { $0.id == target }),
           let url = WallpaperLibrary.shared.getWallpaperURL(for: item) {
            setBackgroundImage(url: url)
            return
        }
        // ファイルパスとして解釈 (絶対パス前提)
        if target.hasPrefix("/") || target.hasPrefix("file://") {
            let candidate = target.hasPrefix("file://") ? URL(string: target) : URL(fileURLWithPath: target)
            if let url = candidate, FileManager.default.fileExists(atPath: url.path) {
                setBackgroundImage(url: url)
                return
            }
        }
        debugLog("[ArtiaURL] WARN wallpaper set: 該当 ID/パスなし: \(target)")
    }

    @MainActor
    private func applyAdjacentWallpaper(forward: Bool) {
        let items = WallpaperLibrary.shared.wallpapers.filter { $0.isDownloaded }
        guard !items.isEmpty else { return }
        let currentPath = backgroundImageURL?.path
        let currentIndex = items.firstIndex { item in
            guard let url = WallpaperLibrary.shared.getWallpaperURL(for: item) else { return false }
            return url.path == currentPath
        }
        let count = items.count
        let nextIndex: Int
        if let idx = currentIndex {
            nextIndex = forward ? (idx + 1) % count : (idx - 1 + count) % count
        } else {
            nextIndex = 0
        }
        if let url = WallpaperLibrary.shared.getWallpaperURL(for: items[nextIndex]) {
            setBackgroundImage(url: url)
        }
    }

    @MainActor
    private func applyRandomWallpaper() {
        let items = WallpaperLibrary.shared.wallpapers.filter { $0.isDownloaded }
        guard let pick = items.randomElement(),
              let url = WallpaperLibrary.shared.getWallpaperURL(for: pick) else { return }
        setBackgroundImage(url: url)
    }

    @MainActor
    private func switchPlaylist(idString: String) {
        guard let uuid = UUID(uuidString: idString) else {
            // 名前一致もフォールバックとして許容
            if let pl = PlaylistManager.shared.playlists.first(where: { $0.name == idString }) {
                PlaylistManager.shared.start(pl.id)
            } else {
                debugLog("[ArtiaURL] WARN playlist switch: \(idString) が見つかりません")
            }
            return
        }
        PlaylistManager.shared.start(uuid)
    }

    @MainActor
    private func switchProfile(idString: String) {
        guard let preset = ArtiaURLHandler.resolveProfile(id: idString) else {
            debugLog("[ArtiaURL] WARN profile switch: 未知 \(idString)")
            return
        }
        settings.performancePreset = preset
        settings.performanceFrameRate = preset.frameRate
        settings.performanceResolutionScale = preset.resolutionScale
        syncSettingsToEngine()
    }

    @MainActor
    private func applyPropertySet(key: String, value: String) {
        // 代表的なキーのみ対応する。未知キーは UserDefaults に書き込んで無視する。
        switch key {
        case "effect_intensity":
            if let v = Float(value) {
                setEffectIntensity(v)
            }
        case "video_volume":
            if let v = Float(value) {
                videoVolume = max(0, min(1, v))
                settings.videoVolume = videoVolume
            }
        case "performance_preset":
            switchProfile(idString: value)
        default:
            debugLog("[ArtiaURL] property set: 未知キー \(key)=\(value) (UserDefaults へ書き込み)")
            UserDefaults.standard.set(value, forKey: "artia.cli.property.\(key)")
        }
    }
}

// MARK: - Settings Management

extension AppDelegate {

    func loadSettingsFromStorage() {
        debugLog("[AppDelegate] ========================================")
        debugLog("[AppDelegate] UserDefaultsから設定を読み込み中...")

        // シェーダー壁紙は廃止したため、常に透過モードへ戻す
        currentShader = .transparent
        settings.currentShader = ShaderType.transparent.rawValue
        debugLog("[AppDelegate] - シェーダー読み込み: 廃止済みのため transparent に固定")

        effectIntensity = settings.effectIntensity
        debugLog("[AppDelegate] - エフェクト強度読み込み: \(effectIntensity)")

        videoVolume = settings.videoVolume
        debugLog("[AppDelegate] - 動画音量読み込み: \(videoVolume)")

        if let path = settings.backgroundImagePath, !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            backgroundImageURL = URL(fileURLWithPath: path)
            debugLog("[AppDelegate] - 背景画像パス読み込み: \(path)")
        } else {
            if let path = settings.backgroundImagePath, !path.isEmpty {
                debugLog("[AppDelegate] - グローバル背景画像が見つかりません: \(path)")
            } else {
                debugLog("[AppDelegate] - グローバル背景画像パスが未設定です")
            }
        }

        // ディスプレイ固有の壁紙パスを確認
        let displayPaths = settings.displayBackgroundPaths
        displayBackgroundPaths = displayPaths
        if !displayPaths.isEmpty {
            debugLog("[AppDelegate] - ディスプレイ固有の背景: \(displayPaths.count)件")
            for (displayID, path) in displayPaths {
                debugLog("[AppDelegate]   - ディスプレイ \(displayID): \(path)")
                debugLog("[AppDelegate]     ファイル存在: \(FileManager.default.fileExists(atPath: path))")
            }

            // グローバルパスが使えない場合、ディスプレイ固有のパスからプレビュー用に復元
            if backgroundImageURL == nil {
                if let firstPath = displayPaths.values.first(where: { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }) {
                    backgroundImageURL = URL(fileURLWithPath: firstPath)
                    debugLog("[AppDelegate] - ディスプレイ固有パスから背景を復元: \(firstPath)")
                }
            }
        }

        // 自動一時停止（PerformanceMonitor）によって isPaused = true が
        // 保存されたまま残っている可能性があるため、起動時にリセットする。
        isPaused = false
        settings.isPaused = false

        // エフェクト設定を読み込み
        if let config = settings.effectConfiguration {
            effectConfiguration = config
            effectManager.configuration = config
        }

        // Phase 1.2+: effectIntensity 役割再定義に伴うマイグレーション。
        // Why: 旧仕様では intensity=0 で blur/chroma/glitch/bloom/ripple が一括 OFF だった。
        // 新仕様では各エフェクトの enabled フラグのみで判定するため、
        // 「intensity=0 だがエフェクトを有効化していたユーザー」は新仕様だと
        // バックグラウンド画像とのミックスが 0% になり何も乗らなくなる。
        // → 一度きり、enabled なエフェクトがあるのに intensity==0 なら 1.0 に引き上げる。
        migrateEffectIntensityIfNeeded()

        debugLog("[AppDelegate] ========================================")

        // エフェクト設定変更の監視を開始
        startObservingEffectManager()
    }

    /// Phase 1.2+: effectIntensity 役割再定義のためのマイグレーション。
    /// - 旧: intensity > 0 で各種ポストエフェクト (blur/chroma/glitch/bloom/ripple) を一括 ON
    /// - 新: 各エフェクトは <name>.enabled で個別判定し、intensity は最終ミックス比率専用
    /// ユーザーが既に enabled なエフェクトを持ちつつ intensity=0 のままだと
    /// 新仕様でミックス 0% で何も適用されなくなるため、初回起動時に 1.0 へ引き上げる。
    private func migrateEffectIntensityIfNeeded() {
        let key = "artia.effectIntensity.migration.v2.completed"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return }

        if effectIntensity <= 0.0 && effectConfiguration.hasActiveEffects {
            debugLog("[AppDelegate] effectIntensity マイグレーション: 0 → 1.0 (有効エフェクトあり)")
            effectIntensity = 1.0
            settings.effectIntensity = 1.0

            // UI 側で控えめに通知できるよう Notification を投げる（強制モーダルは出さない）。
            NotificationCenter.default.post(
                name: Notification.Name("ArtiaEffectIntensityMigratedV2"),
                object: nil
            )
        }
        defaults.set(true, forKey: key)
    }

    private func startObservingEffectManager() {
        // 既存のObserverがあれば解除
        if let token = effectObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
        // EffectManagerの変更を監視してレンダラーに反映
        effectObserverToken = NotificationCenter.default.addObserver(
            forName: .effectConfigurationChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.syncEffectConfigurationToRenderers()
        }
    }

    /// Observer・リソースを解放
    func applicationWillTerminate(_ notification: Notification) {
        if let token = effectObserverToken {
            NotificationCenter.default.removeObserver(token)
            effectObserverToken = nil
        }
        removeSleepWakeObservers()
    }

    // MARK: - スリープ/復帰ハンドリング

    private func setupSleepWakeObservers() {
        let wsCenter = NSWorkspace.shared.notificationCenter

        // システムスリープ
        sleepObserver = wsCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSuspend(reason: "システムスリープ")
        }

        // システム復帰
        wakeObserver = wsCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            debugLog("[WallBlank] システム復帰検出")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.handleResume(reason: "システム復帰")
            }
        }

        // ディスプレイOFF（ロック画面 / ディスプレイスリープ）
        screensSleepObserver = wsCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSuspend(reason: "ディスプレイスリープ")
        }

        // ディスプレイON
        screensWakeObserver = wsCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            debugLog("[WallBlank] ディスプレイ復帰検出")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.handleResume(reason: "ディスプレイ復帰")
            }
        }

        // セッション非アクティブ（ファストユーザースイッチ / ロック画面）
        sessionResignObserver = wsCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSuspend(reason: "セッション非アクティブ")
        }

        // セッション復帰
        sessionBecomeActiveObserver = wsCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            debugLog("[WallBlank] セッション復帰検出")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.handleResume(reason: "セッション復帰")
            }
        }

        debugLog("[WallBlank] スリープ/ロック/復帰監視を開始")
    }

    private func removeSleepWakeObservers() {
        let wsCenter = NSWorkspace.shared.notificationCenter
        if let token = sleepObserver { wsCenter.removeObserver(token) }
        if let token = wakeObserver { wsCenter.removeObserver(token) }
        if let token = screensSleepObserver { wsCenter.removeObserver(token) }
        if let token = screensWakeObserver { wsCenter.removeObserver(token) }
        if let token = sessionResignObserver { wsCenter.removeObserver(token) }
        if let token = sessionBecomeActiveObserver { wsCenter.removeObserver(token) }
        sleepObserver = nil
        wakeObserver = nil
        screensSleepObserver = nil
        screensWakeObserver = nil
        sessionResignObserver = nil
        sessionBecomeActiveObserver = nil
    }

    /// スリープ/ロック/ディスプレイOFF時の共通一時停止処理
    private func handleSuspend(reason: String) {
        debugLog("[WallBlank] \(reason)検出 → 全レンダリングを一時停止")

        wallpaperEngine?.suspendForSystemEvent(reason: reason)

        // 壁紙エンジンを一時停止
        wallpaperEngine?.pauseAll()

        // エディターのアニメーションを一時停止
        let editorManager = ImageEditorManager.shared
        if let animManager = editorManager.animationManager, animManager.isPlaying {
            editorWasPlayingBeforeSuspend = true
            animManager.pause()
        }
        if let engine = editorManager.wgpuEngine {
            RustCore.wgpuSetPlaying(engine, playing: false)
        }
    }

    /// 復帰/ロック解除/ディスプレイON時の共通復旧処理
    private func handleResume(reason: String) {
        debugLog("[WallBlank] \(reason) → 復旧処理を開始")

        wallpaperEngine?.resumeFromSystemEvent(reason: reason)

        // 壁紙エンジンの復旧
        if !isPaused {
            wallpaperEngine?.resumeAll()
        }
        wallpaperEngine?.forceRedrawAll()

        // エディターのGPUデバイス復旧
        let editorManager = ImageEditorManager.shared
        editorManager.recoverFromDeviceLost()

        // エディターのアニメーション再開（一時停止前に再生中だった場合のみ）
        if editorWasPlayingBeforeSuspend {
            editorWasPlayingBeforeSuspend = false
            editorManager.animationManager?.play()
        }
        if let engine = editorManager.wgpuEngine {
            RustCore.wgpuSetPlaying(engine, playing: true)
        }

        debugLog("[WallBlank] \(reason) → 復旧処理完了")
    }

    private func syncEffectConfigurationToRenderers() {
        let config = effectManager.configuration
        effectConfiguration = config
        settings.effectConfiguration = config

        // レンダラーに設定を反映
        previewRenderer?.updateEffectConfiguration(config)
        hubPreviewRenderer?.updateEffectConfiguration(config)

        // マスクテクスチャも更新
        if let maskData = effectManager.maskData {
            previewRenderer?.updateMaskTexture(from: maskData)
            hubPreviewRenderer?.updateMaskTexture(from: maskData)
        }

        // combinedモードの場合、壁紙エンジンにも反映
        if appMode == .combined {
            wallpaperEngine?.setEffectConfigurationForAll(config)
            if let maskData = effectManager.maskData {
                wallpaperEngine?.setMaskTextureForAll(from: maskData)
            }
        }
    }

    func syncSettingsToEngine() {
        // combinedモードで壁紙エンジンに設定を同期
        guard appMode == .combined else { return }
        settings.currentShader = currentShader.rawValue
        settings.effectIntensity = effectIntensity
        settings.videoVolume = videoVolume
        settings.backgroundImagePath = backgroundImageURL?.path
        settings.isPaused = isPaused
        settings.effectConfiguration = effectConfiguration
    }
}

// MARK: - Engine Management

extension AppDelegate {

    func launchEngineIfNeeded() {
        // 壁紙エンジンが既に実行中か確認
        let runningApps = NSWorkspace.shared.runningApplications
        let engineRunning = runningApps.contains { app in
            app.bundleIdentifier == Bundle.main.bundleIdentifier &&
            app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }

        if !engineRunning {
            debugLog("[Controller] 壁紙エンジンを起動中...")
            launchEngine()
        } else {
            debugLog("[Controller] 壁紙エンジンは既に実行中です")
        }
    }

    private func launchEngine() {
        let appURL = Bundle.main.bundleURL

        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--engine-only"]
        config.activates = false
        config.hides = true
        config.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { app, error in
            if let error = error {
                debugLog("[Controller] エンジンの起動に失敗: \(error)")
            } else {
                debugLog("[Controller] エンジンの起動に成功")
            }
        }
    }
}

// MARK: - Launch Agent Management

extension AppDelegate {

    private var launchAgentURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/LaunchAgents/com.artia.engine.plist")
    }

    func installLaunchAgent() {
        guard let bundlePlistURL = Bundle.main.url(forResource: "com.artia.engine", withExtension: "plist") else {
            debugLog("[LaunchAgent] バンドル内にplistが見つかりません")
            return
        }

        do {
            // LaunchAgentsディレクトリを作成（存在しない場合）
            let launchAgentsDir = launchAgentURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

            // plistをコピー
            if FileManager.default.fileExists(atPath: launchAgentURL.path) {
                try FileManager.default.removeItem(at: launchAgentURL)
            }
            try FileManager.default.copyItem(at: bundlePlistURL, to: launchAgentURL)

            // launchctlで読み込み
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["load", launchAgentURL.path]
            try process.run()
            process.waitUntilExit()

            debugLog("[LaunchAgent] インストール成功")
        } catch {
            debugLog("[LaunchAgent] インストール失敗: \(error)")
        }
    }

    func uninstallLaunchAgent() {
        do {
            // launchctlでアンロード
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["unload", launchAgentURL.path]
            try process.run()
            process.waitUntilExit()

            // plistを削除
            if FileManager.default.fileExists(atPath: launchAgentURL.path) {
                try FileManager.default.removeItem(at: launchAgentURL)
            }

            debugLog("[LaunchAgent] アンインストール成功")
        } catch {
            debugLog("[LaunchAgent] アンインストール失敗: \(error)")
        }
    }

    func isLaunchAgentInstalled() -> Bool {
        return FileManager.default.fileExists(atPath: launchAgentURL.path)
    }
}

// MARK: - Launch at Login

extension AppDelegate {

    func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                debugLog("[LaunchAtLogin] ログイン時起動の切り替えに失敗: \(error)")
            }
        }
    }

    func toggleLaunchAtLogin() {
        setLaunchAtLogin(!isLaunchAtLoginEnabled())
    }

    func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }
}

// MARK: - Wallpaper Actions (UI -> Settings -> Engine)

extension AppDelegate {

    @discardableResult
    func bumpWallpaperSelectionEpoch() -> UInt64 {
        wallpaperSelectionEpoch += 1
        return wallpaperSelectionEpoch
    }

    func isWallpaperSelectionEpochCurrent(_ epoch: UInt64) -> Bool {
        wallpaperSelectionEpoch == epoch
    }

    /// Application Support 内の WallBlank/Wallpapers 配下かどうか
    private func isUnderArtiaWallpapersDirectory(_ url: URL) -> Bool {
        guard let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return false
        }
        let root = appSupportURL
            .appendingPathComponent("WallBlank")
            .appendingPathComponent("Wallpapers")
            .standardizedFileURL
            .path
        let p = url.standardizedFileURL.path
        return p == root || p.hasPrefix(root + "/")
    }

    /// 壁紙ファイルをローカルにコピー（既にWallpapersディレクトリ内の場合はコピーしない）
    private func copyWallpaperToLocal(from sourceURL: URL) -> URL? {
        // Web壁紙フォルダは巨大になりやすい（Workshopは数GBなど）。
        // ここで丸ごとコピーすると「追加できない」ように見える/失敗しやすいので、原本パスをそのまま使う。
        if WallpaperEngineWebResolver.isWebWallpaperRoot(sourceURL) {
            debugLog("[AppDelegate] Web壁紙フォルダはコピーせず原本を使用: \(sourceURL.path)")
            return sourceURL
        }

        // ローカル保存先ディレクトリを作成
        guard let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            debugLog("[AppDelegate] Application Supportディレクトリが見つかりません")
            return nil
        }
        let wallpapersDir = appSupportURL
            .appendingPathComponent("WallBlank")
            .appendingPathComponent("Wallpapers")

        do {
            // ディレクトリが存在しない場合は作成
            try FileManager.default.createDirectory(at: wallpapersDir, withIntermediateDirectories: true)

            // ソースが既にWallpapersディレクトリ内にある場合はコピーをスキップ
            let resolvedSource = sourceURL.standardizedFileURL.path
            let resolvedWallpapersDir = wallpapersDir.standardizedFileURL.path
            if resolvedSource.hasPrefix(resolvedWallpapersDir + "/") {
                debugLog("[AppDelegate] 壁紙は既にローカルディレクトリにあります。コピーをスキップ: \(sourceURL.path)")
                return sourceURL
            }

            // ファイル名を生成（タイムスタンプ付き）
            let timestamp = Date().timeIntervalSince1970
            let fileName = "\(Int(timestamp))_\(sourceURL.lastPathComponent)"
            let destinationURL = wallpapersDir.appendingPathComponent(fileName)

            // ファイルが既に存在する場合は削除
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            // ファイルをコピー
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            debugLog("[AppDelegate] 壁紙をローカルにコピーしました: \(destinationURL.path)")
            return destinationURL

        } catch {
            debugLog("[AppDelegate] 壁紙のコピーに失敗: \(error)")
            return nil
        }
    }

    func togglePause() {
        isPaused.toggle()
        settings.isPaused = isPaused
        performanceMonitor.setUserManuallyPaused(isPaused)
    }

    func selectShader(_ shader: ShaderType) {
        currentShader = shader
        settings.currentShader = shader.rawValue
        previewRenderer?.currentShader = shader
        hubPreviewRenderer?.currentShader = shader
    }

    func selectBackgroundImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = true
        panel.allowsMultipleSelection = false
        // 画像・動画に加え、Wallpaper Engine 形式のフォルダ（project.json / index.html）を選べるようにする
        panel.allowedContentTypes = [
            .image,
            .movie,
            .mpeg4Movie,
            .quickTimeMovie,
            .gif,
            .html,
            .json,
            UTType.folder
        ]

        if panel.runModal() == .OK, let url = panel.url {
            setBackgroundImage(url: url)
        }
    }

    /// 壁紙エンジンと同じプロセスで動いているとき、表示中の Web 壁紙を既定ブラウザで開く。
    @discardableResult
    func openActiveWebWallpaperInDefaultBrowser() -> Bool {
        wallpaperEngine?.openActiveWebWallpaperInDefaultBrowser() ?? false
    }

    func setBackgroundImage(url: URL) {
        bumpWallpaperSelectionEpoch()
        debugLog("[AppDelegate] setBackgroundImage called (mode=\(appMode)) url=\(url.path)")
        // controller モードではエンジン別プロセスが必要
        if appMode == .controller {
            launchEngineIfNeeded()
        }

        let resolvedURL = WallpaperEngineWebResolver.canonicalFilesystemURL(matching: url) ?? url.standardizedFileURL

        // 入力の実在確認（フォルダもOK）
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedURL.path, isDirectory: &isDir) else {
            debugLog("[AppDelegate] 指定されたパスが存在しません: \(url.path) (resolved: \(resolvedURL.path))")
            return
        }

        // ファイルをローカルにコピー（失敗時は元のURLを使用）
        let effectiveURL = copyWallpaperToLocal(from: resolvedURL) ?? resolvedURL
        debugLog("[AppDelegate] effectiveURL=\(effectiveURL.path)")

        backgroundImageURL = effectiveURL
        settings.backgroundImagePath = effectiveURL.path

        if WallpaperEngineWebResolver.isWebWallpaperRoot(effectiveURL) {
            artiaWebLog("[AppDelegate] setBackgroundImage Web root path=\(effectiveURL.path)")
            previewRenderer?.clearBackgroundImage()
            hubPreviewRenderer?.clearBackgroundImage()
        } else {
            previewRenderer?.loadBackground(from: effectiveURL)
            hubPreviewRenderer?.loadBackground(from: effectiveURL)
        }

        // combinedモードの場合、壁紙エンジンに直接反映
        if appMode == .combined {
            wallpaperEngine?.setBackgroundImageForAll(from: effectiveURL)
        }

        // 有効な各ディスプレイに個別に保存
        for displayID in displayManager.enabledDisplayIDs {
            settings.setBackgroundImagePath(effectiveURL.path, for: displayID)
        }

        SharedSettingsManager.shared.flushSharedDefaultsForIPC()
        if appMode == .controller {
            scheduleRepostBackgroundImageChangedForEngine(path: effectiveURL.path)
        }

        // ウィジェットデータを更新
        refreshWidgetData()

        syncLibraryAfterBackgroundChange(effectiveURL: effectiveURL)
    }

    /// エンジン起動直後は Distributed 通知や共有 defaults の反映が遅れることがあるため再送する
    private func scheduleRepostBackgroundImageChangedForEngine(path: String) {
        guard !path.isEmpty else { return }
        let pathCopy = path
        for delay in [0.55, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, self.appMode == .controller else { return }
                // controller→engine の別プロセス IPC のため DNC を保持。EventBus は同一プロセス内のみ。
                DistributedNotificationCenter.default().postNotificationName(
                    WallpaperNotifications.backgroundImageChanged,
                    object: nil,
                    userInfo: ["path": pathCopy],
                    deliverImmediately: true
                )
                debugLog("[AppDelegate] Delayed IPC: backgroundImageChanged reposted for engine (+\(delay)s)")
            }
        }
    }

    private func scheduleRepostDisplayBackgroundImageChangedForEngine(path: String, displayID: String) {
        let pathCopy = path
        let displayIDCopy = displayID
        for delay in [0.55, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, self.appMode == .controller else { return }
                // controller→engine の別プロセス IPC のため DNC を保持。
                DistributedNotificationCenter.default().postNotificationName(
                    WallpaperNotifications.displayBackgroundImageChanged,
                    object: nil,
                    userInfo: [
                        "path": pathCopy,
                        "displayID": displayIDCopy
                    ],
                    deliverImmediately: true
                )
                debugLog("[AppDelegate] Delayed IPC: displayBackgroundImageChanged reposted for engine (+\(delay)s)")
            }
        }
    }

    /// 特定のディスプレイに壁紙を設定
    func setBackgroundImage(url: URL, for displayID: String) {
        bumpWallpaperSelectionEpoch()
        debugLog("[AppDelegate] setBackgroundImage(for display) displayID=\(displayID) url=\(url.path)")
        if appMode == .controller {
            launchEngineIfNeeded()
        }

        let resolvedURL = WallpaperEngineWebResolver.canonicalFilesystemURL(matching: url) ?? url.standardizedFileURL

        // ファイルをローカルにコピー
        guard let localURL = copyWallpaperToLocal(from: resolvedURL) else {
            debugLog("[AppDelegate] ディスプレイ \(displayID) への壁紙コピーに失敗、元のパスを使用します")
            // 元のパスで続行
            if appMode == .combined {
                wallpaperEngine?.setBackgroundImage(from: resolvedURL, for: displayID)
            }
            settings.setBackgroundImagePath(resolvedURL.path, for: displayID)
            displayBackgroundPaths = settings.displayBackgroundPaths
            SharedSettingsManager.shared.flushSharedDefaultsForIPC()
            if appMode == .controller {
                scheduleRepostDisplayBackgroundImageChangedForEngine(path: resolvedURL.path, displayID: displayID)
            }
            syncLibraryAfterBackgroundChange(effectiveURL: resolvedURL)
            return
        }

        // combinedモードの場合、壁紙エンジンに直接反映
        if appMode == .combined {
            wallpaperEngine?.setBackgroundImage(from: localURL, for: displayID)
        }

        if WallpaperEngineWebResolver.isWebWallpaperRoot(localURL) {
            previewRenderer?.clearBackgroundImage()
            hubPreviewRenderer?.clearBackgroundImage()
        } else {
            previewRenderer?.loadBackground(from: localURL)
            hubPreviewRenderer?.loadBackground(from: localURL)
        }

        // 設定を保存（ローカルパス）
        settings.setBackgroundImagePath(localURL.path, for: displayID)
        displayBackgroundPaths = settings.displayBackgroundPaths
        debugLog("[AppDelegate] ディスプレイ \(displayID) に壁紙を保存: \(localURL.path)")

        SharedSettingsManager.shared.flushSharedDefaultsForIPC()
        if appMode == .controller {
            scheduleRepostDisplayBackgroundImageChangedForEngine(path: localURL.path, displayID: displayID)
        }

        syncLibraryAfterBackgroundChange(effectiveURL: localURL)
    }

    /// ライブラリ一覧をディスク内容と一致させる（追加直後にギャラリへ反映）
    private func syncLibraryAfterBackgroundChange(effectiveURL: URL) {
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: effectiveURL.path, isDirectory: &isDir)
        if isDir.boolValue,
           !isUnderArtiaWallpapersDirectory(effectiveURL),
           WallpaperEngineWebResolver.isWebWallpaperRoot(effectiveURL) {
            WallpaperLibrary.shared.registerExternalWebWallpaperRoot(effectiveURL)
        }
        WallpaperLibrary.shared.loadWallpapers()
    }

    func clearBackgroundImage() {
        bumpWallpaperSelectionEpoch()
        backgroundImageURL = nil
        settings.backgroundImagePath = nil
        settings.clearAllDisplayBackgroundPaths()
        displayBackgroundPaths = [:]
        previewRenderer?.clearBackgroundImage()
        hubPreviewRenderer?.clearBackgroundImage()

        // combinedモードの場合、壁紙エンジンに直接反映
        if appMode == .combined {
            wallpaperEngine?.clearBackgroundImageForAll()
        }
    }

    /// 壁紙を完全にクリアして透過モードに移行（macOSデスクトップの壁紙を表示）
    func clearAndEnableTransparentMode() {
        bumpWallpaperSelectionEpoch()
        backgroundImageURL = nil
        settings.backgroundImagePath = nil
        settings.clearAllDisplayBackgroundPaths()
        displayBackgroundPaths = [:]

        // 透過モードに移行
        previewRenderer?.enableTransparentMode()
        hubPreviewRenderer?.enableTransparentMode()

        if appMode == .combined {
            wallpaperEngine?.enableTransparentModeForAll()
        }
    }

    /// 特定のディスプレイの壁紙をクリア
    func clearBackgroundImage(for displayID: String) {
        bumpWallpaperSelectionEpoch()
        // combinedモードの場合、壁紙エンジンに直接反映
        if appMode == .combined {
            wallpaperEngine?.clearBackgroundImage(for: displayID)
        }

        // 設定を保存
        settings.setBackgroundImagePath(nil, for: displayID)
        displayBackgroundPaths = settings.displayBackgroundPaths
    }

    func setEffectIntensity(_ intensity: Float) {
        effectIntensity = intensity
        settings.effectIntensity = intensity
        previewRenderer?.effectIntensity = intensity
        hubPreviewRenderer?.effectIntensity = intensity

        // combinedモードの場合、壁紙エンジンに直接反映
        if appMode == .combined {
            wallpaperEngine?.setEffectIntensityForAll(intensity)
        }
    }

    func setVideoVolume(_ volume: Float) {
        videoVolume = volume
        settings.videoVolume = volume
        previewRenderer?.volume = volume
        hubPreviewRenderer?.volume = volume

        // combinedモードの場合、壁紙エンジンに直接反映
        if appMode == .combined {
            wallpaperEngine?.setVolumeForAll(volume)
        }
    }

    func setEffectConfiguration(_ config: EffectConfiguration) {
        effectConfiguration = config
        effectManager.configuration = config
        settings.effectConfiguration = config

        previewRenderer?.updateEffectConfiguration(config)
        hubPreviewRenderer?.updateEffectConfiguration(config)

        // combinedモードの場合、壁紙エンジンに直接反映
        if appMode == .combined {
            wallpaperEngine?.setEffectConfigurationForAll(config)
        }
    }

    func updateMaskTexture(from maskData: MaskData) {
        previewRenderer?.updateMaskTexture(from: maskData)
        hubPreviewRenderer?.updateMaskTexture(from: maskData)

        // combinedモードの場合、壁紙エンジンに直接反映
        if appMode == .combined {
            wallpaperEngine?.setMaskTextureForAll(from: maskData)
        }
    }

    func clearMaskTexture() {
        previewRenderer?.clearMaskTexture()
        hubPreviewRenderer?.clearMaskTexture()

        // combinedモードの場合、壁紙エンジンに直接反映
        if appMode == .combined {
            wallpaperEngine?.clearMaskTextureForAll()
        }
    }
}

// MARK: - Window Management (Preview / Hub)

extension AppDelegate {

    /// Rendererを初期化し、現在の設定を反映する共通ヘルパー
    func configureRenderer(_ renderer: Renderer, overrideVolume: Float? = nil) {
        renderer.currentShader = currentShader
        renderer.effectIntensity = effectIntensity
        renderer.volume = overrideVolume ?? videoVolume
        renderer.updateEffectConfiguration(effectConfiguration)

        if let bgURL = backgroundImageURL {
            if WallpaperEngineWebResolver.isWebWallpaperRoot(bgURL) {
                renderer.clearBackgroundImage()
            } else {
                renderer.loadBackground(from: bgURL)
            }
        }

        if let maskData = effectManager.maskData {
            renderer.updateMaskTexture(from: maskData)
        }
    }

    func showPreviewWindow() {
        if let existingWindow = previewWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let device = MTLCreateSystemDefaultDevice() else {
            debugLog("[Metal] Metalがサポートされていません")
            return
        }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            debugLog("[AppDelegate] 利用可能な画面がありません")
            return
        }
        let screenAspect = screen.frame.width / screen.frame.height
        let previewWidth: CGFloat = 600
        let previewHeight = previewWidth / screenAspect

        let tempView = MTKView(frame: NSRect(x: 0, y: 0, width: previewWidth, height: previewHeight), device: device)
        tempView.colorPixelFormat = .bgra8Unorm
        previewRenderer = Renderer(metalView: tempView)

        guard let renderer = previewRenderer else {
            debugLog("[AppDelegate] プレビューレンダラーの作成に失敗しました")
            return
        }

        configureRenderer(renderer)

        let contentView = PreviewWindowContent(
            appDelegate: self,
            previewRenderer: renderer,
            device: device
        )

        let hostingView = NSHostingView(rootView: contentView)

        let windowWidth = previewWidth + 60
        let windowHeight = previewHeight + 200

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()
        window.contentView = hostingView
        window.isReleasedWhenClosed = false

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.previewWindow = nil
            self?.previewRenderer = nil
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        previewWindow = window
    }

    func closePreviewWindow() {
        previewWindow?.close()
        previewWindow = nil
        previewRenderer = nil
    }

    @MainActor
    func showLockScreenWindow() {
        if let existingWindow = lockScreenWindow {
            setLockScreenMuted(true)
            existingWindow.orderFrontRegardless()
            existingWindow.makeKey()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let device = MTLCreateSystemDefaultDevice() else {
            debugLog("[Metal] Metalがサポートされていません")
            return
        }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            debugLog("[AppDelegate] ロック画面を表示できる画面がありません")
            return
        }

        let tempView = MTKView(frame: screen.frame, device: device)
        tempView.colorPixelFormat = .bgra8Unorm
        lockScreenRenderer = Renderer(metalView: tempView)

        guard let renderer = lockScreenRenderer else {
            debugLog("[AppDelegate] ロック画面レンダラーの作成に失敗しました")
            return
        }

        configureRenderer(renderer, overrideVolume: 0)
        setLockScreenMuted(true)

        let contentView = LockScreenWindowContent(
            appLockManager: AppLockManager.shared,
            previewRenderer: renderer,
            device: device
        )

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = screen.frame

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.setFrame(screen.frame, display: true)
        window.contentView = hostingView
        window.isReleasedWhenClosed = false

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.lockScreenWindow = nil
            self?.lockScreenRenderer = nil
            MainActor.assumeIsolated {
                if AppLockManager.shared.isLocked == false {
                    self?.setLockScreenMuted(false)
                }
            }
        }

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)

        lockScreenWindow = window
    }

    func closeLockScreenWindow() {
        if let window = lockScreenWindow {
            window.close()
        }
        lockScreenWindow = nil
        lockScreenRenderer = nil
        setLockScreenMuted(false)
    }

    func setLockScreenMuted(_ muted: Bool) {
        let targetVolume: Float = muted ? 0 : videoVolume

        previewRenderer?.volume = targetVolume
        hubPreviewRenderer?.volume = targetVolume

        switch appMode {
        case .combined:
            wallpaperEngine?.setVolumeForAll(targetVolume)
        case .controller:
            // controller→engine の別プロセス IPC のため DNC を保持。
            DistributedNotificationCenter.default().postNotificationName(
                WallpaperNotifications.videoVolumeChanged,
                object: nil,
                userInfo: ["volume": targetVolume],
                deliverImmediately: true
            )
        case .engine:
            break
        }
    }

    func showMainHubWindow() {
        if let existingWindow = mainHubWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let device = MTLCreateSystemDefaultDevice() else {
            debugLog("[Metal] Metalがサポートされていません")
            return
        }

        // プレビュー用レンダラーを作成
        let tempView = MTKView(frame: NSRect(x: 0, y: 0, width: 160, height: 90), device: device)
        tempView.colorPixelFormat = .bgra8Unorm
        hubPreviewRenderer = Renderer(metalView: tempView)

        if let renderer = hubPreviewRenderer {
            configureRenderer(renderer)
        }

        let contentView = MainHubWindowContent(
            appDelegate: self,
            library: WallpaperLibrary.shared,
            previewRenderer: hubPreviewRenderer,
            device: device
        )

        let hostingView = NSHostingView(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = "WallBlank"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = true
        window.center()
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 450)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.mainHubWindow = nil
            self?.hubPreviewRenderer = nil
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        mainHubWindow = window
    }

    func closeMainHubWindow() {
        mainHubWindow?.close()
        mainHubWindow = nil
        hubPreviewRenderer = nil
    }
}

// MARK: - Widget Integration

extension AppDelegate {

    /// ウィジェットからの通知を監視開始
    /// Why: WallpaperHubWidget Extension は別プロセスのため EventBus では届かず、DNC を残す。
    func startObservingWidgetIntents() {
        let center = DistributedNotificationCenter.default()

        center.addObserver(
            forName: NSNotification.Name("com.artia.widget.nextWallpaper"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            ScheduleManager.shared.advanceNow()
            self?.refreshWidgetData()
        }

        center.addObserver(
            forName: NSNotification.Name("com.artia.widget.setWallpaper"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let wallpaperID = notification.userInfo?["wallpaperID"] as? String else { return }
            if let item = WallpaperLibrary.shared.wallpapers.first(where: { $0.id == wallpaperID }),
               let url = WallpaperLibrary.shared.getWallpaperURL(for: item) {
                self?.setBackgroundImage(url: url)
                self?.refreshWidgetData()
            }
        }

        center.addObserver(
            forName: NSNotification.Name("com.artia.widget.toggleSchedule"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let manager = ScheduleManager.shared
            if manager.isScheduleActive {
                manager.stopSchedule()
            } else if let firstSchedule = manager.schedules.first(where: { $0.isEnabled }) {
                manager.startSchedule(firstSchedule.id)
            }
            self?.refreshWidgetData()
        }
    }

    /// ウィジェットデータを更新してタイムラインをリロード
    func refreshWidgetData() {
        // 現在の壁紙情報を更新
        let currentName: String
        let currentThumbnailPath: String?
        let currentType: String

        if let bgURL = backgroundImageURL {
            let item = WallpaperLibrary.shared.wallpapers.first { item in
                WallpaperLibrary.shared.getWallpaperURL(for: item)?.path == bgURL.path
            }
            currentName = item?.name ?? bgURL.deletingPathExtension().lastPathComponent
            currentThumbnailPath = item.flatMap { WallpaperLibrary.shared.getThumbnailPath(for: $0) }
            currentType = item?.type.rawValue ?? "image"
        } else {
            currentName = "壁紙未設定"
            currentThumbnailPath = nil
            currentType = "image"
        }

        WidgetDataProvider.updateCurrentWallpaper(
            name: currentName,
            thumbnailPath: currentThumbnailPath,
            type: currentType
        )

        // お気に入りを更新
        let library = WallpaperLibrary.shared
        let favCollection = library.favoritesCollection
        let favItems: [WidgetWallpaperInfo] = favCollection.wallpaperIDs.compactMap { id in
            guard let item = library.wallpapers.first(where: { $0.id == id }) else { return nil }
            return WidgetWallpaperInfo(
                id: item.id,
                name: item.name,
                thumbnailPath: library.getThumbnailPath(for: item),
                type: item.type.rawValue
            )
        }
        WidgetDataProvider.updateFavorites(Array(favItems.prefix(6)))

        // スケジュール状態を更新
        let scheduleManager = ScheduleManager.shared
        WidgetDataProvider.updateScheduleState(
            isActive: scheduleManager.isScheduleActive,
            nextRotation: scheduleManager.nextRotationDate,
            scheduleName: scheduleManager.schedules.first(where: { $0.id == scheduleManager.activeScheduleID })?.name
        )

        // ウィジェットタイムラインをリロード
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: - ローカル通知（デスクトップ表示の案内）

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        MacOSDesktopClickRevealAdvice.handleNotificationResponse(response)
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
