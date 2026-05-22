import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

/// Phase 10B: CloudKit private database を使ったプライベート同期。
///
/// 同期対象:
///   - お気に入り (favorites)
///   - コレクション (collections)
///   - スケジュール (schedules)
///   - ブラシプリセット (brush_presets)
///
/// 衝突解決: server-wins (CloudKit のサーバ側レコードを優先)。
/// オフライン時: ローカルに `pendingChanges` キューを溜め、再接続時に flush する。
///
/// 注意: CloudKit Container は Apple Developer Console で
///   `iCloud.com.artia.app` を作成する必要がある。コードは push 可能だが
///   実機テスト前に Console 設定が必須。
@MainActor
final class CloudKitSyncManager: ObservableObject {

    // MARK: - レコードタイプ

    /// CloudKit RecordType。文字列をそのまま CKRecord の type として使う。
    enum RecordType: String, CaseIterable {
        case favorite = "Favorite"          // お気に入り (1 wallpaper id ごと)
        case collection = "WallpaperCollection"
        case schedule = "Schedule"
        case brushPreset = "BrushPreset"
    }

    // MARK: - 操作モデル

    /// 同期対象の汎用レコード。CloudKit と独立した形で表現する (CloudKit 不在環境でもテスト可)。
    struct SyncRecord: Equatable {
        let id: String
        let type: RecordType
        /// JSON シリアライズされたペイロード (CKRecord の `payload` フィールドに格納)
        let payload: Data
        /// 最終更新 (server-wins 判定で使用)
        let modifiedAt: Date
    }

    /// オフラインキューのアイテム。
    struct PendingChange: Equatable {
        enum Operation: String { case upsert, delete }
        let operation: Operation
        let record: SyncRecord
    }

    // MARK: - プロトコル (CloudKit 抽象化)

    /// CloudKit operations を抽象化したプロトコル。
    /// Why: 単体テストで CloudKit 不要にしたい + ネットワーク不在環境を表現したい。
    protocol RemoteStore {
        /// レコードを upsert する。
        func save(_ record: SyncRecord) async throws
        /// レコードを削除する。
        func delete(id: String, type: RecordType) async throws
        /// 指定タイプのレコードをすべて取得する。
        func fetchAll(type: RecordType) async throws -> [SyncRecord]
        /// 接続可能かどうか (オフライン判定)。
        var isAvailable: Bool { get }
    }

    // MARK: - 状態

    /// オフラインキュー (in-memory)。
    @Published private(set) var pendingChanges: [PendingChange] = []
    /// 同期中フラグ。
    @Published private(set) var isSyncing: Bool = false
    /// 直近の同期エラー。
    @Published var lastError: String?

    private let remote: RemoteStore

    init(remote: RemoteStore) {
        self.remote = remote
    }

    // MARK: - 公開 API

    /// レコードを upsert する。オフラインなら queue に積む。
    func upsert(_ record: SyncRecord) async {
        if remote.isAvailable {
            do {
                try await remote.save(record)
            } catch {
                lastError = error.localizedDescription
                pendingChanges.append(PendingChange(operation: .upsert, record: record))
            }
        } else {
            pendingChanges.append(PendingChange(operation: .upsert, record: record))
        }
    }

    /// レコードを削除する。オフラインなら queue に積む。
    func delete(id: String, type: RecordType, dummyPayload: Data = Data()) async {
        let stub = SyncRecord(id: id, type: type, payload: dummyPayload, modifiedAt: Date())
        if remote.isAvailable {
            do {
                try await remote.delete(id: id, type: type)
            } catch {
                lastError = error.localizedDescription
                pendingChanges.append(PendingChange(operation: .delete, record: stub))
            }
        } else {
            pendingChanges.append(PendingChange(operation: .delete, record: stub))
        }
    }

    /// オフラインキューをサーバへ flush する。再接続後に呼ぶ。
    func flushPending() async {
        guard remote.isAvailable, !pendingChanges.isEmpty else { return }
        isSyncing = true
        defer { isSyncing = false }

        var remaining: [PendingChange] = []
        for change in pendingChanges {
            do {
                switch change.operation {
                case .upsert:
                    try await remote.save(change.record)
                case .delete:
                    try await remote.delete(id: change.record.id, type: change.record.type)
                }
            } catch {
                lastError = error.localizedDescription
                remaining.append(change)
            }
        }
        pendingChanges = remaining
    }

