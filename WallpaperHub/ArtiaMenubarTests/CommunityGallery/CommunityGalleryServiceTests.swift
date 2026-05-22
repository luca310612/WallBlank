import XCTest
import Foundation

@testable import WallBlank

/// Phase 10E: CommunityGalleryService の publish/list/download ラウンドトリップ。
/// Firebase 実体には触れず、Firestore / Storage のモック経由で検証する。
@MainActor
final class CommunityGalleryServiceTests: XCTestCase {

    // MARK: - モック

    final class MockFirestore: CommunityGalleryService.FirestoreOperator {
        /// (collection, docId) → fields
        var documents: [String: [String: [String: Any]]] = [:]
        var createCalls: [(String, String?, [String: Any])] = []
        var deleteCalls: [(String, String)] = []

        func create(collection: String, docId: String?, fields: [String: Any]) async throws -> RustFirebase.FirestoreDocument {
            createCalls.append((collection, docId, fields))
            let id = docId ?? UUID().uuidString
            documents[collection, default: [:]][id] = fields
            return RustFirebase.FirestoreDocument(
                name: "projects/test/databases/(default)/documents/\(collection)/\(id)",
                fields: fields,
                createTime: nil,
                updateTime: nil
            )
        }
        func update(collection: String, docId: String, fields: [String: Any], updateMask: [String]?) async throws -> RustFirebase.FirestoreDocument {
            // updateMask に含まれるフィールドだけを更新する (server-wins では partial update がより自然)
            var current = documents[collection]?[docId] ?? [:]
            if let mask = updateMask, !mask.isEmpty {
                for key in mask {
                    if let v = fields[key] { current[key] = v }
                }
            } else {
                for (k, v) in fields { current[k] = v }
            }
            documents[collection, default: [:]][docId] = current
            return RustFirebase.FirestoreDocument(
                name: "projects/test/databases/(default)/documents/\(collection)/\(docId)",
                fields: current,
                createTime: nil,
                updateTime: nil
            )
        }
        func delete(collection: String, docId: String) async throws {
            deleteCalls.append((collection, docId))
            documents[collection]?.removeValue(forKey: docId)
        }
        func query(parent: String, query: [String: Any]) async throws -> [RustFirebase.FirestoreDocument] {
            // テストでは単純に最初の collectionId に該当するドキュメント全件を返す。
            guard let from = query["from"] as? [[String: Any]],
                  let first = from.first,
                  let cid = first["collectionId"] as? String else {
                return []
            }
            // parent が community_wallpapers/<id> 形式ならサブコレクションキーとして組み立てる
            let key: String
            if parent.isEmpty {
                key = cid
            } else {
                key = "\(parent)/\(cid)"
            }
            return (documents[key] ?? [:]).map { (id, fields) in
                RustFirebase.FirestoreDocument(
                    name: "projects/test/databases/(default)/documents/\(key)/\(id)",
                    fields: fields,
                    createTime: nil,
                    updateTime: nil
                )
            }
        }
        func get(collection: String, docId: String) async throws -> RustFirebase.FirestoreDocument {
            guard let fields = documents[collection]?[docId] else {
                throw NSError(domain: "MockFirestore", code: 404, userInfo: [NSLocalizedDescriptionKey: "not found"])
            }
            return RustFirebase.FirestoreDocument(
                name: "projects/test/databases/(default)/documents/\(collection)/\(docId)",
                fields: fields,
                createTime: nil,
                updateTime: nil
            )
        }
    }

    final class MockStorage: CommunityGalleryService.StorageOperator {
        var blobs: [String: Data] = [:]
        func upload(path: String, data: Data, contentType: String) async throws -> String {
            blobs[path] = data
            return "{\"name\":\"\(path)\",\"size\":\(data.count)}"
        }
        func download(path: String) async throws -> Data {
            guard let d = blobs[path] else {
                throw NSError(domain: "MockStorage", code: 404)
            }
            return d
        }
        func delete(path: String) async throws {
            blobs.removeValue(forKey: path)
        }
    }

    var firestore: MockFirestore!
    var storage: MockStorage!
    var service: CommunityGalleryService!

