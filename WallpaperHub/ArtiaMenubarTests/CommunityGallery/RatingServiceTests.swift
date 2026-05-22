import XCTest
import Foundation

@testable import Artia

/// Phase 10E: RatingService と CommentService のラウンドトリップ。
/// CommunityGalleryServiceTests と同じ MockFirestore を再利用する。
@MainActor
final class RatingServiceTests: XCTestCase {

    var firestore: CommunityGalleryServiceTests.MockFirestore!

    override func setUp() {
        super.setUp()
        firestore = CommunityGalleryServiceTests.MockFirestore()
        // 親壁紙ドキュメントを 1 件入れておく (rating 更新用)
        let now = CommunityGalleryService.iso8601Formatter.string(from: Date())
        firestore.documents["community_wallpapers"] = [
            "wp-1": CommunityGalleryService.fieldsPayload(
                title: "T", description: "", tags: [], type: "scene",
                previewURL: "p", downloadURL: "d", authorID: "a",
                createdAtISO: now, downloads: 0, rating: 0, ratingCount: 0
            )
        ]
    }

    override func tearDown() {
        firestore = nil
        super.tearDown()
    }

    // MARK: - Rating

    func test_rate_validScoreUpdatesAverage() async throws {
        let svc = RatingService(firestore: firestore, userIDProvider: { "u-1" })
        try await svc.rate(wallpaperID: "wp-1", score: 4)

        // ratings/u-1 に書き込まれている
        let ratings = firestore.documents["community_wallpapers/wp-1/ratings"]
        XCTAssertEqual(ratings?["u-1"]?["score"] as? [String: Any] != nil, true)

        // 親 wp-1.rating / ratingCount が更新されている
        let parent = firestore.documents["community_wallpapers"]?["wp-1"]
        let rating = (parent?["rating"] as? [String: Any])?["doubleValue"] as? Double
        let ratingCount = (parent?["ratingCount"] as? [String: Any])?["integerValue"] as? String
        XCTAssertEqual(rating ?? 0, 4.0, accuracy: 0.001)
        XCTAssertEqual(ratingCount, "1")
    }

    func test_rate_outOfRangeThrows() async {
        let svc = RatingService(firestore: firestore, userIDProvider: { "u-1" })
        do {
            try await svc.rate(wallpaperID: "wp-1", score: 6)
            XCTFail("score 範囲外でエラーが期待される")
        } catch RatingService.RatingError.scoreOutOfRange(let s) {
            XCTAssertEqual(s, 6)
        } catch {
            XCTFail("想定外のエラー: \(error)")
        }
    }

    func test_rate_unauthenticatedThrows() async {
        let svc = RatingService(firestore: firestore, userIDProvider: { nil })
        do {
            try await svc.rate(wallpaperID: "wp-1", score: 3)
            XCTFail("未認証でエラーが期待される")
        } catch RatingService.RatingError.notAuthenticated {
            // ok
        } catch {
            XCTFail("想定外のエラー: \(error)")
        }
    }

    func test_averageRating_multipleVotes() async throws {
        let alice = RatingService(firestore: firestore, userIDProvider: { "alice" })
        let bob = RatingService(firestore: firestore, userIDProvider: { "bob" })
        try await alice.rate(wallpaperID: "wp-1", score: 5)
        try await bob.rate(wallpaperID: "wp-1", score: 3)

        let avg = try await alice.averageRating(wallpaperID: "wp-1")
        XCTAssertEqual(avg, 4.0, accuracy: 0.001)
    }
}

@MainActor
final class CommentServiceTests: XCTestCase {

    var firestore: CommunityGalleryServiceTests.MockFirestore!

    override func setUp() {
        super.setUp()
        firestore = CommunityGalleryServiceTests.MockFirestore()
    }

    override func tearDown() {
        firestore = nil
        super.tearDown()
    }

    func test_post_createsCommentDocument() async throws {
        let svc = CommentService(
            firestore: firestore,
            userIDProvider: { "user-α" },
            commentIDGenerator: { "c-001" }
        )
        let id = try await svc.post(wallpaperID: "wp-x", body: "綺麗な壁紙ですね")
        XCTAssertEqual(id, "c-001")
        let collection = firestore.documents["community_wallpapers/wp-x/comments"]
        XCTAssertNotNil(collection?["c-001"])
        let body = (collection?["c-001"]?["body"] as? [String: Any])?["stringValue"] as? String
        XCTAssertEqual(body, "綺麗な壁紙ですね")
    }

    func test_post_emptyBodyThrows() async {
        let svc = CommentService(
            firestore: firestore,
            userIDProvider: { "u" },
            commentIDGenerator: { "c-1" }
        )
        do {
            _ = try await svc.post(wallpaperID: "wp-x", body: "   \n")
            XCTFail("空コメントでエラーが期待される")
        } catch CommentService.CommentError.bodyEmpty {
            // ok
        } catch {
            XCTFail("想定外のエラー: \(error)")
        }
    }

    func test_list_returnsAllComments() async throws {
        let svc = CommentService(
            firestore: firestore,
            userIDProvider: { "u" },
            commentIDGenerator: {
                // 連番ジェネレータをクロージャで作るのは難しいので UUID にする
                UUID().uuidString
            }
        )
        _ = try await svc.post(wallpaperID: "wp-y", body: "1")
        _ = try await svc.post(wallpaperID: "wp-y", body: "2")
        _ = try await svc.post(wallpaperID: "wp-y", body: "3")

        let list = try await svc.list(wallpaperID: "wp-y")
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(Set(list.map { $0.body }), ["1", "2", "3"])
    }

    func test_delete_removesComment() async throws {
        let svc = CommentService(
            firestore: firestore,
            userIDProvider: { "u" },
            commentIDGenerator: { "c-keep" }
        )
        let id = try await svc.post(wallpaperID: "wp-z", body: "削除予定")
        try await svc.delete(wallpaperID: "wp-z", commentID: id)
        let collection = firestore.documents["community_wallpapers/wp-z/comments"]
        XCTAssertNil(collection?[id])
    }
}
