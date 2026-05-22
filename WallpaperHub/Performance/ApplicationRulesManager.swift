import Foundation
import AppKit
import Combine

/// Phase 7B: アプリ連動ルール — 起動中の bundle id を polling して、
/// 一致したら指定アクション (壁紙切替 / プレイリスト / 一時停止 / プロファイル切替) を発火する。
///
/// Why: ScheduleManager (時刻トリガ) / EnvironmentMonitor (環境トリガ) と並走させ、
///      アプリ単位の ad-hoc ルールを 1 か所に集約する。

/// アクション種別
enum ApplicationRuleAction: Codable, Equatable {
    /// パフォーマンスプロファイルを切り替える (preset id)
    case switchProfile(presetID: Int)
    /// プレイリストを切り替える (playlist UUID)
    case switchPlaylist(playlistID: String)
    /// 単一壁紙を適用する (wallpaper id)
    case switchWallpaper(wallpaperID: String)
    /// 全ディスプレイの壁紙を一時停止する
    case pauseWallpaper

    enum CodingKeys: String, CodingKey {
        case kind, presetID = "preset_id", playlistID = "playlist_id", wallpaperID = "wallpaper_id"
    }

    enum Kind: String, Codable {
        case switchProfile = "switch_profile"
        case switchPlaylist = "switch_playlist"
        case switchWallpaper = "switch_wallpaper"
        case pauseWallpaper = "pause_wallpaper"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .switchProfile:
            self = .switchProfile(presetID: try c.decode(Int.self, forKey: .presetID))
        case .switchPlaylist:
            self = .switchPlaylist(playlistID: try c.decode(String.self, forKey: .playlistID))
        case .switchWallpaper:
            self = .switchWallpaper(wallpaperID: try c.decode(String.self, forKey: .wallpaperID))
        case .pauseWallpaper:
            self = .pauseWallpaper
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .switchProfile(let id):
            try c.encode(Kind.switchProfile, forKey: .kind)
            try c.encode(id, forKey: .presetID)
        case .switchPlaylist(let id):
            try c.encode(Kind.switchPlaylist, forKey: .kind)
            try c.encode(id, forKey: .playlistID)
        case .switchWallpaper(let id):
            try c.encode(Kind.switchWallpaper, forKey: .kind)
            try c.encode(id, forKey: .wallpaperID)
        case .pauseWallpaper:
            try c.encode(Kind.pauseWallpaper, forKey: .kind)
        }
    }
}

/// 1 件のアプリ連動ルール
struct ApplicationRule: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var bundleIDs: [String]
    var action: ApplicationRuleAction
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        bundleIDs: [String],
        action: ApplicationRuleAction,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.bundleIDs = bundleIDs
        self.action = action
        self.isEnabled = isEnabled
    }
}

/// アプリ連動ルール マネージャー
@MainActor
final class ApplicationRulesManager: ObservableObject {

    static let shared = ApplicationRulesManager()

    @Published private(set) var rules: [ApplicationRule] = []

    /// 直近に発火した rule.id (再発火防止用)
    @Published private(set) var lastTriggeredRuleID: UUID?

    /// 外部から差し込むハンドラ (action → 実際の壁紙操作)
    /// Why: Manager は副作用を直接持たず、AppDelegate 側で接続することで
    ///      テスト時にダミー注入が可能になる。
    var actionHandler: ((ApplicationRuleAction) -> Void)?

    private let pollingInterval: TimeInterval
    private var pollingTimer: Timer?
    /// テスト時に NSWorkspace を差し替えるためのプロバイダ
    private let runningBundleIDsProvider: () -> Set<String>
    /// 直近 polling で発火済みの (ruleID, bundleID) ペア (同じ bundle が起動中の間は再発火しない)
    private var firedRuleBundles: Set<UUID> = []

    private let fileManager = FileManager.default

    private var rulesURL: URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return fileManager.temporaryDirectory.appendingPathComponent("\(AppConstants.appFolderName)/application_rules.json")
        }
        return appSupport.appendingPathComponent("\(AppConstants.appFolderName)/application_rules.json")
    }

    init(
        pollingInterval: TimeInterval = 5.0,
        runningBundleIDsProvider: @escaping () -> Set<String> = ApplicationRulesManager.defaultRunningBundleIDs
    ) {
        self.pollingInterval = pollingInterval
        self.runningBundleIDsProvider = runningBundleIDsProvider
        loadRules()
    }

    // MARK: - 永続化

    private func loadRules() {
        guard fileManager.fileExists(atPath: rulesURL.path),
              let data = try? Data(contentsOf: rulesURL),
              let decoded = try? JSONDecoder().decode([ApplicationRule].self, from: data) else {
            return
        }
        rules = decoded
    }

    private func saveRules() {
        do {
            let dir = rulesURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(rules)
            try data.write(to: rulesURL, options: .atomic)
        } catch {
            // 失敗しても致命ではないので吸収
        }
    }

    // MARK: - CRUD

    @discardableResult
    func addRule(_ rule: ApplicationRule) -> ApplicationRule {
        rules.append(rule)
        saveRules()
        return rule
    }

    func updateRule(_ rule: ApplicationRule) {
        guard let idx = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[idx] = rule
        saveRules()
    }

    func removeRule(id: UUID) {
        rules.removeAll { $0.id == id }
        saveRules()
    }

    // MARK: - Polling

    func startMonitoring() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        evaluate()
    }

    func stopMonitoring() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    /// テスト用: 1 回だけ評価を行う
    func evaluate() {
        let runningIDs = runningBundleIDsProvider()
        var stillFired: Set<UUID> = []
        for rule in rules where rule.isEnabled {
            let isMatching = rule.bundleIDs.contains(where: { runningIDs.contains($0) })
            if isMatching {
                if !firedRuleBundles.contains(rule.id) {
                    fire(rule)
                }
                stillFired.insert(rule.id)
            }
        }
        // 起動中じゃなくなったルールを fired から除去 → 次回再起動時に再発火させる
        firedRuleBundles = stillFired
    }

    private func fire(_ rule: ApplicationRule) {
        firedRuleBundles.insert(rule.id)
        lastTriggeredRuleID = rule.id
        actionHandler?(rule.action)
    }

    // MARK: - Defaults

    nonisolated static func defaultRunningBundleIDs() -> Set<String> {
        let apps = NSWorkspace.shared.runningApplications
        return Set(apps.compactMap { $0.bundleIdentifier })
    }
}
