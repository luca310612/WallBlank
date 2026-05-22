import Cocoa
import MetalKit

/// WallBlank - 複数ディスプレイ対応
class WallpaperEngine {
    private struct InitialWallpaperAssignment {
        let displayID: String
        let resolvedURL: URL?
    }

    private struct InitialSettingsSnapshot {
        let shader: ShaderType
        let intensity: Float
        let globalBackgroundPath: String?
        let displayBackgroundPaths: [String: String]
        let isPaused: Bool
        let preset: PerformancePreset
        let frameRate: Int
        let resolutionScale: Float
        let webWallpaperScale: Float
        let effectConfig: EffectConfiguration?
    }

    private var displayInstances: [String: DisplayWallpaperInstance] = [:]
    private var detachedDisplayCache: [String: DisplayWallpaperInstance] = [:]
    private var displayIDToName: [String: String] = [:]  // 実際のIDから表示名へのマッピング
    private var nextDisplayNumber: Int = 1  // 次に割り当てる連番
    private let startupRestoreQueue = DispatchQueue(label: "com.artia.engine.startup-restore", qos: .userInitiated)
    private var startupRestoreGeneration: UInt64 = 0

    private let settings: SettingsManagerProtocol
    private let displayManager: any DisplayManagerProtocol

    init(
        settings: SettingsManagerProtocol = SharedSettingsManager.shared,
        displayManager: any DisplayManagerProtocol = DisplayManager.shared
    ) {
        self.settings = settings
        self.displayManager = displayManager
        setupWallpaperWindows()
        startListeningForSettings()
        loadInitialSettingsAsync()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - セットアップ

    private func setupWallpaperWindows() {
        debugLog("[Engine] 壁紙エンジンを起動中...")

        let currentScreens = currentScreenMap()
        let enabledIDs = targetDisplayIDs(currentScreens: currentScreens)

        for displayID in enabledIDs {
            if let screen = currentScreens[displayID] {
                createInstance(for: displayID, screen: screen)
            }
        }

        // 画面変更の監視
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        debugLog("[Engine] \(displayInstances.count)個の壁紙インスタンスを作成")
    }

    /// ディスプレイIDを文字列として取得
    private func displayIDString(for screen: NSScreen) -> String {
        if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            return String(displayID)
        }
        return "unknown"
    }

    private func currentScreenMap() -> [String: NSScreen] {
        var screens: [String: NSScreen] = [:]
        for screen in NSScreen.screens {
            screens[displayIDString(for: screen)] = screen
        }
        return screens
    }

    /// DisplayManager の初回起動時は、保存済み有効ディスプレイが空なら全接続ディスプレイを有効化する。
    /// Engine 側も同じ解釈にし、保存通知の到着順でメイン画面だけに固定される競合を避ける。
    private func targetDisplayIDs(currentScreens: [String: NSScreen]? = nil) -> Set<String> {
        let savedIDs = Set(settings.enabledDisplayIDs)
        if !savedIDs.isEmpty { return savedIDs }

        let screens = currentScreens ?? currentScreenMap()
        let connectedIDs = Set(screens.keys)
        if !connectedIDs.isEmpty {
            debugLog("[Engine] 有効ディスプレイ設定が空のため、接続中の全ディスプレイを対象にします: \(Array(connectedIDs))")
        }
        return connectedIDs
    }

    /// インスタンスを作成
    private func createInstance(for displayID: String, screen: NSScreen) {
        guard displayInstances[displayID] == nil else {
            let displayName = displayIDToName[displayID] ?? "不明"
            debugLog("[Engine] \(displayName) のインスタンスは既に存在します")
            return
        }

        if let cached = detachedDisplayCache.removeValue(forKey: displayID) {
            displayInstances[displayID] = cached
            cached.reattach(to: screen, reason: "display reconnected")
            cached.refreshDisplayArrangement()
            let displayName = displayIDToName[displayID] ?? "不明"
            debugLog("[Engine] \(displayName) のキャッシュ済みインスタンスを再利用")
            return
        }

        // 新しい表示名を生成
        let displayName = "display\(nextDisplayNumber)"
        nextDisplayNumber += 1
        displayIDToName[displayID] = displayName

        let instance = DisplayWallpaperInstance(
            displayID: displayID,
            screen: screen,
            settings: settings,
            displays: displayManager
        )
        displayInstances[displayID] = instance
        instance.refreshDisplayArrangement()
        debugLog("[Engine] \(displayName) のインスタンスを作成")
    }

