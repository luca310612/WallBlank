import Foundation
import AppKit

/// Phase 10A: Firebase ベースの公開ギャラリー。
///
/// 設計方針:
///   - 既存 `RustFirebase.Firestore` / `.Storage` 経由のみで Firebase へアクセスする
///     (Firebase iOS SDK は使わない)
///   - スキーマ:
///     Firestore "community_wallpapers" コレクション
///       doc_id = wallpaper UUID
///       fields:
///         - title (String)
///         - description (String)
///         - tags ([String])
///         - type (String): "scene" / "video" / "web" / "app"
///         - previewURL (String): Storage 上の preview.jpg のパス
///         - downloadURL (String): Storage 上の wallpaper.zip のパス
///         - authorID (String): Firebase Auth uid
///         - createdAt (Timestamp): 公開日時
///         - downloads (Int): 累計ダウンロード数
///         - rating (Double): 平均評価
///         - ratingCount (Int): 評価数
///     Storage:
///       community/<id>/preview.jpg
///       community/<id>/wallpaper.zip
///
/// テスト容易性のため、Firestore / Storage のオペレーションは
/// `FirestoreOperator` / `StorageOperator` プロトコル経由で差し替え可能にしている。
@MainActor
final class CommunityGalleryService: ObservableObject {

    // MARK: - 公開モデル

    /// Firestore 上の公開壁紙レコード。`fields` のタグ付き JSON から復元する。
    struct CommunityWallpaper: Identifiable, Equatable {
        let id: String
        var title: String
        var description: String
        var tags: [String]
        var type: String
        var previewURL: String
        var downloadURL: String
        var authorID: String
        var downloads: Int
        var rating: Double
        var ratingCount: Int
        var createdAt: Date?

        var displayType: String {
            switch type {
            case "scene": return "シーン"
            case "video": return "動画"
            case "web": return "Web"
            case "app": return "アプリ"
            default: return type
            }
        }
    }

    /// 検索クエリ。タグ検索 + ページング + ソート。
    struct GalleryQuery: Equatable {
        var tag: String?
        var type: String?
        var orderBy: OrderBy = .createdAtDesc
        var limit: Int = 50

        enum OrderBy: String, Equatable {
            case createdAtDesc
            case ratingDesc
            case downloadsDesc

            /// Firestore StructuredQuery の orderBy へ変換するキー。
            var fieldName: String {
                switch self {
                case .createdAtDesc: return "createdAt"
                case .ratingDesc: return "rating"
                case .downloadsDesc: return "downloads"
                }
            }
        }
    }

    // MARK: - 依存性

    /// Firestore 抽象化。`RustFirebase.Firestore` を本番では渡す。
    protocol FirestoreOperator {
        func create(collection: String, docId: String?, fields: [String: Any]) async throws -> RustFirebase.FirestoreDocument
        func update(collection: String, docId: String, fields: [String: Any], updateMask: [String]?) async throws -> RustFirebase.FirestoreDocument
        func delete(collection: String, docId: String) async throws
        func query(parent: String, query: [String: Any]) async throws -> [RustFirebase.FirestoreDocument]
        func get(collection: String, docId: String) async throws -> RustFirebase.FirestoreDocument
    }

    /// Storage 抽象化。`RustFirebase.Storage` を本番では渡す。
    protocol StorageOperator {
        func upload(path: String, data: Data, contentType: String) async throws -> String
        func download(path: String) async throws -> Data
        func delete(path: String) async throws
    }

    private let firestore: FirestoreOperator
    private let storage: StorageOperator
    /// 認証済みユーザの uid を返す。`AuthManager.shared.currentUID` を本番では渡す。
    private let authorIDProvider: @Sendable () -> String?

    // MARK: - 状態

    @Published private(set) var wallpapers: [CommunityWallpaper] = []
    @Published private(set) var isLoading: Bool = false
    @Published var lastError: String?

