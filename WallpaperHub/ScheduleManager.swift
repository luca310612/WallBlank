import Foundation
import Combine

/// 壁紙ローテーションスケジュール
struct WallpaperSchedule: Identifiable, Codable {
    let id: String
    var name: String
    var isEnabled: Bool
    var collectionID: String?       // ソースコレクション（nilなら全壁紙）
    var wallpaperIDs: [String]      // コレクション未使用時の明示的リスト
    var interval: TimeInterval      // ローテーション間隔（秒）
    var shuffleOrder: Bool          // ランダム順 vs 順番
    var displayIDs: [String]?       // nil = 全ディスプレイ
    var activeHours: ActiveHours?   // 任意の時間制限

    struct ActiveHours: Codable {
        var startHour: Int          // 0-23
        var startMinute: Int        // 0-59
        var endHour: Int
        var endMinute: Int

        /// 現在の時刻がアクティブ時間内かどうか
        func isCurrentlyActive() -> Bool {
            let calendar = Calendar.current
            let now = Date()
            let hour = calendar.component(.hour, from: now)
            let minute = calendar.component(.minute, from: now)
            let currentMinutes = hour * 60 + minute
            let startMinutes = startHour * 60 + startMinute
            let endMinutes = endHour * 60 + endMinute

            if startMinutes <= endMinutes {
                return currentMinutes >= startMinutes && currentMinutes < endMinutes
            } else {
                // 深夜をまたぐ場合（例: 22:00 - 06:00）
                return currentMinutes >= startMinutes || currentMinutes < endMinutes
            }
        }
    }

    init(
        id: String = UUID().uuidString,
        name: String = "スケジュール",
        isEnabled: Bool = true,
        collectionID: String? = nil,
        wallpaperIDs: [String] = [],
        interval: TimeInterval = AppConstants.Schedule.defaultInterval,
        shuffleOrder: Bool = false,
        displayIDs: [String]? = nil,
        activeHours: ActiveHours? = nil
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.collectionID = collectionID
        self.wallpaperIDs = wallpaperIDs
        self.interval = interval
        self.shuffleOrder = shuffleOrder
        self.displayIDs = displayIDs
        self.activeHours = activeHours
    }
}

/// スケジュール管理クラス
class ScheduleManager: ObservableObject {
    static let shared = ScheduleManager()

    @Published var schedules: [WallpaperSchedule] = []
    @Published var activeScheduleID: String?
    @Published var currentWallpaperIndex: Int = 0
    @Published var nextRotationDate: Date?

    /// 壁紙適用コールバック（AppDelegateから設定される）
    /// WallpaperItem と WallpaperLibrary を受け取り、壁紙を適用する
    var applyWallpaperHandler: ((WallpaperItem, WallpaperLibrary) -> Void)?

    private var rotationTimer: Timer?
    private var shuffledOrder: [Int] = []
    private let fileManager = FileManager.default

