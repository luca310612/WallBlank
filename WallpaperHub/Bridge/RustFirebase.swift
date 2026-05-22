// RustFirebase: artia-firebase (Rust) FFI の Swift ラッパー
// Why: Firebase SDK の代わりに Rust 側 REST 実装を呼び出すための入口。
//      Phase 2D ではまず GalleryManager の限定的な経路 (一覧取得・ダウンロード) で
//      Rust 経由を試行し、失敗時は既存 SDK パスへフォールバックする段階移行戦略を採る。

import Foundation

/// Rust 側 artia-firebase クライアントへの薄い Swift ラッパー。
///
/// 全ての I/O は内部で `Task.detached` + `withCheckedThrowingContinuation` により
/// バックグラウンドスレッドにオフロードされる (Rust 側はブロッキング呼び出し)。
enum RustFirebase {

    // MARK: - エラー型

    /// Rust 側から返ってきたエラー、または橋渡し中に起きた変換エラー。
    enum Error: LocalizedError {
        /// `RustFirebase.initialize` を呼ぶ前に他の API を呼んだ
        case notInitialized
        /// JSON 文字列のエンコード/デコードに失敗
        case decoding(String)
        /// Rust から `{"error": "..."}` が返ってきた
        case rust(String)
        /// FFI 関数が NULL を返した
        case nullReturn(String)

        var errorDescription: String? {
            switch self {
            case .notInitialized:
                return "RustFirebase 未初期化です"
            case .decoding(let detail):
                return "JSON デコードに失敗: \(detail)"
            case .rust(let message):
                return message
            case .nullReturn(let where_):
                return "\(where_): NULL が返されました"
            }
        }
    }

    // MARK: - 設定モデル

    /// Rust 側 FirebaseConfig に渡す JSON ペイロード。
    struct Config: Codable {
        let project_id: String
        let api_key: String
        let storage_bucket: String
        let app_id: String?

        init(projectID: String, apiKey: String, storageBucket: String, appID: String? = nil) {
            self.project_id = projectID
            self.api_key = apiKey
            self.storage_bucket = storageBucket
            self.app_id = appID
        }
    }

    /// Auth セッション (Rust 側 AuthSession の JSON 表現)
    struct AuthSession: Codable {
        /// Firebase ID トークン (JWT)
        let id_token: String
        /// リフレッシュトークン (current_id_token 経由では空)
        let refresh_token: String?
        /// Firebase ローカル ID (uid)
        let local_id: String
        /// 有効期限 (UNIX 秒)。current_id_token では未提供のため Optional。
        let expires_at: TimeInterval?
    }

    /// Firestore Document (簡易表現)
    struct FirestoreDocument {
        /// `projects/<id>/databases/(default)/documents/<col>/<doc_id>` 形式
        let name: String
        /// Tagged JSON 形式のフィールド (例: `["age": ["integerValue": "30"]]`)
        let fields: [String: Any]
        let createTime: String?
        let updateTime: String?

        /// JSON 文字列 (Rust 側 Document) からデコードする。
        static func decode(from json: String) throws -> FirestoreDocument {
            guard let data = json.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Error.decoding(json)
            }
            return try fromDict(object)
        }