    override func setUp() {
        super.setUp()
        firestore = MockFirestore()
        storage = MockStorage()
        service = CommunityGalleryService(
            firestore: firestore,
            storage: storage,
            authorIDProvider: { "uid-test" }
        )
        service.downloadDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("artia-community-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: service.downloadDirectory)
        service = nil
        firestore = nil
        storage = nil
        super.tearDown()
    }

    // MARK: - publish

    func test_publish_uploadsAndCreatesDocument() async throws {
        let item = WallpaperItem(
            id: "wp-001",
            name: "夜空",
            type: .scene,
            thumbnailName: "thumb.png"
        )
        let preview = "preview-bytes".data(using: .utf8)!
        let archive = "zip-bytes".data(using: .utf8)!

        let id = try await service.publish(
            wallpaper: item,
            title: "オーロラ",
            description: "夜空の壁紙",
            tags: ["aurora", "夜"],
            previewImage: preview,
            archiveData: archive
        )
        XCTAssertEqual(id, "wp-001")

        // Storage にアップロードされている
        XCTAssertEqual(storage.blobs["community/wp-001/preview.jpg"], preview)
        XCTAssertEqual(storage.blobs["community/wp-001/wallpaper.zip"], archive)

        // Firestore に作成されている
        let fields = firestore.documents["community_wallpapers"]?["wp-001"]
        XCTAssertNotNil(fields)
        XCTAssertEqual((fields?["title"] as? [String: Any])?["stringValue"] as? String, "オーロラ")
        XCTAssertEqual((fields?["type"] as? [String: Any])?["stringValue"] as? String, "scene")
        XCTAssertEqual((fields?["authorID"] as? [String: Any])?["stringValue"] as? String, "uid-test")
    }

    func test_publish_fails_whenUnauthenticated() async {
        let svc = CommunityGalleryService(
            firestore: firestore, storage: storage,
            authorIDProvider: { nil }
        )
        let item = WallpaperItem(id: "x", name: "n", type: .image, thumbnailName: "t")
        do {
            _ = try await svc.publish(
                wallpaper: item, title: "t", description: "d", tags: [],
                previewImage: Data(), archiveData: Data()
            )
            XCTFail("認証エラーが期待される")
        } catch let CommunityGalleryService.ServiceError.notAuthenticated {
            // ok
        } catch {
            XCTFail("想定外のエラー: \(error)")
        }
    }

    // MARK: - list

    func test_list_returnsParsedDocuments() async throws {
        // 直接 Firestore モックに 2 件入れる
        let now = CommunityGalleryService.iso8601Formatter.string(from: Date())
        firestore.documents["community_wallpapers"] = [
            "a": CommunityGalleryService.fieldsPayload(
                title: "A", description: "", tags: ["x"], type: "scene",
                previewURL: "p/a", downloadURL: "d/a", authorID: "u",
                createdAtISO: now, downloads: 3, rating: 4.5, ratingCount: 2
            ),
            "b": CommunityGalleryService.fieldsPayload(
                title: "B", description: "", tags: ["y"], type: "video",
                previewURL: "p/b", downloadURL: "d/b", authorID: "u",
                createdAtISO: now, downloads: 0, rating: 0.0, ratingCount: 0
            ),
        ]
        let list = try await service.list()
        XCTAssertEqual(list.count, 2)
        let titles = Set(list.map { $0.title })
        XCTAssertEqual(titles, ["A", "B"])
        let a = list.first { $0.id == "a" }
        XCTAssertEqual(a?.downloads, 3)
        XCTAssertEqual(a?.rating ?? 0, 4.5, accuracy: 0.001)
        XCTAssertEqual(a?.ratingCount, 2)
        XCTAssertEqual(a?.tags, ["x"])
    }

    // MARK: - download

    func test_download_writesArchiveAndIncrementsCounter() async throws {
        // publish 経由で 1 件登録する
        let item = WallpaperItem(id: "dl-1", name: "n", type: .image, thumbnailName: "t")
        _ = try await service.publish(
            wallpaper: item, title: "t", description: "d", tags: [],
            previewImage: Data("p".utf8), archiveData: Data("zip!".utf8)
        )

        let url = try await service.download(id: "dl-1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let saved = try Data(contentsOf: url)
        XCTAssertEqual(saved, Data("zip!".utf8))

        // Firestore 側のダウンロードカウンタ +1 (background Task なので少し待つ)
        try await Task.sleep(nanoseconds: 200_000_000)
        let fields = firestore.documents["community_wallpapers"]?["dl-1"]
        let downloads = (fields?["downloads"] as? [String: Any])?["integerValue"] as? String
        XCTAssertEqual(downloads, "1")
    }

    // MARK: - unpublish

    func test_unpublish_deletesEverything() async throws {
        let item = WallpaperItem(id: "del-1", name: "n", type: .video, thumbnailName: "t")
        _ = try await service.publish(
            wallpaper: item, title: "t", description: "", tags: [],
            previewImage: Data("p".utf8), archiveData: Data("z".utf8)
        )
        try await service.unpublish(id: "del-1")
        XCTAssertNil(firestore.documents["community_wallpapers"]?["del-1"])
        XCTAssertNil(storage.blobs["community/del-1/preview.jpg"])
        XCTAssertNil(storage.blobs["community/del-1/wallpaper.zip"])
    }

    // MARK: - typeString マッピング

    func test_typeString_mapping() {
        XCTAssertEqual(CommunityGalleryService.typeString(for: .scene), "scene")
        XCTAssertEqual(CommunityGalleryService.typeString(for: .video), "video")
        XCTAssertEqual(CommunityGalleryService.typeString(for: .image), "image")
        XCTAssertEqual(CommunityGalleryService.typeString(for: .gif), "video")
        XCTAssertEqual(CommunityGalleryService.typeString(for: .shader), "scene")
    }
}
