import Foundation

/// Phase 10C: 公開壁紙へのコメント。
/// パス: `community_wallpapers/<wallpaperID>/comments/<commentID>`
@MainActor
final class CommentService {

    enum CommentError: LocalizedError {
        case notAuthenticated
        case bodyEmpty

        var errorDescription: String? {
            switch self {
            case .notAuthenticated: return "サインインが必要です"
            case .bodyEmpty: return "コメント本文を入力してください"
            }
        }
    }

    struct Comment: Identifiable, Equatable {
        let id: String
        let userID: String
        let body: String
        let createdAt: Date?
    }

    private let firestore: CommunityGalleryService.FirestoreOperator
    private let userIDProvider: @Sendable () -> String?
    /// 新規コメント ID 生成。テストで決定論的にするため差し替え可能。
    private let commentIDGenerator: @Sendable () -> String

    init(
        firestore: CommunityGalleryService.FirestoreOperator,
        userIDProvider: @escaping @Sendable () -> String?,
        commentIDGenerator: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.firestore = firestore
        self.userIDProvider = userIDProvider
        self.commentIDGenerator = commentIDGenerator
    }

    static func makeDefault() -> CommentService {
        return CommentService(
            firestore: DefaultFirestoreAdapter.shared,
            userIDProvider: { AuthManager.shared.currentUID }
        )
    }

    /// 新規コメントを投稿する。
    @discardableResult
    func post(wallpaperID: String, body: String) async throws -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw CommentError.bodyEmpty
        }
        guard let uid = userIDProvider() else {
            throw CommentError.notAuthenticated
        }
        let collectionPath = subcollectionPath(wallpaperID: wallpaperID)
        let commentID = commentIDGenerator()
        let nowIso = CommunityGalleryService.iso8601Formatter.string(from: Date())
        let fields: [String: Any] = [
            "userId": ["stringValue": uid],
            "body": ["stringValue": trimmed],
            "createdAt": ["timestampValue": nowIso],
        ]
        _ = try await firestore.create(collection: collectionPath, docId: commentID, fields: fields)
        return commentID
    }

    /// コメント一覧を取得する。
    func list(wallpaperID: String, limit: Int = 100) async throws -> [Comment] {
        let parent = "\(CommunityGalleryService.collection)/\(wallpaperID)"
        let query: [String: Any] = [
            "from": [["collectionId": "comments"]],
            "limit": limit,
            "orderBy": [[
                "field": ["fieldPath": "createdAt"],
                "direction": "DESCENDING",
            ]]
        ]
        let docs = try await firestore.query(parent: parent, query: query)
        return docs.compactMap { Self.parse($0) }
    }

    /// コメントを削除する。
    func delete(wallpaperID: String, commentID: String) async throws {
        let collectionPath = subcollectionPath(wallpaperID: wallpaperID)
        try await firestore.delete(collection: collectionPath, docId: commentID)
    }

    // MARK: - 内部ヘルパー

    private func subcollectionPath(wallpaperID: String) -> String {
        return "\(CommunityGalleryService.collection)/\(wallpaperID)/comments"
    }

    static func parse(_ doc: RustFirebase.FirestoreDocument) -> Comment? {
        let id = CommunityGalleryService.extractDocID(from: doc.name)
        let userID = (doc.fields["userId"] as? [String: Any])?["stringValue"] as? String ?? ""
        let body = (doc.fields["body"] as? [String: Any])?["stringValue"] as? String ?? ""
        let ts = (doc.fields["createdAt"] as? [String: Any])?["timestampValue"] as? String
        let date = ts.flatMap { CommunityGalleryService.iso8601Formatter.date(from: $0) }
        return Comment(id: id, userID: userID, body: body, createdAt: date)
    }
}