        fileprivate static func fromDict(_ dict: [String: Any]) throws -> FirestoreDocument {
            guard let name = dict["name"] as? String else {
                throw Error.decoding("Document.name が不在")
            }
            return FirestoreDocument(
                name: name,
                fields: dict["fields"] as? [String: Any] ?? [:],
                createTime: dict["createTime"] as? String,
                updateTime: dict["updateTime"] as? String
            )
        }
    }

    // MARK: - 初期化

    /// 初期化済みかどうかを記録 (二重 init 防止用)
    private static let initLock = NSLock()
    private static var didInitialize: Bool = false

    /// Rust 側 FirebaseClient を初期化する。二重呼び出しは無視する。
    /// - Parameter config: GoogleService-Info.plist 等から組み立てた `Config`
    static func initialize(config: Config) throws {
        initLock.lock()
        defer { initLock.unlock() }
        if didInitialize { return }

        let data = try JSONEncoder().encode(config)
        guard let json = String(data: data, encoding: .utf8) else {
            throw Error.decoding("Config エンコード失敗")
        }
        let ok = json.withCString { artia_fb_init($0) }
        if !ok {
            throw Error.rust("artia_fb_init が false を返しました (config 不正の可能性)")
        }
        didInitialize = true
        print("[RustFirebase] 初期化完了 (project=\(config.project_id))")
    }

    /// `GoogleService-Info.plist` (Bundle 内) から `Config` を組み立てる。
    /// - Note: plist は Bundle に含まれるリソースであり、Keychain ではないが
    ///   Apple/Google 公式の供給ルートに従う前提で利用する。
    static func loadConfigFromBundle() -> Config? {
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            return nil
        }
        guard let projectID = dict["PROJECT_ID"] as? String,
              let apiKey = dict["API_KEY"] as? String,
              let storageBucket = dict["STORAGE_BUCKET"] as? String else {
            return nil
        }
        let appID = dict["GOOGLE_APP_ID"] as? String
        return Config(projectID: projectID, apiKey: apiKey, storageBucket: storageBucket, appID: appID)
    }

    /// Bundle 同梱 plist から自動で初期化を試みる。失敗しても投げず警告ログのみ。
    /// Why: Phase 2D は段階移行のため、Rust 側 init に失敗しても既存 SDK パスで動かしたい。
    @discardableResult
    static func initializeFromBundleIfPossible() -> Bool {
        guard let config = loadConfigFromBundle() else {
            print("[RustFirebase] GoogleService-Info.plist が読めなかったため初期化スキップ")
            return false
        }
        do {
            try initialize(config: config)
            return true
        } catch {
            print("[RustFirebase] 初期化失敗: \(error.localizedDescription)")
            return false
        }
    }

    /// 初期化済みかどうか。
    static var isInitialized: Bool {
        initLock.lock()
        defer { initLock.unlock() }
        return didInitialize
    }

    // MARK: - Auth

    /// 匿名サインイン
    static func signInAnonymously() async throws -> AuthSession {
        try await detachedFFI("signInAnonymously") {
            artia_fb_auth_sign_in_anonymously()
        } decode: { json in
            try parseSession(json)
        }
    }

    /// カスタムトークンでサインイン
    static func signInWithCustomToken(_ token: String) async throws -> AuthSession {
        try await detachedFFI("signInWithCustomToken") {
            token.withCString { artia_fb_auth_sign_in_with_custom_token($0) }
        } decode: { json in
            try parseSession(json)
        }
    }

    /// 現在の ID トークンを取得 (期限が近ければ自動リフレッシュ)
    static func currentIdToken() throws -> String {
        try syncFFI("currentIdToken") {
            artia_fb_auth_current_id_token()
        } decode: { json in
            try parseSession(json).id_token
        }
    }

    /// Rust 側ローカルセッションをサインアウト (Firebase SDK 側は別途)
    @discardableResult
    static func signOut() -> Bool {
        return artia_fb_auth_sign_out()
    }

    // MARK: - Firestore

    enum Firestore {
        static func get(collection: String, docId: String) async throws -> FirestoreDocument {
            try await detachedFFI("Firestore.get") {
                collection.withCString { c in
                    docId.withCString { d in
                        artia_fb_firestore_get(c, d)
                    }
                }
            } decode: { json in
                try FirestoreDocument.decode(from: json)
            }
        }

        static func create(
            collection: String,
            docId: String?,
            fields: [String: Any]
        ) async throws -> FirestoreDocument {
            let fieldsJSON = try jsonString(fields)
            return try await detachedFFI("Firestore.create") {
                collection.withCString { c in
                    fieldsJSON.withCString { f in
                        if let docId = docId {
                            return docId.withCString { d in
                                artia_fb_firestore_create(c, d, f)
                            }
                        } else {
                            return artia_fb_firestore_create(c, nil, f)
                        }
                    }
                }
            } decode: { json in
                try FirestoreDocument.decode(from: json)
            }
        }

        static func update(
            collection: String,
            docId: String,
            fields: [String: Any],
            updateMask: [String]? = nil
        ) async throws -> FirestoreDocument {
            let fieldsJSON = try jsonString(fields)
            let maskJSON = try updateMask.map { try jsonString($0) }
            return try await detachedFFI("Firestore.update") {
                collection.withCString { c in
                    docId.withCString { d in
                        fieldsJSON.withCString { f in
                            if let maskJSON = maskJSON {
                                return maskJSON.withCString { m in
                                    artia_fb_firestore_update(c, d, f, m)
                                }
                            } else {
                                return artia_fb_firestore_update(c, d, f, nil)
                            }
                        }
                    }
                }
            } decode: { json in
                try FirestoreDocument.decode(from: json)
            }
        }

        static func delete(collection: String, docId: String) async throws {
            let ok: Bool = await Task.detached(priority: .userInitiated) {
                collection.withCString { c in
                    docId.withCString { d in
                        artia_fb_firestore_delete(c, d)
                    }
                }
            }.value
            if !ok {
                throw Error.rust("artia_fb_firestore_delete が false を返しました")
            }
        }

        /// runQuery を実行する。`query` は Rust 側 `StructuredQuery` の JSON 互換辞書。
        /// 例: `["from": [["collectionId": "users"]], "limit": 50]`
        static func query(parent: String, query: [String: Any]) async throws -> [FirestoreDocument] {
            let queryJSON = try jsonString(query)
            return try await detachedFFI("Firestore.query") {
                parent.withCString { p in
                    queryJSON.withCString { q in
                        artia_fb_firestore_query(p, q)
                    }
                }
            } decode: { json in
                guard let data = json.data(using: .utf8),
                      let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    throw Error.decoding("Document[] 解析失敗: \(json)")
                }
                return try array.map { try FirestoreDocument.fromDict($0) }
            }
        }
    }

    // MARK: - Storage

    enum Storage {
        /// アップロード。戻り値は StorageObject の JSON 文字列。
        @discardableResult
        static func upload(path: String, data: Data, contentType: String) async throws -> String {
            // Rust 側は usize (Swift では UInt) で長さを受けるため、
            // Data 全体を Vec<UInt8> にコピーしてから FFI に渡す。
            let bytes = [UInt8](data)
            let task: Task<String, Swift.Error> = Task.detached(priority: .userInitiated) {
                let json: String = try bytes.withUnsafeBufferPointer { buf in
                    let basePtr = buf.baseAddress
                    let len = UInt(buf.count)
                    let raw = path.withCString { p in
                        contentType.withCString { ct in
                            artia_fb_storage_upload(p, basePtr, len, ct)
                        }
                    }
                    guard let ptr = raw else {
                        throw Error.nullReturn("Storage.upload")
                    }
                    let s = String(cString: ptr)
                    artia_fb_free_string(ptr)
                    if let err = parseError(s) {
                        throw Error.rust(err)
                    }
                    return s
                }
                return json
            }
            return try await task.value
        }

        /// ダウンロード。失敗時は throw。
        static func download(path: String) async throws -> Data {
            try await Task.detached(priority: .userInitiated) {
                var outLen: UInt = 0
                let raw = path.withCString { p -> UnsafeMutablePointer<UInt8>? in
                    artia_fb_storage_download(p, &outLen)
                }
                guard let ptr = raw else {
                    throw Error.nullReturn("Storage.download")
                }
                let data = Data(bytes: ptr, count: Int(outLen))
                artia_fb_free_bytes(ptr, outLen)
                return data
            }.value
        }

        static func delete(path: String) async throws {
            let ok: Bool = await Task.detached(priority: .userInitiated) {
                path.withCString { p in
                    artia_fb_storage_delete(p)
                }
            }.value
            if !ok {
                throw Error.rust("artia_fb_storage_delete が false を返しました")
            }
        }
    }

    // MARK: - Cloud Messaging

    enum Messaging {
        @discardableResult
        static func subscribe(token: String, topic: String) async -> Bool {
            await Task.detached(priority: .userInitiated) {
                token.withCString { t in
                    topic.withCString { tp in
                        artia_fb_messaging_subscribe_topic(t, tp)
                    }
                }
            }.value
        }

        @discardableResult
        static func unsubscribe(token: String, topic: String) async -> Bool {
            await Task.detached(priority: .userInitiated) {
                token.withCString { t in
                    topic.withCString { tp in
                        artia_fb_messaging_unsubscribe_topic(t, tp)
                    }
                }
            }.value
        }
    }

    // MARK: - 内部ユーティリティ

    /// Rust 側エラー JSON (`{"error":"..."}`) かどうか判定し、メッセージを返す。
    private static func parseError(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = dict["error"] as? String else {
            return nil
        }
        return error
    }

    /// Rust 側 AuthSession JSON をパース。
    private static func parseSession(_ json: String) throws -> AuthSession {
        guard let data = json.data(using: .utf8) else {
            throw Error.decoding(json)
        }
        do {
            return try JSONDecoder().decode(AuthSession.self, from: data)
        } catch {
            throw Error.decoding("\(error) (raw: \(json))")
        }
    }

    /// 任意の Codable/辞書を JSON 文字列にする。
    private static func jsonString(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [])
        guard let s = String(data: data, encoding: .utf8) else {
            throw Error.decoding("UTF-8 へのエンコード失敗")
        }
        return s
    }

    /// Rust の C 文字列を返す FFI を呼び、エラー JSON チェック + decode を行う共通処理。
    /// 同期版: `currentIdToken` のような小さい呼び出しに使う (ブロッキング許容)。
    private static func syncFFI<T>(
        _ where_: String,
        _ call: () -> UnsafeMutablePointer<CChar>?,
        decode: (String) throws -> T
    ) throws -> T {
        guard let ptr = call() else {
            throw Error.nullReturn(where_)
        }
        let json = String(cString: ptr)
        artia_fb_free_string(ptr)
        if let err = parseError(json) {
            throw Error.rust(err)
        }
        return try decode(json)
    }

    /// 非同期版: Rust 側 block_on を呼ぶため `Task.detached` で別スレッドへ逃がす。
    private static func detachedFFI<T>(
        _ where_: String,
        _ call: @Sendable @escaping () -> UnsafeMutablePointer<CChar>?,
        decode: @Sendable @escaping (String) throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try syncFFI(where_, call, decode: decode)
        }.value
    }
}
