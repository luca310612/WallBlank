import XCTest
import Foundation

@testable import Artia

/// Phase 10E: CloudKitSyncManager のレコード変換 + 衝突解決 + オフラインキューを検証する。
/// CloudKit 実体は呼ばず、`RemoteStore` プロトコルのモックで決定論的に検証。
@MainActor
final class CloudKitSyncManagerTests: XCTestCase {

    final class MockRemote: CloudKitSyncManager.RemoteStore {
        var saved: [String: CloudKitSyncManager.SyncRecord] = [:]
        var deleted: [(String, CloudKitSyncManager.RecordType)] = []
        var saveError: Error?
        var deleteError: Error?
        var isAvailable: Bool = true

        func save(_ record: CloudKitSyncManager.SyncRecord) async throws {
            if let saveError { throw saveError }
            saved[record.id] = record
        }
        func delete(id: String, type: CloudKitSyncManager.RecordType) async throws {
            if let deleteError { throw deleteError }
            deleted.append((id, type))
            saved.removeValue(forKey: id)
        }
        func fetchAll(type: CloudKitSyncManager.RecordType) async throws -> [CloudKitSyncManager.SyncRecord] {
            return saved.values.filter { $0.type == type }
        }
    }

    var remote: MockRemote!
    var manager: CloudKitSyncManager!

    override func setUp() {
        super.setUp()
        remote = MockRemote()
        manager = CloudKitSyncManager(remote: remote)
    }

    override func tearDown() {
        manager = nil
        remote = nil
        super.tearDown()
    }

    // MARK: - レコード変換

    struct SamplePayload: Codable, Equatable {
        let name: String
        let count: Int
    }

    func test_makeRecord_encodesPayload() throws {
        let payload = SamplePayload(name: "α", count: 3)
        let record = try CloudKitSyncManager.makeRecord(
            id: "id-1",
            type: .favorite,
            payload: payload
        )
        XCTAssertEqual(record.id, "id-1")
        XCTAssertEqual(record.type, .favorite)
        let decoded = try CloudKitSyncManager.decode(SamplePayload.self, from: record)
        XCTAssertEqual(decoded, payload)
    }

    // MARK: - upsert / delete (online)

    func test_upsert_savesToRemote_whenAvailable() async throws {
        let record = try CloudKitSyncManager.makeRecord(
            id: "fav-1", type: .favorite,
            payload: SamplePayload(name: "x", count: 1)
        )
        await manager.upsert(record)
        XCTAssertEqual(remote.saved["fav-1"]?.id, "fav-1")
        XCTAssertTrue(manager.pendingChanges.isEmpty)
    }

    func test_delete_removesFromRemote_whenAvailable() async throws {
        let record = try CloudKitSyncManager.makeRecord(
            id: "fav-2", type: .favorite,
            payload: SamplePayload(name: "y", count: 0)
        )
        await manager.upsert(record)
        await manager.delete(id: "fav-2", type: .favorite)
        XCTAssertNil(remote.saved["fav-2"])
        XCTAssertEqual(remote.deleted.first?.0, "fav-2")
    }

    // MARK: - オフラインキュー

    func test_upsert_queues_whenOffline() async throws {
        remote.isAvailable = false
        let record = try CloudKitSyncManager.makeRecord(
            id: "off-1", type: .schedule,
            payload: SamplePayload(name: "z", count: 0)
        )
        await manager.upsert(record)
        XCTAssertNil(remote.saved["off-1"])
        XCTAssertEqual(manager.pendingChanges.count, 1)
        XCTAssertEqual(manager.pendingChanges.first?.operation, .upsert)
    }

    func test_flushPending_sendsAllQueuedChanges() async throws {
        remote.isAvailable = false
        let r1 = try CloudKitSyncManager.makeRecord(
            id: "q-1", type: .collection, payload: SamplePayload(name: "a", count: 1)
        )
        let r2 = try CloudKitSyncManager.makeRecord(
            id: "q-2", type: .brushPreset, payload: SamplePayload(name: "b", count: 2)
        )
        await manager.upsert(r1)
        await manager.upsert(r2)
        await manager.delete(id: "q-1", type: .collection)
        XCTAssertEqual(manager.pendingChanges.count, 3)

        // 接続復帰 → flush
        remote.isAvailable = true
        await manager.flushPending()
        XCTAssertTrue(manager.pendingChanges.isEmpty)
        XCTAssertEqual(remote.saved["q-2"]?.id, "q-2")
        XCTAssertNil(remote.saved["q-1"])  // 削除も適用された
        XCTAssertTrue(remote.deleted.contains { $0.0 == "q-1" })
    }

    func test_flushPending_keepsFailedItems() async throws {
        let r = try CloudKitSyncManager.makeRecord(
            id: "fail-1", type: .favorite, payload: SamplePayload(name: "f", count: 0)
        )
        remote.isAvailable = false
        await manager.upsert(r)

        remote.isAvailable = true
        remote.saveError = NSError(domain: "test", code: 500, userInfo: [NSLocalizedDescriptionKey: "boom"])
        await manager.flushPending()
        XCTAssertEqual(manager.pendingChanges.count, 1)
        XCTAssertEqual(manager.lastError, "boom")
    }

    // MARK: - 衝突解決 (server-wins)

    func test_resolveConflicts_serverWinsOnSameID() {
        let now = Date()
        let local = [
            CloudKitSyncManager.SyncRecord(id: "a", type: .favorite, payload: Data("local-a".utf8), modifiedAt: now),
            CloudKitSyncManager.SyncRecord(id: "b", type: .favorite, payload: Data("local-b".utf8), modifiedAt: now),
        ]
        let server = [
            CloudKitSyncManager.SyncRecord(id: "a", type: .favorite, payload: Data("server-a".utf8), modifiedAt: now),
            CloudKitSyncManager.SyncRecord(id: "c", type: .favorite, payload: Data("server-c".utf8), modifiedAt: now),
        ]
        let merged = CloudKitSyncManager.resolveConflicts(localRecords: local, serverRecords: server)
        // a: server, b: local, c: server
        let byID = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0.payload) })
        XCTAssertEqual(byID["a"], Data("server-a".utf8))
        XCTAssertEqual(byID["b"], Data("local-b".utf8))
        XCTAssertEqual(byID["c"], Data("server-c".utf8))
        XCTAssertEqual(merged.map { $0.id }, ["a", "b", "c"])
    }

    // MARK: - pull

    func test_pullAll_returnsAllRecordTypes() async throws {
        let fav = try CloudKitSyncManager.makeRecord(
            id: "f", type: .favorite, payload: SamplePayload(name: "f", count: 0)
        )
        let col = try CloudKitSyncManager.makeRecord(
            id: "c", type: .collection, payload: SamplePayload(name: "c", count: 1)
        )
        await manager.upsert(fav)
        await manager.upsert(col)

        let result = try await manager.pullAll()
        XCTAssertEqual(result[.favorite]?.count, 1)
        XCTAssertEqual(result[.collection]?.count, 1)
        XCTAssertEqual(result[.schedule]?.count ?? -1, 0)
        XCTAssertEqual(result[.brushPreset]?.count ?? -1, 0)
    }
}
