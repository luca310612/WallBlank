import Foundation
import Combine

/// Phase 7B: プレイリスト — 既存 ScheduleManager (時刻ローテ) と並走する「順番に表示」機能。
///
/// Why: ScheduleManager は activeHours/間隔/シャッフルで時刻ベース、
///      PlaylistManager は明示的に複数アイテムを並べて再生する用途に分離する。

/// プレイリストの再生モード
enum PlaylistMode: String, Codable, CaseIterable {
    /// 順次再生 (items の先頭から末尾、終端で先頭へ戻る)
    case sequential
    /// 完全ランダム (毎回 items.randomElement())
    case random
    /// 各サイクルで順序をシャッフルし、サイクル内では順次
    case intervalShuffle

    var displayName: String {
        switch self {
        case .sequential:      return "順番"
        case .random:          return "ランダム"
        case .intervalShuffle: return "シャッフル順"
        }
    }
}

/// 1 件のプレイリスト
struct Playlist: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var items: [String]                 // wallpaper id (WallpaperItem.id)
    var mode: PlaylistMode
    var intervalSeconds: TimeInterval

    init(
        id: UUID = UUID(),
        name: String,
        items: [String] = [],
        mode: PlaylistMode = .sequential,
        intervalSeconds: TimeInterval = 600
    ) {
        self.id = id
        self.name = name
        self.items = items
        self.mode = mode
        self.intervalSeconds = intervalSeconds
    }
}

/// プレイリスト マネージャー
@MainActor
final class PlaylistManager: ObservableObject {

    static let shared = PlaylistManager()

    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var activePlaylistID: UUID?
    @Published private(set) var currentIndex: Int = 0
    @Published private(set) var nextRotationDate: Date?

    /// playlist が次のアイテムへ進んだとき呼ばれる (wallpaper id を渡す)
    var advanceHandler: ((String) -> Void)?

    private var rotationTimer: Timer?
    private var shuffledIndices: [Int] = []
    private let fileManager = FileManager.default

    private var playlistsURL: URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return fileManager.temporaryDirectory.appendingPathComponent("\(AppConstants.appFolderName)/playlists.json")
        }
        return appSupport.appendingPathComponent("\(AppConstants.appFolderName)/playlists.json")
    }

    init() {
        loadPlaylists()
    }

    // MARK: - 永続化

    private func loadPlaylists() {
        guard fileManager.fileExists(atPath: playlistsURL.path),
              let data = try? Data(contentsOf: playlistsURL),
              let decoded = try? JSONDecoder().decode([Playlist].self, from: data) else {
            return
        }
        playlists = decoded
    }

    private func savePlaylists() {
        do {
            let dir = playlistsURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(playlists)
            try data.write(to: playlistsURL, options: .atomic)
        } catch {
            // 永続化失敗は致命ではないので吸収
        }
    }

    // MARK: - CRUD

    @discardableResult
    func createPlaylist(name: String = "新しいプレイリスト") -> Playlist {
        let p = Playlist(name: name)
        playlists.append(p)
        savePlaylists()
        return p
    }

    func updatePlaylist(_ playlist: Playlist) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[idx] = playlist
        savePlaylists()
        if activePlaylistID == playlist.id {
            // 再生中の playlist が更新されたらタイマーをリスタート
            restartCurrentRotation()
        }
    }

    func deletePlaylist(id: UUID) {
        if activePlaylistID == id {
            stop()
        }
        playlists.removeAll { $0.id == id }
        savePlaylists()
    }

    // MARK: - Playback

    /// プレイリスト再生開始
    func start(_ playlistID: UUID) {
        guard let playlist = playlists.first(where: { $0.id == playlistID }),
              !playlist.items.isEmpty else {
            return
        }
        stop()
        activePlaylistID = playlistID
        currentIndex = 0
        prepareShuffleOrderIfNeeded(for: playlist)
        applyCurrent()
        scheduleNextTick(for: playlist)
    }

    /// 再生停止
    func stop() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        activePlaylistID = nil
        nextRotationDate = nil
        shuffledIndices = []
    }

    /// 次のアイテムへ進める
    func advance() {
        guard let id = activePlaylistID,
              let playlist = playlists.first(where: { $0.id == id }),
              !playlist.items.isEmpty else {
            return
        }
        switch playlist.mode {
        case .sequential:
            currentIndex = (currentIndex + 1) % playlist.items.count
        case .random:
            currentIndex = Int.random(in: 0..<playlist.items.count)
        case .intervalShuffle:
            currentIndex += 1
            if currentIndex >= shuffledIndices.count {
                shuffledIndices = Array(0..<playlist.items.count).shuffled()
                currentIndex = 0
            }
        }
        applyCurrent()
        scheduleNextTick(for: playlist)
    }

    // MARK: - Internal helpers

    /// テスト用: 任意 index で発火させる
    func setCurrentIndex(_ index: Int) {
        currentIndex = index
    }

    /// 現在のアイテム id を返す (再生中で playlist が空でないとき)
    func currentItemID() -> String? {
        guard let id = activePlaylistID,
              let playlist = playlists.first(where: { $0.id == id }),
              !playlist.items.isEmpty else {
            return nil
        }
        switch playlist.mode {
        case .intervalShuffle:
            let realIndex = shuffledIndices.indices.contains(currentIndex)
                ? shuffledIndices[currentIndex]
                : currentIndex
            return playlist.items.indices.contains(realIndex) ? playlist.items[realIndex] : nil
        default:
            return playlist.items.indices.contains(currentIndex) ? playlist.items[currentIndex] : nil
        }
    }

    private func prepareShuffleOrderIfNeeded(for playlist: Playlist) {
        if playlist.mode == .intervalShuffle {
            shuffledIndices = Array(0..<playlist.items.count).shuffled()
        } else {
            shuffledIndices = []
        }
    }

    private func applyCurrent() {
        if let item = currentItemID() {
            advanceHandler?(item)
        }
    }

    private func scheduleNextTick(for playlist: Playlist) {
        rotationTimer?.invalidate()
        let interval = max(playlist.intervalSeconds, 5.0)
        nextRotationDate = Date().addingTimeInterval(interval)
        rotationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.advance() }
        }
    }

    private func restartCurrentRotation() {
        guard let id = activePlaylistID,
              let playlist = playlists.first(where: { $0.id == id }) else { return }
        scheduleNextTick(for: playlist)
    }
}
