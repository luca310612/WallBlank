import Foundation
import XCTest

@testable import Artia

/// Phase 7B: PlaylistManager の CRUD / 再生モード / Codable 検証。
@MainActor
final class PlaylistManagerTests: XCTestCase {

    // MARK: - Codable

    func test_playlist_codable_roundTrip() throws {
        let playlist = Playlist(
            name: "夜のプレイリスト",
            items: ["w-1", "w-2", "w-3"],
            mode: .intervalShuffle,
            intervalSeconds: 600
        )
        let data = try JSONEncoder().encode(playlist)
        let back = try JSONDecoder().decode(Playlist.self, from: data)
        XCTAssertEqual(playlist, back)
    }

    func test_mode_displayName_isDistinctAndJapanese() {
        let names = Set(PlaylistMode.allCases.map { $0.displayName })
        XCTAssertEqual(names.count, PlaylistMode.allCases.count)
        for m in PlaylistMode.allCases {
            XCTAssertFalse(m.displayName.isEmpty)
        }
    }

    // MARK: - CRUD

    func test_createUpdateDelete_listManipulation() {
        let mgr = PlaylistManager()
        let initialCount = mgr.playlists.count
        let p = mgr.createPlaylist(name: "テスト")
        XCTAssertEqual(mgr.playlists.count, initialCount + 1)
        XCTAssertEqual(mgr.playlists.last?.id, p.id)

        var modified = p
        modified.name = "リネーム"
        modified.items = ["w-1"]
        mgr.updatePlaylist(modified)
        XCTAssertEqual(mgr.playlists.first(where: { $0.id == p.id })?.name, "リネーム")

        mgr.deletePlaylist(id: p.id)
        XCTAssertNil(mgr.playlists.first(where: { $0.id == p.id }))
    }

    // MARK: - Playback

    func test_start_emptyPlaylist_isNoOp() {
        let mgr = PlaylistManager()
        let empty = mgr.createPlaylist(name: "空")
        var fired: [String] = []
        mgr.advanceHandler = { fired.append($0) }
        mgr.start(empty.id)
        XCTAssertNil(mgr.activePlaylistID, "空 playlist で start は何もしない")
        XCTAssertEqual(fired.count, 0)
        mgr.deletePlaylist(id: empty.id)
    }

    func test_start_emitsFirstItemImmediately() {
        let mgr = PlaylistManager()
        var p = mgr.createPlaylist(name: "実行")
        p.items = ["w-1", "w-2"]
        p.intervalSeconds = 60
        mgr.updatePlaylist(p)

        var fired: [String] = []
        mgr.advanceHandler = { fired.append($0) }
        mgr.start(p.id)
        XCTAssertEqual(fired, ["w-1"])
        XCTAssertEqual(mgr.currentItemID(), "w-1")
        mgr.stop()
        mgr.deletePlaylist(id: p.id)
    }

    func test_advance_sequential_loopsBackToStart() {
        let mgr = PlaylistManager()
        var p = mgr.createPlaylist(name: "順次")
        p.items = ["a", "b", "c"]
        mgr.updatePlaylist(p)
        mgr.start(p.id)

        var fired: [String] = []
        mgr.advanceHandler = { fired.append($0) }
        // start で a が一度発火済みのため、 fired は再リセット
        fired.removeAll()
        mgr.advance()
        mgr.advance()
        mgr.advance()
        // a → b → c → a (ループ) で advance を 3 回呼んだので b, c, a が発火する
        XCTAssertEqual(fired, ["b", "c", "a"])
        mgr.stop()
        mgr.deletePlaylist(id: p.id)
    }

    func test_advance_random_picksOneOfItems() {
        let mgr = PlaylistManager()
        var p = mgr.createPlaylist(name: "ランダム")
        p.items = ["x", "y", "z"]
        p.mode = .random
        mgr.updatePlaylist(p)
        mgr.start(p.id)

        var lastFired: String?
        mgr.advanceHandler = { lastFired = $0 }
        for _ in 0..<10 {
            mgr.advance()
            XCTAssertTrue(["x", "y", "z"].contains(lastFired ?? ""))
        }
        mgr.stop()
        mgr.deletePlaylist(id: p.id)
    }

    func test_advance_intervalShuffle_yieldsAllItemsOncePerCycle() {
        let mgr = PlaylistManager()
        var p = mgr.createPlaylist(name: "シャッフル")
        p.items = ["m", "n", "o", "p"]
        p.mode = .intervalShuffle
        mgr.updatePlaylist(p)

        var fired: [String] = []
        mgr.advanceHandler = { fired.append($0) }
        mgr.start(p.id)
        for _ in 0..<3 {
            mgr.advance()
        }
        // start で 1 個 + advance で 3 個 = 1 サイクル分 (4 個)
        XCTAssertEqual(fired.count, 4)
        XCTAssertEqual(Set(fired), Set(p.items), "1 サイクルで全 item が発火する")
        mgr.stop()
        mgr.deletePlaylist(id: p.id)
    }

    func test_stop_clearsActiveState() {
        let mgr = PlaylistManager()
        var p = mgr.createPlaylist(name: "停止")
        p.items = ["a"]
        mgr.updatePlaylist(p)
        mgr.start(p.id)
        XCTAssertEqual(mgr.activePlaylistID, p.id)
        mgr.stop()
        XCTAssertNil(mgr.activePlaylistID)
        XCTAssertNil(mgr.nextRotationDate)
        mgr.deletePlaylist(id: p.id)
    }
}