    /// サーバから引っ張って server-wins でローカルへ反映するシンプルな pull。
    /// - Parameter type: 取得対象のレコードタイプ
    /// - Returns: サーバ側の最新レコード一覧 (呼び出し側でローカルへ書き込む)
    func pull(type: RecordType) async throws -> [SyncRecord] {
        guard remote.isAvailable else { return [] }
        return try await remote.fetchAll(type: type)
    }

    /// すべてのレコードタイプを順次 pull する便利メソッド。
    func pullAll() async throws -> [RecordType: [SyncRecord]] {
        var result: [RecordType: [SyncRecord]] = [:]
        for type in RecordType.allCases {
            result[type] = (try? await pull(type: type)) ?? []
        }
        return result
    }

    /// server-wins の衝突解決ヘルパー。
    /// - Parameters:
    ///   - localRecords: ローカル側のレコード
    ///   - serverRecords: サーバ側のレコード
    /// - Returns: マージ結果 (server-wins: 同じ id があればサーバを優先する)
    nonisolated static func resolveConflicts(
        localRecords: [SyncRecord],
        serverRecords: [SyncRecord]
    ) -> [SyncRecord] {
        var byID: [String: SyncRecord] = [:]
        for r in localRecords { byID[r.id] = r }
        for r in serverRecords { byID[r.id] = r } // server overrides
        return Array(byID.values).sorted { $0.id < $1.id }
    }

    // MARK: - 変換ヘルパー

    /// JSON Encodable なペイロードから SyncRecord を作る。
    static func makeRecord<T: Encodable>(
        id: String,
        type: RecordType,
        payload: T,
        modifiedAt: Date = Date()
    ) throws -> SyncRecord {
        let data = try JSONEncoder().encode(payload)
        return SyncRecord(id: id, type: type, payload: data, modifiedAt: modifiedAt)
    }

    /// SyncRecord のペイロードを JSON Decodable にデコードする。
    static func decode<T: Decodable>(_ type: T.Type, from record: SyncRecord) throws -> T {
        return try JSONDecoder().decode(type, from: record.payload)
    }
}

// MARK: - CloudKit 実装

#if canImport(CloudKit)

/// CloudKit private database 経由の RemoteStore 実装。
/// Why: CKContainer.default() は実機サインイン状態が必要だが、
///      コード自体はビルド可能。テストではモックに差し替える。
struct CloudKitRemoteStore: CloudKitSyncManager.RemoteStore {

    /// CloudKit ペイロード用フィールド名 (CKRecord キー)
    private static let payloadField = "payload"
    private static let modifiedField = "modifiedAt"

    let containerIdentifier: String?
    let database: CKDatabase
    let isAvailable: Bool

    /// `iCloud.com.artia.app` を expected container として初期化する。
    /// - Note: containerIdentifier nil で `default()` を使う。
    init(containerIdentifier: String? = "iCloud.com.artia.app", isAvailable: Bool = true) {
        self.containerIdentifier = containerIdentifier
        let container: CKContainer
        if let id = containerIdentifier {
            container = CKContainer(identifier: id)
        } else {
            container = CKContainer.default()
        }
        self.database = container.privateCloudDatabase
        self.isAvailable = isAvailable
    }

    func save(_ record: CloudKitSyncManager.SyncRecord) async throws {
        let recordID = CKRecord.ID(recordName: record.id)
        let ckRecord = CKRecord(recordType: record.type.rawValue, recordID: recordID)
        ckRecord[Self.payloadField] = record.payload as NSData
        ckRecord[Self.modifiedField] = record.modifiedAt as NSDate
        try await database.save(ckRecord)
    }

    func delete(id: String, type: CloudKitSyncManager.RecordType) async throws {
        let recordID = CKRecord.ID(recordName: id)
        try await database.deleteRecord(withID: recordID)
    }

    func fetchAll(type: CloudKitSyncManager.RecordType) async throws -> [CloudKitSyncManager.SyncRecord] {
        let query = CKQuery(recordType: type.rawValue, predicate: NSPredicate(value: true))
        let result = try await database.records(matching: query)
        var output: [CloudKitSyncManager.SyncRecord] = []
        for (_, recordResult) in result.matchResults {
            switch recordResult {
            case .success(let record):
                guard let data = record[Self.payloadField] as? Data else { continue }
                let date = (record[Self.modifiedField] as? Date) ?? record.modificationDate ?? Date()
                output.append(CloudKitSyncManager.SyncRecord(
                    id: record.recordID.recordName,
                    type: type,
                    payload: data,
                    modifiedAt: date
                ))
            case .failure:
                continue
            }
        }
        return output
    }
}

#endif