    /// インスタンスを削除
    private func removeInstance(for displayID: String, preserveCachedState: Bool = false) {
        if let instance = displayInstances.removeValue(forKey: displayID) {
            let displayName = displayIDToName[displayID] ?? "不明"
            if preserveCachedState {
                detachedDisplayCache[displayID] = instance
                instance.detachForDisplaySleepOrRemoval(reason: "display disconnected")
                debugLog("[Engine] \(displayName) のインスタンスをキャッシュ退避")
                return
            }

            displayIDToName.removeValue(forKey: displayID)
            instance.destroy()
            debugLog("[Engine] \(displayName) のインスタンスを削除")
            return
        }

        if let cached = detachedDisplayCache.removeValue(forKey: displayID) {
            let displayName = displayIDToName.removeValue(forKey: displayID) ?? "不明"
            cached.destroy()
            debugLog("[Engine] \(displayName) のキャッシュ済みインスタンスを削除")
        }
    }

    // MARK: - 画面変更

    @objc private func screenParametersDidChange(_ notification: Notification) {
        debugLog("[Engine] 画面パラメータが変更されました")

        // 現在のスクリーンIDを取得
        let currentScreenIDs = currentScreenMap()
        let targetIDs = targetDisplayIDs(currentScreens: currentScreenIDs)

        // 切断または無効化されたディスプレイのインスタンスを削除
        for displayID in displayInstances.keys {
            if currentScreenIDs[displayID] == nil {
                removeInstance(for: displayID, preserveCachedState: true)
            } else if !targetIDs.contains(displayID) {
                removeInstance(for: displayID)
            }
        }

        // 既存インスタンスのフレームを更新
        for (displayID, instance) in displayInstances {
            if let screen = currentScreenIDs[displayID] {
                instance.updateFrame(for: screen)
            }
        }

        // 新しいディスプレイのインスタンスを作成
        for displayID in targetIDs {
            if displayInstances[displayID] == nil,
               let screen = currentScreenIDs[displayID] {
                createInstance(for: displayID, screen: screen)
                applyCurrentSettings(to: displayID)
            }
        }

        refreshDisplayArrangementForAll()
    }

    // MARK: - 設定

    /// 保存済みパスと実ファイルの Unicode 表記の差を吸収（例: フォルダ名「のコピー」の NFC/NFD）
    private func urlResolvingFilesystemUnicode(path: String) -> URL {
        let decoded = path.removingPercentEncoding ?? path
        let u = URL(fileURLWithPath: decoded).standardizedFileURL
        return WallpaperEngineWebResolver.canonicalFilesystemURL(matching: u) ?? u
    }