    private var schedulesURL: URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return fileManager.temporaryDirectory.appendingPathComponent("\(AppConstants.appFolderName)/schedules.json")
        }
        return appSupport.appendingPathComponent("\(AppConstants.appFolderName)/schedules.json")
    }

    private init() {
        loadSchedules()
    }

    // MARK: - 永続化

    private func loadSchedules() {
        guard fileManager.fileExists(atPath: schedulesURL.path),
              let data = try? Data(contentsOf: schedulesURL),
              let loaded = try? JSONDecoder().decode([WallpaperSchedule].self, from: data)
        else { return }

        schedules = loaded
        debugLog("[Schedule] \(schedules.count) 件のスケジュールを読み込み")
    }

    private func saveSchedules() {
        do {
            let dir = schedulesURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(schedules)
            try data.write(to: schedulesURL, options: .atomic)
        } catch {
            debugLog("[Schedule] スケジュールの保存に失敗: \(error)")
        }
    }

    // MARK: - CRUD

    @discardableResult
    func createSchedule(
        name: String = "スケジュール",
        collectionID: String? = nil,
        interval: TimeInterval = AppConstants.Schedule.defaultInterval,
        shuffleOrder: Bool = false
    ) -> WallpaperSchedule {
        let schedule = WallpaperSchedule(
            name: name,
            collectionID: collectionID,
            interval: interval,
            shuffleOrder: shuffleOrder
        )
        schedules.append(schedule)
        saveSchedules()
        return schedule
    }

    func deleteSchedule(id: String) {
        if activeScheduleID == id {
            stopSchedule()
        }
        schedules.removeAll { $0.id == id }
        saveSchedules()
    }

    func updateSchedule(_ schedule: WallpaperSchedule) {
        guard let index = schedules.firstIndex(where: { $0.id == schedule.id }) else { return }
        schedules[index] = schedule
        saveSchedules()

        // アクティブなスケジュールが更新された場合はリスタート
        if activeScheduleID == schedule.id {
            if schedule.isEnabled {
                startSchedule(schedule.id)
            } else {
                stopSchedule()
            }
        }
    }

    // MARK: - スケジュール制御

    /// スケジュールを開始
    func startSchedule(_ scheduleID: String) {
        guard let schedule = schedules.first(where: { $0.id == scheduleID }),
              schedule.isEnabled else { return }

        stopSchedule()
        activeScheduleID = scheduleID
        currentWallpaperIndex = 0

        // シャッフル順を準備
        let wallpaperCount = getWallpaperIDs(for: schedule).count
        if schedule.shuffleOrder && wallpaperCount > 0 {
            shuffledOrder = Array(0..<wallpaperCount).shuffled()
        } else {
            shuffledOrder = Array(0..<wallpaperCount)
        }

        // 最初の壁紙を適用
        applyCurrentWallpaper()

        // タイマー開始
        let interval = max(schedule.interval, AppConstants.Schedule.minimumInterval)
        nextRotationDate = Date().addingTimeInterval(interval)

        rotationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.advanceSchedule()
        }

        debugLog("[Schedule] スケジュール '\(schedule.name)' を開始（間隔: \(interval)秒）")
    }

    /// スケジュールを停止
    func stopSchedule() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        activeScheduleID = nil
        nextRotationDate = nil
        currentWallpaperIndex = 0
        shuffledOrder = []
        debugLog("[Schedule] スケジュールを停止")
    }

    /// 次の壁紙に進む（手動トリガー）
    func advanceNow() {
        advanceSchedule()
    }

    /// 前の壁紙に戻る
    func previousWallpaper() {
        guard let scheduleID = activeScheduleID,
              let schedule = schedules.first(where: { $0.id == scheduleID }) else { return }

        let wallpaperIDs = getWallpaperIDs(for: schedule)
        guard !wallpaperIDs.isEmpty else { return }

        currentWallpaperIndex = (currentWallpaperIndex - 1 + wallpaperIDs.count) % wallpaperIDs.count
        applyCurrentWallpaper()
        resetTimer()
    }

    // MARK: - 内部ロジック

    private func advanceSchedule() {
        guard let scheduleID = activeScheduleID,
              let schedule = schedules.first(where: { $0.id == scheduleID }) else { return }

        // アクティブ時間チェック
        if let activeHours = schedule.activeHours, !activeHours.isCurrentlyActive() {
            debugLog("[Schedule] アクティブ時間外のためローテーションをスキップ")
            return
        }

        let wallpaperIDs = getWallpaperIDs(for: schedule)
        guard !wallpaperIDs.isEmpty else { return }

        currentWallpaperIndex = (currentWallpaperIndex + 1) % wallpaperIDs.count

        // シャッフルモードで一巡したら再シャッフル
        if schedule.shuffleOrder && currentWallpaperIndex == 0 {
            shuffledOrder = Array(0..<wallpaperIDs.count).shuffled()
        }

        applyCurrentWallpaper()

        let interval = max(schedule.interval, AppConstants.Schedule.minimumInterval)
        nextRotationDate = Date().addingTimeInterval(interval)
    }

    private func applyCurrentWallpaper() {
        guard let scheduleID = activeScheduleID,
              let schedule = schedules.first(where: { $0.id == scheduleID }) else { return }

        let wallpaperIDs = getWallpaperIDs(for: schedule)
        guard !wallpaperIDs.isEmpty else { return }

        let index = shuffledOrder.isEmpty ? currentWallpaperIndex : shuffledOrder[currentWallpaperIndex % shuffledOrder.count]
        let wallpaperID = wallpaperIDs[index % wallpaperIDs.count]

        let library = WallpaperLibrary.shared
        guard let wallpaper = library.wallpapers.first(where: { $0.id == wallpaperID }) else {
            debugLog("[Schedule] 壁紙が見つかりません: \(wallpaperID)")
            return
        }

        // コールバック経由で壁紙を適用（レイヤー違反を回避）
        DispatchQueue.main.async { [weak self] in
            guard let handler = self?.applyWallpaperHandler else {
                debugLog("[Schedule] 壁紙適用ハンドラが未設定です")
                return
            }
            handler(wallpaper, library)
            debugLog("[Schedule] 壁紙を適用: \(wallpaper.name)")
        }
    }

    private func resetTimer() {
        guard let scheduleID = activeScheduleID,
              let schedule = schedules.first(where: { $0.id == scheduleID }) else { return }

        rotationTimer?.invalidate()
        let interval = max(schedule.interval, AppConstants.Schedule.minimumInterval)
        nextRotationDate = Date().addingTimeInterval(interval)

        rotationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.advanceSchedule()
        }
    }

    /// スケジュールに使用する壁紙IDリストを取得
    private func getWallpaperIDs(for schedule: WallpaperSchedule) -> [String] {
        if let collectionID = schedule.collectionID {
            let library = WallpaperLibrary.shared
            return library.wallpapers(in: collectionID).map { $0.id }
        }
        return schedule.wallpaperIDs
    }

    /// スケジュールがアクティブかどうか
    var isScheduleActive: Bool {
        activeScheduleID != nil
    }
}