    /// ローカルライブラリへの保存先 (デフォルトは Application Support/WallBlank/Community)
    var downloadDirectory: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("WallBlank/Community", isDirectory: true)
    }()

    // MARK: - 初期化

    init(
        firestore: FirestoreOperator,
        storage: StorageOperator,
        authorIDProvider: @escaping @Sendable () -> String?
    ) {
        self.firestore = firestore
        self.storage = storage
        self.authorIDProvider = authorIDProvider
    }

    /// 本番用ファクトリ。RustFirebase ラッパー + AuthManager の uid を使う。
    static func makeDefault() -> CommunityGalleryService {
        return CommunityGalleryService(
            firestore: RustFirebaseFirestoreAdapter(),
            storage: RustFirebaseStorageAdapter(),
            authorIDProvider: { AuthManager.shared.currentUID }
        )
    }

    // MARK: - 定数

    static let collection = "community_wallpapers"
    static let storagePrefix = "community"

    // MARK: - 公開 API

    /// 公開する。preview/zip を Storage へアップロードしたあと、Firestore レコードを作成する。
    /// - Returns: 生成された wallpaper ID
    @discardableResult
    func publish(
        wallpaper: WallpaperItem,
        title: String,
        description: String,
        tags: [String],
        previewImage: Data,
        archiveData: Data
    ) async throws -> String {
        guard let authorID = authorIDProvider() else {
            throw ServiceError.notAuthenticated
        }
        let id = wallpaper.id
        let previewPath = "\(Self.storagePrefix)/\(id)/preview.jpg"
        let archivePath = "\(Self.storagePrefix)/\(id)/wallpaper.zip"

        _ = try await storage.upload(path: previewPath, data: previewImage, contentType: "image/jpeg")
        _ = try await storage.upload(path: archivePath, data: archiveData, contentType: "application/zip")

        let nowIso = Self.iso8601Formatter.string(from: Date())
        let fields: [String: Any] = Self.fieldsPayload(
            title: title,
            description: description,
            tags: tags,
            type: Self.typeString(for: wallpaper.type),
            previewURL: previewPath,
            downloadURL: archivePath,
            authorID: authorID,
            createdAtISO: nowIso,
            downloads: 0,
            rating: 0.0,
            ratingCount: 0
        )

        _ = try await firestore.create(collection: Self.collection, docId: id, fields: fields)
        return id
    }

    /// 非公開化。Storage と Firestore レコードを削除する。
    func unpublish(id: String) async throws {
        let previewPath = "\(Self.storagePrefix)/\(id)/preview.jpg"
        let archivePath = "\(Self.storagePrefix)/\(id)/wallpaper.zip"

        try? await storage.delete(path: previewPath)
        try? await storage.delete(path: archivePath)
        try await firestore.delete(collection: Self.collection, docId: id)
    }

    /// 検索クエリで公開壁紙を取得し、`wallpapers` に格納する。
    func list(query: GalleryQuery = GalleryQuery()) async throws -> [CommunityWallpaper] {
        isLoading = true
        defer { isLoading = false }

        var structuredQuery: [String: Any] = [
            "from": [["collectionId": Self.collection]],
            "limit": query.limit,
        ]
        // orderBy
        let direction = "DESCENDING"
        structuredQuery["orderBy"] = [[
            "field": ["fieldPath": query.orderBy.fieldName],
            "direction": direction,
        ]]
        // where (タグ + type)
        var conditions: [[String: Any]] = []
        if let tag = query.tag, !tag.isEmpty {
            conditions.append([
                "fieldFilter": [
                    "field": ["fieldPath": "tags"],
                    "op": "ARRAY_CONTAINS",
                    "value": ["stringValue": tag],
                ]
            ])
        }
        if let type = query.type, !type.isEmpty {
            conditions.append([
                "fieldFilter": [
                    "field": ["fieldPath": "type"],
                    "op": "EQUAL",
                    "value": ["stringValue": type],
                ]
            ])
        }
        if conditions.count == 1 {
            structuredQuery["where"] = conditions[0]
        } else if conditions.count > 1 {
            structuredQuery["where"] = [
                "compositeFilter": [
                    "op": "AND",
                    "filters": conditions,
                ]
            ]
        }

        let docs = try await firestore.query(parent: "", query: structuredQuery)
        let parsed = docs.compactMap { Self.parseDocument($0) }
        wallpapers = parsed
        return parsed
    }

    /// 指定 ID の壁紙を Storage からダウンロードし、ローカルへ保存して URL を返す。
    /// 同時に Firestore の `downloads` をインクリメントする。
    @discardableResult
    func download(id: String, withinDocument doc: CommunityWallpaper? = nil) async throws -> URL {
        let target: CommunityWallpaper
        if let doc {
            target = doc
        } else {
            target = try await Self.fetchDocument(firestore: firestore, id: id)
        }
        let archiveData = try await storage.download(path: target.downloadURL)

        let dir = downloadDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent("wallpaper.zip")
        try archiveData.write(to: destination, options: .atomic)

        // ダウンロード数を +1
        Task.detached { [firestore = self.firestore] in
            let next = max(0, target.downloads + 1)
            _ = try? await firestore.update(
                collection: Self.collection,
                docId: id,
                fields: ["downloads": ["integerValue": "\(next)"]],
                updateMask: ["downloads"]
            )
        }
        return destination
    }

    // MARK: - エラー

    enum ServiceError: LocalizedError {
        case notAuthenticated
        case documentNotFound

        var errorDescription: String? {
            switch self {
            case .notAuthenticated: return "サインインが必要です"
            case .documentNotFound: return "対象の壁紙が見つかりませんでした"
            }
        }
    }

    // MARK: - 静的ヘルパー

    /// WallpaperType → 公開フォーマットの type 文字列。
    static func typeString(for type: WallpaperType) -> String {
        switch type {
        case .scene, .shader: return "scene"
        case .video, .gif: return "video"
        case .image: return "image"
        case .mediaFolder: return "scene"
        }
    }

    /// Firestore fields ペイロードを組み立てる (Tagged JSON)。
    static func fieldsPayload(
        title: String,
        description: String,
        tags: [String],
        type: String,
        previewURL: String,
        downloadURL: String,
        authorID: String,
        createdAtISO: String,
        downloads: Int,
        rating: Double,
        ratingCount: Int
    ) -> [String: Any] {
        return [
            "title": ["stringValue": title],
            "description": ["stringValue": description],
            "tags": ["arrayValue": ["values": tags.map { ["stringValue": $0] }]],
            "type": ["stringValue": type],
            "previewURL": ["stringValue": previewURL],
            "downloadURL": ["stringValue": downloadURL],
            "authorID": ["stringValue": authorID],
            "createdAt": ["timestampValue": createdAtISO],
            "downloads": ["integerValue": "\(downloads)"],
            "rating": ["doubleValue": rating],
            "ratingCount": ["integerValue": "\(ratingCount)"],
        ]
    }

    /// Firestore Document の name から末尾の docId を取り出す。
    static func extractDocID(from name: String) -> String {
        return name.split(separator: "/").last.map(String.init) ?? name
    }

    /// Firestore Document をデコードする。
    static func parseDocument(_ doc: RustFirebase.FirestoreDocument) -> CommunityWallpaper? {
        let id = extractDocID(from: doc.name)
        let fields = doc.fields
        return CommunityWallpaper(
            id: id,
            title: stringValue(fields, "title") ?? "",
            description: stringValue(fields, "description") ?? "",
            tags: tagsValue(fields, "tags"),
            type: stringValue(fields, "type") ?? "image",
            previewURL: stringValue(fields, "previewURL") ?? "",
            downloadURL: stringValue(fields, "downloadURL") ?? "",
            authorID: stringValue(fields, "authorID") ?? "",
            downloads: integerValue(fields, "downloads") ?? 0,
            rating: doubleValue(fields, "rating") ?? 0.0,
            ratingCount: integerValue(fields, "ratingCount") ?? 0,
            createdAt: timestampValue(fields, "createdAt")
        )
    }

    // MARK: - tagged JSON ユーティリティ

    private static func stringValue(_ fields: [String: Any], _ key: String) -> String? {
        (fields[key] as? [String: Any])?["stringValue"] as? String
    }

    private static func integerValue(_ fields: [String: Any], _ key: String) -> Int? {
        guard let f = fields[key] as? [String: Any] else { return nil }
        if let s = f["integerValue"] as? String { return Int(s) }
        if let n = f["integerValue"] as? NSNumber { return n.intValue }
        return nil
    }

    private static func doubleValue(_ fields: [String: Any], _ key: String) -> Double? {
        guard let f = fields[key] as? [String: Any] else { return nil }
        if let n = f["doubleValue"] as? NSNumber { return n.doubleValue }
        if let s = f["doubleValue"] as? String { return Double(s) }
        return nil
    }

    private static func tagsValue(_ fields: [String: Any], _ key: String) -> [String] {
        guard let f = fields[key] as? [String: Any],
              let arr = f["arrayValue"] as? [String: Any],
              let values = arr["values"] as? [[String: Any]] else { return [] }
        return values.compactMap { $0["stringValue"] as? String }
    }

    private static func timestampValue(_ fields: [String: Any], _ key: String) -> Date? {
        guard let f = fields[key] as? [String: Any],
              let ts = f["timestampValue"] as? String else { return nil }
        return iso8601Formatter.date(from: ts)
    }

    static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// 単一ドキュメントを取得して `CommunityWallpaper` に変換するヘルパー。
    private static func fetchDocument(firestore: FirestoreOperator, id: String) async throws -> CommunityWallpaper {
        let doc = try await firestore.get(collection: collection, docId: id)
        guard let parsed = parseDocument(doc) else {
            throw ServiceError.documentNotFound
        }
        return parsed
    }
}

// MARK: - RustFirebase アダプタ

/// `RustFirebase.Firestore` を `FirestoreOperator` プロトコルに適合させる。
/// Why: 本番経路では Rust 側 REST 実装を使い、テストではモックを差し込めるようにする。
private struct RustFirebaseFirestoreAdapter: CommunityGalleryService.FirestoreOperator {
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

/// `RustFirebase.Storage` を `StorageOperator` プロトコルに適合させる。
private struct RustFirebaseStorageAdapter: CommunityGalleryService.StorageOperator {
    func upload(path: String, data: Data, contentType: String) async throws -> String {
        try await RustFirebase.Storage.upload(path: path, data: data, contentType: contentType)
    }
    func download(path: String) async throws -> Data {
        try await RustFirebase.Storage.download(path: path)
    }
    func delete(path: String) async throws {
        try await RustFirebase.Storage.delete(path: path)
    }
}