    private func loadInitialSettingsAsync() {
        let snapshot = InitialSettingsSnapshot(
            shader: ShaderType(rawValue: settings.currentShader) ?? .transparent,
            intensity: settings.effectIntensity,
            globalBackgroundPath: settings.backgroundImagePath,
            displayBackgroundPaths: settings.displayBackgroundPaths,
            isPaused: settings.isPaused,
            preset: settings.performancePreset,
            frameRate: settings.performanceFrameRate,
            resolutionScale: settings.performanceResolutionScale,
            webWallpaperScale: settings.webWallpaperScale,
            effectConfig: settings.effectConfiguration
        )
        startupRestoreGeneration &+= 1
        let generation = startupRestoreGeneration

        debugLog("[Engine] ========================================")
        debugLog("[Engine] UserDefaultsから初期設定を読み込み中...")
        debugLog("[Engine] - シェーダー: \(snapshot.shader)")
        debugLog("[Engine] - エフェクト強度: \(snapshot.intensity)")
        debugLog("[Engine] - グローバル壁紙: \(snapshot.globalBackgroundPath ?? "未設定")")
        debugLog("[Engine] - ディスプレイ別壁紙数: \(snapshot.displayBackgroundPaths.count)")
        for (displayID, path) in snapshot.displayBackgroundPaths {
            debugLog("[Engine]   - 保存済みディスプレイID: '\(displayID)' -> \(path)")
        }
        debugLog("[Engine] - アクティブインスタンス数: \(displayInstances.count)")
        for displayID in displayInstances.keys {
            debugLog("[Engine]   - アクティブディスプレイID: '\(displayID)'")
        }
        debugLog("[Engine] - 一時停止: \(snapshot.isPaused)")
        debugLog("[Engine] - パフォーマンスプリセット: \(snapshot.preset.displayName)")
        debugLog("[Engine] ========================================")

        for (displayID, instance) in displayInstances {
            debugLog("[Engine] ディスプレイ '\(displayID)' を処理中...")
            instance.setShader(snapshot.shader)
            instance.setEffectIntensity(snapshot.intensity)
            instance.setVolume(settings.videoVolume)
            instance.setWebWallpaperScale(snapshot.webWallpaperScale)
            instance.applyPerformanceSettings(
                preset: snapshot.preset,
                frameRate: snapshot.frameRate,
                resolutionScale: snapshot.resolutionScale
            )

            // エフェクト設定を適用
            if let config = snapshot.effectConfig {
                instance.setEffectConfiguration(config)
            }
        }

        let activeDisplayIDs = Array(displayInstances.keys)
        debugLog("[Engine] 初期の軽量設定を \(activeDisplayIDs.count) 個のインスタンスに適用完了。壁紙復元は非同期で継続")

        startupRestoreQueue.async { [weak self] in
            guard let self else { return }
            let assignments = self.prepareInitialWallpaperAssignments(
                for: activeDisplayIDs,
                displayBackgroundPaths: snapshot.displayBackgroundPaths,
                globalBackgroundPath: snapshot.globalBackgroundPath
            )

            DispatchQueue.main.async { [weak self] in
                guard let self, self.startupRestoreGeneration == generation else { return }
                self.applyInitialWallpaperAssignments(assignments, isPaused: snapshot.isPaused)
            }
        }
    }

