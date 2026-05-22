import Foundation

/// Phase 10C: 公開壁紙への 1〜5 評価。
/// パス: `community_wallpapers/<wallpaperID>/ratings/<userID>`
@MainActor
final class RatingService {

    /// 1〜5 のスコア。範囲外は throw。
    enum RatingError: LocalizedError {
        case scoreOutOfRange(Int)
        case notAuthenticated

        var errorDescription: String? {
            switch self {
            case .scoreOutOfRange(let s): return "評価値は 1〜5 の範囲で指定してください (受信: \(s))"
            case .notAuthenticated: return "サインインが必要です"
            }
        }
    }

    struct Rating: Equatable {
        let userID: String
        let score: Int
        let createdAt: Date?
    }

    private let firestore: CommunityGalleryService.FirestoreOperator
    private let userIDProvider: @Sendable () -> String?

    init(
        firestore: CommunityGalleryService.FirestoreOperator,
        userIDProvider: @escaping @Sendable () -> String?
    ) {
        self.firestore = firestore
        self.userIDProvider = userIDProvider
    }

    static func makeDefault() -> RatingService {
        return RatingService(
            firestore: DefaultFirestoreAdapter.shared,
            userIDProvider: { AuthManager.shared.currentUID }
        )
    }

    /// 評価を投票する。同じユーザの再投票は上書き (server-wins)。
    func rate(wallpaperID: String, score: Int) async throws {
        guard (1...5).contains(score) else {
            throw RatingError.scoreOutOfRange(score)
        }
        guard let uid = userIDProvider() else {
            throw RatingError.notAuthenticated
        }

        let nowIso = CommunityGalleryService.iso8601Formatter.string(from: Date())
        let collectionPath = subcollectionPath(wallpaperID: wallpaperID)
        let fields: [String: Any] = [
            "userId": ["stringValue": uid],
            "score": ["integerValue": "\(score)"],
            "createdAt": ["timestampValue": nowIso],
        ]
        // Firestore は create で同じ docId が既存なら conflict なので、
        // 確実に上書きするには update が望ましい。
        // ここは MVP として update を試し、404 なら create にフォールバック。
        do {
            _ = try await firestore.update(
                collection: collectionPath,
                docId: uid,
                fields: fields,
                updateMask: ["userId", "score", "createdAt"]
            )
        } catch {
            _ = try await firestore.create(collection: collectionPath, docId: uid, fields: fields)
        }

        // 親ドキュメントの rating / ratingCount を再計算
        let allRatings = try await listAll(wallpaperID: wallpaperID)
        let count = allRatings.count
        let avg: Double
        if count > 0 {
            let sum = allRatings.map { Double($0.score) }.reduce(0, +)
            avg = sum / Double(count)
        } else {
            avg = 0.0
        }
        let parentFields: [String: Any] = [
            "rating": ["doubleValue": avg],
            "ratingCount": ["integerValue": "\(count)"],
        ]
        _ = try? await firestore.update(
            collection: CommunityGalleryService.collection,
            docId: wallpaperID,
            fields: parentFields,
            updateMask: ["rating", "ratingCount"]
        )
    }

    /// 平均評価を計算する。
    func averageRating(wallpaperID: String) async throws -> Double {
        let all = try await listAll(wallpaperID: wallpaperID)
        if all.isEmpty { return 0.0 }
        let sum = all.map { Double($0.score) }.reduce(0, +)
        return sum / Double(all.count)
    }

    /// 全評価をリスト取得。
    func listAll(wallpaperID: String) async throws -> [Rating] {
        let collectionPath = subcollectionPath(wallpaperID: wallpaperID)
        let query: [String: Any] = [
            "from": [["collectionId": "ratings"]],
            "limit": 500,
        ]
        let parent = "\(CommunityGalleryService.collection)/\(wallpaperID)"
        let docs = try await firestore.query(parent: parent, query: query)
        _ = collectionPath  // 警告抑制 (パスは parent に集約)
        return docs.compactMap { Self.parse($0) }
    }

    // MARK: - 内部ヘルパー

    private func subcollectionPath(wallpaperID: String) -> String {
        return "\(CommunityGalleryService.collection)/\(wallpaperID)/ratings"
    }

    static func parse(_ doc: RustFirebase.FirestoreDocument) -> Rating? {
        let userID = (doc.fields["userId"] as? [String: Any])?["stringValue"] as? String ?? ""
        let scoreStr = (doc.fields["score"] as? [String: Any])?["integerValue"] as? String ?? "0"
        let score = Int(scoreStr) ?? 0
        let ts = (doc.fields["createdAt"] as? [String: Any])?["timestampValue"] as? String
        let date = ts.flatMap { CommunityGalleryService.iso8601Formatter.date(from: $0) }
        return Rating(userID: userID, score: score, createdAt: date)
    }
}

/// `RustFirebase.Firestore` 直結アダプタ (本番デフォルト)。
/// Why: RatingService / CommentService どちらも同じ抽象を使う。
struct DefaultFirestoreAdapter: CommunityGalleryService.FirestoreOperator {
    static let shared = DefaultFirestoreAdapter()

    func create(collection: String, docId: String?, fields: [String: Any]) async throws -> RustFirebase.FirestoreDocument {
        try await RustFirebase.Firestore.create(collection: collection, docId: docId, fields: fields)
    }
    func update(collection: String, docId: String, fields: [String: Any], updateMask: [String]?) async throws -> RustFirebase.FirestoreDocument {
        try await RustFirebase.Firestore.update(collection: collection, docId: docId, fields: fields, updateMask: updateMask)
    }
    func delete(collection: String, docId: String) async throws {
        try await RustFirebase.Firestore.delete(collection: collection, docId: docId)
    }
    func query(parent: String, query: [String: Any]) async throws -> [RustFirebase.FirestoreDocument] {
        try await RustFirebase.Firestore.query(parent: parent, query: query)
    }
    func get(collection: String, docId: String) async throws -> RustFirebase.FirestoreDocument {
        try await RustFirebase.Firestore.get(collection: collection, docId: docId)
    }
}
