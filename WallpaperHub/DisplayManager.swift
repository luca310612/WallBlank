import Foundation
import AppKit
import IOKit

/// 接続されたディスプレイの情報
struct DisplayInfo: Identifiable, Hashable {
    let id: String                    // CGDirectDisplayID を文字列化
    let localizedName: String         // ユーザーに表示する名前
    let resolution: CGSize            // 解像度
    let frame: CGRect                 // macOS上のディスプレイフレーム
    let isMain: Bool                  // メインディスプレイか
    let isBuiltIn: Bool               // 内蔵ディスプレイか（MacBook）

    var displayID: CGDirectDisplayID {
        return CGDirectDisplayID(id) ?? 0
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: DisplayInfo, rhs: DisplayInfo) -> Bool {
        return lhs.id == rhs.id
    }
}

/// 壁紙キャンバス用のディスプレイ配置。yは下方向を正とする。
struct DisplayLayoutConfiguration: Codable, Equatable, Hashable {
    let id: String
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    init(id: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.id = id
        self.x = x
        self.y = y
        self.width = max(width, 1)
        self.height = max(height, 1)
    }

    init(display: DisplayInfo) {
        self.init(
            id: display.id,
            x: display.frame.minX,
            y: -display.frame.maxY,
            width: display.frame.width,
            height: display.frame.height
        )
    }

    init(displayID: String, screen: NSScreen) {
        self.init(
            id: displayID,
            x: screen.frame.minX,
            y: -screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
    }

    var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    mutating func move(to origin: CGPoint) {
        x = origin.x
        y = origin.y
    }
}

/// ディスプレイの検出・管理
class DisplayManager: DisplayManagerProtocol {
    static let shared = DisplayManager()

    @Published var connectedDisplays: [DisplayInfo] = []
    @Published var enabledDisplayIDs: Set<String> = []
    @Published var displayArrangement: [String: DisplayLayoutConfiguration] = [:]
    @Published var spanWallpaperAcrossDisplays: Bool = false

    private let settings: SettingsManagerProtocol

    // DI対応: デフォルト引数でシングルトンを使用しつつ、テスト時はモックを注入可能
    init(settings: SettingsManagerProtocol = SharedSettingsManager.shared) {
        self.settings = settings
        loadEnabledDisplays()
        loadDisplayArrangement()
        refreshDisplays()
        observeDisplayChanges()
    }

    // MARK: - Display Detection

    /// 接続されているディスプレイを更新
    func refreshDisplays() {
        var displays: [DisplayInfo] = []

        for screen in NSScreen.screens {
            if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                let idString = String(displayID)
                let name = displayName(for: displayID) ?? "Display \(displayID)"
                let isMain = screen == NSScreen.main
                let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0

                let info = DisplayInfo(
                    id: idString,
                    localizedName: name,
                    resolution: screen.frame.size,
                    frame: screen.frame,
                    isMain: isMain,
                    isBuiltIn: isBuiltIn
                )
                displays.append(info)
            }
        }

        // メインディスプレイを先頭に
        displays.sort { lhs, rhs in
            if lhs.isMain != rhs.isMain {
                return lhs.isMain
            }
            return lhs.localizedName < rhs.localizedName
        }

        DispatchQueue.main.async {
            let previousDisplayIDs = Set(self.connectedDisplays.map(\.id))
            let currentDisplayIDs = Set(displays.map(\.id))
            let newlyAddedDisplayIDs = currentDisplayIDs.subtracting(previousDisplayIDs)

            self.connectedDisplays = displays
            self.reconcileDisplayArrangement(with: displays)
            var shouldPersistEnabledDisplays = false

            // 初回起動時、有効なディスプレイがなければ全ディスプレイを有効に
            if self.enabledDisplayIDs.isEmpty && !displays.isEmpty {
                for display in displays {
                    self.enabledDisplayIDs.insert(display.id)
                }
                shouldPersistEnabledDisplays = true
            }

            // 新しく追加されたディスプレイは常に有効化する
            if !newlyAddedDisplayIDs.isEmpty {
                self.enabledDisplayIDs.formUnion(newlyAddedDisplayIDs)
                shouldPersistEnabledDisplays = true
            }

            // 切断されたディスプレイを有効リストから削除
            let intersectedEnabledIDs = self.enabledDisplayIDs.intersection(currentDisplayIDs)
            if intersectedEnabledIDs != self.enabledDisplayIDs {
                self.enabledDisplayIDs = intersectedEnabledIDs
                shouldPersistEnabledDisplays = true
            }

            if shouldPersistEnabledDisplays {
                self.saveEnabledDisplays()
            }
        }