    private func prepareInitialWallpaperAssignments(
        for displayIDs: [String],
        displayBackgroundPaths: [String: String],
        globalBackgroundPath: String?
    ) -> [InitialWallpaperAssignment] {
        debugLog("[Engine] 非同期で初期壁紙の復元対象を解決中...")
        debugLog("[Engine] 保存済みディスプレイID一覧: \(Array(displayBackgroundPaths.keys))")

        return displayIDs.map { displayID in
            debugLog("[Engine] ディスプレイ '\(displayID)' の壁紙を検索中...")
            if let displayPath = displayBackgroundPaths[displayID], !displayPath.isEmpty {
                let fileURL = urlResolvingFilesystemUnicode(path: displayPath)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    return InitialWallpaperAssignment(displayID: displayID, resolvedURL: fileURL)
                }
                debugLog("[Engine] ✗ ディスプレイ固有の壁紙ファイルが見つかりません \(displayID): \(fileURL.path)")
                return InitialWallpaperAssignment(displayID: displayID, resolvedURL: nil)
            }

            if let path = globalBackgroundPath, !path.isEmpty {
                let url = urlResolvingFilesystemUnicode(path: path)
                if FileManager.default.fileExists(atPath: url.path) {
                    return InitialWallpaperAssignment(displayID: displayID, resolvedURL: url)
                }
                debugLog("[Engine] ✗ グローバル壁紙ファイルが見つかりません: \(url.path)")
                return InitialWallpaperAssignment(displayID: displayID, resolvedURL: nil)
            }

            debugLog("[Engine] - 壁紙が未設定: \(displayID)")
            return InitialWallpaperAssignment(displayID: displayID, resolvedURL: nil)
        }
    }

    private func applyInitialWallpaperAssignments(
        _ assignments: [InitialWallpaperAssignment],
        isPaused: Bool
    ) {
        debugLog("[Engine] 非同期の初期壁紙復元を開始")

        for assignment in assignments {
            guard let instance = displayInstances[assignment.displayID] else { continue }
            if let url = assignment.resolvedURL {
                instance.setBackgroundImage(from: url)
                debugLog("[Engine] ✓ 初期壁紙を適用 \(assignment.displayID): \(url.path)")
            } else {
                debugLog("[Engine] - 初期壁紙の適用をスキップ: \(assignment.displayID)")
            }

            if isPaused {
                instance.pause()
            }
        }

        debugLog("[Engine] 初期設定の非同期復元が完了")
    }

    private func applyCurrentSettings(to displayID: String) {
        guard let instance = displayInstances[displayID] else { return }

        debugLog("[Engine] ディスプレイ \(displayID) に現在の設定を適用中")

        if let shader = ShaderType(rawValue: settings.currentShader) {
            instance.setShader(shader)
        }

        instance.setEffectIntensity(settings.effectIntensity)
        instance.setVolume(settings.videoVolume)
        instance.setWebWallpaperScale(settings.webWallpaperScale)
        instance.applyPerformanceSettings(
            preset: settings.performancePreset,
            frameRate: settings.performanceFrameRate,
            resolutionScale: settings.performanceResolutionScale
        )

        // エフェクト設定を適用
        if let config = settings.effectConfiguration {
            instance.setEffectConfiguration(config)
        }

        // ディスプレイ固有の壁紙を優先、なければグローバル設定を使用
        if let displayPath = settings.backgroundImagePath(for: displayID), !displayPath.isEmpty {
            let fileURL = urlResolvingFilesystemUnicode(path: displayPath)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                instance.setBackgroundImage(from: fileURL)
                debugLog("[Engine] ✓ ディスプレイ固有の壁紙を適用: \(fileURL.path)")
            } else {
                debugLog("[Engine] ✗ ディスプレイ固有の壁紙ファイルが見つかりません: \(fileURL.path)")
            }
        } else if let path = settings.backgroundImagePath, !path.isEmpty {
            let fileURL = urlResolvingFilesystemUnicode(path: path)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                instance.setBackgroundImage(from: fileURL)
                debugLog("[Engine] ✓ グローバル壁紙を適用: \(fileURL.path)")
            } else {
                debugLog("[Engine] ✗ グローバル壁紙ファイルが見つかりません: \(fileURL.path)")
            }
        } else {
            debugLog("[Engine] - 壁紙が未設定")
        }

        if settings.isPaused {
            instance.pause()
        }
    }

    private func startListeningForSettings() {
        settings.startObserving { [weak self] name, userInfo in
            guard let self = self else { return }

            switch name {
            case WallpaperNotifications.shaderChanged:
                if let shaderIndex = userInfo?["shader"] as? Int,
                   let shader = ShaderType(rawValue: shaderIndex) {
                    self.setShaderForAll(shader)
                    debugLog("[Engine] シェーダーを変更: \(shader)")
                }

            case WallpaperNotifications.intensityChanged:
                if let intensity = userInfo?["intensity"] as? Float {
                    self.setEffectIntensityForAll(intensity)
                    debugLog("[Engine] エフェクト強度を変更: \(intensity)")
                }

            case WallpaperNotifications.videoVolumeChanged:
                if let volume = userInfo?["volume"] as? Float {
                    self.setVolumeForAll(volume)
                    debugLog("[Engine] 動画音量を変更: \(volume)")
                }

            case WallpaperNotifications.backgroundImageChanged:
                // userInfoからパスを取得、なければ設定から読み取る
                let path: String?
                if let infoPath = userInfo?["path"] as? String {
                    path = infoPath
                } else {
                    // フォールバック: 設定から直接読み取る
                    path = self.settings.backgroundImagePath
                    debugLog("[Engine] userInfoの壁紙パスがnil、設定から読み取り")
                }

                if let path = path {
                    if path.isEmpty {
                        self.clearBackgroundImageForAll()
                        debugLog("[Engine] 背景画像をクリア")
                    } else {
                        let url = self.urlResolvingFilesystemUnicode(path: path)
                        // フォルダまたはファイルを設定（DisplayWallpaperInstanceで自動判別）
                        self.setBackgroundImageForAll(from: url)

                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                            if isDir.boolValue {
                                debugLog("[Engine] 壁紙フォルダを変更: \(url.path)")
                            } else {
                                debugLog("[Engine] 壁紙を変更: \(url.path)")
                            }
                        }
                    }
                }

            case WallpaperNotifications.pauseStateChanged:
                if let paused = userInfo?["paused"] as? Bool {
                    if paused {
                        self.pauseAll()
                    } else {
                        self.resumeAll()
                    }
                    debugLog("[Engine] 一時停止状態を変更: \(paused)")
                }

            case WallpaperNotifications.displaysChanged:
                self.handleDisplaysChanged()

            case WallpaperNotifications.displayRemoved:
                self.handleDisplayRemoved()

            case WallpaperNotifications.performancePresetChanged:
                if let presetRaw = userInfo?["preset"] as? Int,
                   let preset = PerformancePreset(rawValue: presetRaw) {
                    let frameRate = self.intValue(from: userInfo?["frameRate"]) ?? self.settings.performanceFrameRate
                    let resolutionScale = self.floatValue(from: userInfo?["resolutionScale"]) ?? self.settings.performanceResolutionScale
                    self.applyPerformanceSettingsForAll(
                        preset,
                        frameRate: frameRate,
                        resolutionScale: resolutionScale
                    )
                    debugLog("[Engine] パフォーマンスプリセットを変更: \(preset.displayName)")
                }

            case WallpaperNotifications.performanceTuningChanged:
                let frameRate = self.intValue(from: userInfo?["frameRate"]) ?? self.settings.performanceFrameRate
                let resolutionScale = self.floatValue(from: userInfo?["resolutionScale"]) ?? self.settings.performanceResolutionScale
                self.applyPerformanceSettingsForAll(
                    self.settings.performancePreset,
                    frameRate: frameRate,
                    resolutionScale: resolutionScale
                )
                debugLog("[Engine] パフォーマンス値を変更: \(frameRate)fps / \(Int(resolutionScale * 100))%")

            case WallpaperNotifications.effectConfigurationChanged:
                if let config = self.settings.effectConfiguration {
                    self.setEffectConfigurationForAll(config)
                    debugLog("[Engine] エフェクト設定を変更")
                }

            case WallpaperNotifications.webWallpaperScaleChanged:
                if let scale = userInfo?["scale"] as? Float {
                    self.setWebWallpaperScaleForAll(scale)
                    debugLog("[Engine] Web壁紙の倍率を変更: \(scale)")
                }

            case WallpaperNotifications.desktopItemsClickableChanged:
                if let enabled = userInfo?["enabled"] as? Bool {
                    self.setDesktopItemsClickableForAll(enabled)
                    debugLog("[Engine] デスクトップ項目のクリック透過を変更: \(enabled)")
                }

            case WallpaperNotifications.webWallpaperDisplaySyncChanged:
                if let rootPath = userInfo?["rootPath"] as? String {
                    let rootURL = self.urlResolvingFilesystemUnicode(path: rootPath)
                    self.reloadWebWallpaperDisplaySync(for: rootURL)
                    debugLog("[Engine] Web壁紙の display 同期設定を再読み込み: \(rootURL.path)")
                }

            case WallpaperNotifications.displayArrangementChanged,
                 WallpaperNotifications.spanWallpaperAcrossDisplaysChanged:
                self.refreshDisplayArrangementForAll()
                debugLog("[Engine] ディスプレイ配置設定を更新")

            case WallpaperNotifications.displayBackgroundImageChanged:
                // 特定ディスプレイの壁紙変更
                if let displayID = userInfo?["displayID"] as? String {
                    if let path = userInfo?["path"] as? String, !path.isEmpty {
                        let url = self.urlResolvingFilesystemUnicode(path: path)
                        self.setBackgroundImage(from: url, for: displayID)
                        debugLog("[Engine] ディスプレイ \(displayID) の壁紙を変更: \(url.path)")
                    } else {
                        self.clearBackgroundImage(for: displayID)
                        debugLog("[Engine] ディスプレイ \(displayID) の壁紙をクリア")
                    }
                }

            default:
                break
            }
        }
    }

    private func intValue(from value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private func floatValue(from value: Any?) -> Float? {
        if let float = value as? Float { return float }
        if let double = value as? Double { return Float(double) }
        if let number = value as? NSNumber { return number.floatValue }
        return nil
    }

    // MARK: - ディスプレイ構成変更

    private func handleDisplaysChanged() {
        let currentScreens = currentScreenMap()
        let enabledIDs = targetDisplayIDs(currentScreens: currentScreens)
        let currentIDs = Set(displayInstances.keys)

        for displayID in currentIDs.subtracting(enabledIDs) {
            removeInstance(for: displayID)
        }

        let detachedIDs = Set(detachedDisplayCache.keys)
        for displayID in detachedIDs.subtracting(enabledIDs) {
            removeInstance(for: displayID)
        }

        // ディスプレイを追加
        for displayID in enabledIDs.subtracting(currentIDs) {
            if let screen = currentScreens[displayID] {
                createInstance(for: displayID, screen: screen)
                applyCurrentSettings(to: displayID)
            }
        }

        debugLog("[Engine] ディスプレイ更新完了。アクティブ: \(displayInstances.count)")
        refreshDisplayArrangementForAll()
    }

    /// 無効化されたディスプレイを削除
    private func handleDisplayRemoved() {
        // メインスレッドで実行を保証
        let work = { [weak self] in
            guard let self = self else { return }

            let enabledIDs = Set(self.settings.enabledDisplayIDs)
            let currentIDs = Set(self.displayInstances.keys)

            // 有効でなくなったディスプレイのインスタンスを削除
            for displayID in currentIDs.subtracting(enabledIDs) {
                self.removeInstance(for: displayID)
            }

            let detachedIDs = Set(self.detachedDisplayCache.keys)
            for displayID in detachedIDs.subtracting(enabledIDs) {
                self.removeInstance(for: displayID)
            }

            debugLog("[Engine] ディスプレイ削除完了。アクティブ: \(self.displayInstances.count)")
            self.refreshDisplayArrangementForAll()
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async { work() }
        }
    }

    // MARK: - 全ディスプレイ制御

    func pauseAll() {
        displayInstances.values.forEach { $0.pause() }
    }

    func resumeAll() {
        displayInstances.values.forEach { $0.resume() }
    }

    func suspendForSystemEvent(reason: String) {
        displayInstances.values.forEach { $0.suspendForSystemEvent(reason: reason) }
        detachedDisplayCache.values.forEach { $0.suspendForSystemEvent(reason: reason) }
    }

    func resumeFromSystemEvent(reason: String) {
        displayInstances.values.forEach { $0.resumeFromSystemEvent(reason: reason) }
        detachedDisplayCache.values.forEach { $0.resumeFromSystemEvent(reason: reason) }
    }

    func setShaderForAll(_ shader: ShaderType) {
        displayInstances.values.forEach { $0.setShader(shader) }
    }

    func setEffectIntensityForAll(_ intensity: Float) {
        displayInstances.values.forEach { $0.setEffectIntensity(intensity) }
    }

    func setVolumeForAll(_ volume: Float) {
        displayInstances.values.forEach { $0.setVolume(volume) }
    }

    func setWebWallpaperScaleForAll(_ scale: Float) {
        displayInstances.values.forEach { $0.setWebWallpaperScale(scale) }
    }

    func setDesktopItemsClickableForAll(_ enabled: Bool) {
        displayInstances.values.forEach { $0.setDesktopItemsClickable(enabled) }
    }

    func setBackgroundImageForAll(from url: URL) {
        debugLog("[Engine] 全ディスプレイに壁紙を設定: \(url.path)")
        debugLog("[Engine] ディスプレイインスタンス数: \(displayInstances.count)")
        refreshDisplayArrangementForAll()
        for (id, instance) in displayInstances {
            debugLog("[Engine] ディスプレイ \(id) に壁紙を設定中")
            instance.setBackgroundImage(from: url)
        }
    }

    /// 特定のディスプレイに壁紙を設定
    func setBackgroundImage(from url: URL, for displayID: String) {
        guard let instance = displayInstances[displayID] else {
            debugLog("[Engine] ディスプレイインスタンスが見つかりません: \(displayID) → 表示構成を再同期して再試行")
            handleDisplaysChanged()
            if let retryInstance = displayInstances[displayID] {
                debugLog("[Engine] ディスプレイ \(displayID) に壁紙を設定: \(url.path)")
                retryInstance.refreshDisplayArrangement()
                retryInstance.setBackgroundImage(from: url)
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                guard let delayedInstance = self.displayInstances[displayID] else {
                    debugLog("[Engine] 再試行後もディスプレイインスタンスが見つかりません: \(displayID)")
                    return
                }
                debugLog("[Engine] ディスプレイ \(displayID) に壁紙を遅延設定: \(url.path)")
                delayedInstance.refreshDisplayArrangement()
                delayedInstance.setBackgroundImage(from: url)
            }
            return
        }
        debugLog("[Engine] ディスプレイ \(displayID) に壁紙を設定: \(url.path)")
        instance.refreshDisplayArrangement()
        instance.setBackgroundImage(from: url)
    }

    func refreshDisplayArrangementForAll() {
        displayInstances.values.forEach { $0.refreshDisplayArrangement() }
    }

    func clearBackgroundImageForAll() {
        displayInstances.values.forEach { $0.clearBackgroundImage() }
    }

    /// 特定のディスプレイの壁紙をクリア
    func clearBackgroundImage(for displayID: String) {
        guard let instance = displayInstances[displayID] else {
            debugLog("[Engine] ディスプレイインスタンスが見つかりません: \(displayID)")
            return
        }
        debugLog("[Engine] ディスプレイ \(displayID) の壁紙をクリア中")
        instance.clearBackgroundImage()
    }

    /// 全ディスプレイで透過モードを有効にする（macOSデスクトップの壁紙を表示）
    func enableTransparentModeForAll() {
        displayInstances.values.forEach { $0.enableTransparentMode() }
    }

    func applyPerformancePresetForAll(_ preset: PerformancePreset) {
        displayInstances.values.forEach { $0.applyPerformancePreset(preset) }
    }

    func applyPerformanceSettingsForAll(_ preset: PerformancePreset, frameRate: Int, resolutionScale: Float) {
        displayInstances.values.forEach {
            $0.applyPerformanceSettings(
                preset: preset,
                frameRate: frameRate,
                resolutionScale: resolutionScale
            )
        }
    }

    func reloadWebWallpaperDisplaySync(for rootURL: URL) {
        displayInstances.values.forEach { $0.reloadCurrentWebWallpaperIfMatches(rootDirectory: rootURL) }
    }

    // MARK: - 復旧

    /// スリープ復帰後に全ディスプレイの描画を強制再開する
    func forceRedrawAll() {
        for (id, instance) in displayInstances {
            instance.forceRedraw()
            debugLog("[Engine] ディスプレイ \(id) の強制再描画を実行")
        }
    }

    // MARK: - Effect Configuration

    func setEffectConfigurationForAll(_ config: EffectConfiguration) {
        displayInstances.values.forEach { $0.setEffectConfiguration(config) }
    }

    func setMaskTextureForAll(from maskData: MaskData) {
        displayInstances.values.forEach { $0.setMaskTexture(from: maskData) }
    }

    func clearMaskTextureForAll() {
        displayInstances.values.forEach { $0.clearMaskTexture() }
    }

    /// メインディスプレイのRendererを取得（エクスポート用）
    var primaryRenderer: Renderer? {
        // メインディスプレイのインスタンスを優先
        if let mainScreen = NSScreen.main {
            let mainID = displayIDString(for: mainScreen)
            if let instance = displayInstances[mainID] {
                return instance.renderer
            }
        }
        // なければ最初のインスタンスを返す
        return displayInstances.values.first?.renderer
    }

    /// 表示中の Web 壁紙の URL を既定ブラウザで開く（メイン画面を優先）。
    @discardableResult
    func openActiveWebWallpaperInDefaultBrowser() -> Bool {
        if let mainScreen = NSScreen.main {
            let mainID = displayIDString(for: mainScreen)
            if let inst = displayInstances[mainID], let url = inst.activeWebWallpaperPageURL() {
                NSWorkspace.shared.open(url)
                return true
            }
        }
        for (_, inst) in displayInstances {
            if let url = inst.activeWebWallpaperPageURL() {
                NSWorkspace.shared.open(url)
                return true
            }
        }
        return false
    }
}