        debugLog("[DisplayManager] Found \(displays.count) display(s)")
        for display in displays {
            debugLog("  - \(display.localizedName) [\(Int(display.resolution.width))x\(Int(display.resolution.height))] \(display.isMain ? "(Main)" : "") \(display.isBuiltIn ? "(Built-in)" : "")")
        }
    }

    /// ディスプレイ名を取得（NSScreenのlocalizedNameを使用）
    private func displayName(for displayID: CGDirectDisplayID) -> String? {
        // NSScreenから対応するスクリーンを探してlocalizedNameを取得
        for screen in NSScreen.screens {
            if let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               screenID == displayID {
                return screen.localizedName
            }
        }

        // フォールバック: 内蔵ディスプレイかどうかで判断
        if CGDisplayIsBuiltin(displayID) != 0 {
            return "Built-in Display"
        }

        return nil
    }

    // MARK: - Display Changes Observation

    private func observeDisplayChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        debugLog("[DisplayManager] Screen parameters changed")
        refreshDisplays()
    }

    // MARK: - Display Enable/Disable

    /// ディスプレイの有効/無効を切り替え
    func setDisplayEnabled(_ displayID: String, enabled: Bool) {
        if enabled {
            enabledDisplayIDs.insert(displayID)
            saveEnabledDisplays()
        } else {
            enabledDisplayIDs.remove(displayID)
            // 明示的な削除通知を送信
            settings.removeDisplay(displayID)
        }
    }

    /// ディスプレイが有効かどうか
    func isDisplayEnabled(_ displayID: String) -> Bool {
        return enabledDisplayIDs.contains(displayID)
    }

    // MARK: - Screen Lookup

    /// DisplayIDからNSScreenを取得
    func screen(for displayID: String) -> NSScreen? {
        guard let targetID = CGDirectDisplayID(displayID) else { return nil }

        return NSScreen.screens.first { screen in
            guard let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return screenID == targetID
        }
    }

    /// 有効なディスプレイのNSScreenリストを取得
    func enabledScreens() -> [NSScreen] {
        return enabledDisplayIDs.compactMap { screen(for: $0) }
    }

    // MARK: - Persistence

    func loadEnabledDisplays() {
        let savedIDs = settings.enabledDisplayIDs
        enabledDisplayIDs = Set(savedIDs)
        debugLog("[DisplayManager] Loaded enabled displays: \(savedIDs)")
    }

    func saveEnabledDisplays() {
        let ids = Array(enabledDisplayIDs)
        settings.enabledDisplayIDs = ids
        debugLog("[DisplayManager] Saved enabled displays: \(ids)")
    }

    private func loadDisplayArrangement() {
        displayArrangement = settings.displayArrangement
        spanWallpaperAcrossDisplays = settings.spanWallpaperAcrossDisplays
        debugLog("[DisplayManager] Loaded display arrangement: \(displayArrangement)")
    }

    private func reconcileDisplayArrangement(with displays: [DisplayInfo]) {
        var arrangement = displayArrangement
        let connectedIDs = Set(displays.map(\.id))

        for display in displays where arrangement[display.id] == nil {
            arrangement[display.id] = DisplayLayoutConfiguration(display: display)
        }

        let pruned = arrangement.filter { connectedIDs.contains($0.key) }
        if pruned != displayArrangement {
            displayArrangement = pruned
            settings.displayArrangement = pruned
        }
    }

    func setDisplayLayout(_ layout: DisplayLayoutConfiguration) {
        var arrangement = displayArrangement
        arrangement[layout.id] = layout
        setDisplayArrangement(arrangement)
    }

    func setDisplayArrangement(_ arrangement: [String: DisplayLayoutConfiguration]) {
        let connectedIDs = Set(connectedDisplays.map(\.id))
        let pruned = arrangement.filter { connectedIDs.contains($0.key) }
        displayArrangement = pruned
        settings.displayArrangement = pruned
        debugLog("[DisplayManager] Saved display arrangement: \(pruned)")
    }

    func resetDisplayArrangementToSystem() {
        let arrangement = Dictionary(uniqueKeysWithValues: connectedDisplays.map { display in
            (display.id, DisplayLayoutConfiguration(display: display))
        })
        setDisplayArrangement(arrangement)
    }

    func setSpanWallpaperAcrossDisplays(_ enabled: Bool) {
        spanWallpaperAcrossDisplays = enabled
        settings.spanWallpaperAcrossDisplays = enabled
        debugLog("[DisplayManager] Span wallpaper across displays: \(enabled)")
    }
}
