import Foundation

/// Cloudflare Workers (artia-auth) との通信クライアント。
///
/// 役割は HTTP API の薄いラッパー。`AuthManager` から呼ばれる。
/// Firebase SDK 依存をすべてここに代替する。
final class CloudflareAuthClient {

    /// 認証バックエンドのベースURL。デプロイ後に確定するため、後で実URLへ差し替える。
    /// 例: "https://artia-auth.<account>.workers.dev"
    static let baseURL: URL = URL(string: "https://artia-auth.REPLACE_WITH_ACCOUNT.workers.dev")!

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(session: URLSession = .shared) {
        self.session = session

        let dec = JSONDecoder()
        // Worker は Unix 秒 (Int) で日時を返すため、Date変換はカスタムで吸収
        dec.dateDecodingStrategy = .secondsSince1970
        self.decoder = dec

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        self.encoder = enc
    }

    // MARK: - レスポンス型

    /// signup / signin / google が返すペイロード
    struct AuthResponse: Decodable {
        let token: String
        let expiresAt: TimeInterval
        let profile: APIProfile
    }

    struct ProfileWrapper: Decodable {
        let profile: APIProfile
    }

    /// Worker の PublicProfile レスポンスにそのままマッピング
    struct APIProfile: Decodable {
        let uid: String
        let email: String?
        let displayName: String
        let photoURL: String?
        let authProvider: String
        let isAdmin: Bool
        let bio: String?
        let socialLinks: APISocialLinks
        let syncPreferences: APISyncPreferences
        let createdAt: TimeInterval
        let updatedAt: TimeInterval
    }

    struct APISocialLinks: Codable {
        let twitter: String?
        let instagram: String?
        let pixiv: String?
        let youtube: String?
    }

    struct APISyncPreferences: Codable {
        let syncCollections: Bool
        let syncSchedules: Bool
        let syncEnvironmentRules: Bool
        let syncSettings: Bool
    }

    struct APIErrorBody: Decodable {
        let error: String
    }

    // MARK: - エンドポイント

    func signUp(email: String, password: String, displayName: String) async throws -> AuthResponse {
        try await post(
            path: "/auth/signup",
            body: ["email": email, "password": password, "displayName": displayName],
            authToken: nil
        )
    }

    func signIn(email: String, password: String) async throws -> AuthResponse {
        try await post(
            path: "/auth/signin",
            body: ["email": email, "password": password],
            authToken: nil
        )
    }

    func signInWithGoogle(idToken: String) async throws -> AuthResponse {
        try await post(
            path: "/auth/google",
            body: ["idToken": idToken],
            authToken: nil
        )
    }

    func fetchProfile(token: String) async throws -> APIProfile {
        let wrapper: ProfileWrapper = try await get(path: "/auth/me", authToken: token)
        return wrapper.profile
    }

    func updateProfile(token: String, patch: ProfilePatch) async throws -> APIProfile {
        let wrapper: ProfileWrapper = try await patchJSON(
            path: "/auth/profile",
            body: patch,
            authToken: token
        )
        return wrapper.profile
    }

    func signOut(token: String) async throws {
        let _: EmptyOK = try await post(
            path: "/auth/signout",
            body: [String: String](),
            authToken: token
        )
    }

    func deleteAccount(token: String) async throws {
        let _: EmptyOK = try await delete(path: "/auth/account", authToken: token)
    }

    // MARK: - パッチ送信ペイロード

    struct ProfilePatch: Encodable {
        var displayName: String?
        var bio: String?
        var socialLinks: APISocialLinks?
        var syncPreferences: APISyncPreferences?
    }

    struct EmptyOK: Decodable {
        let ok: Bool?
    }

    // MARK: - 共通HTTP

    enum CloudflareAuthError: LocalizedError {
        case invalidURL
        case http(status: Int, message: String)
        case decoding(Error)
        case transport(Error)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "URLが不正です"
            case .http(_, let message): return message
            case .decoding(let e): return "レスポンスの解析に失敗しました: \(e.localizedDescription)"
            case .transport(let e): return "通信エラー: \(e.localizedDescription)"
            }
        }
    }

    private func get<T: Decodable>(path: String, authToken: String?) async throws -> T {
        try await execute(method: "GET", path: path, body: Optional<EmptyEncodable>.none, authToken: authToken)
    }

    private func post<Body: Encodable, T: Decodable>(
        path: String,
        body: Body,
        authToken: String?
    ) async throws -> T {
        try await execute(method: "POST", path: path, body: body, authToken: authToken)
    }

    private func patchJSON<Body: Encodable, T: Decodable>(
        path: String,
        body: Body,
        authToken: String?
    ) async throws -> T {
        try await execute(method: "PATCH", path: path, body: body, authToken: authToken)
    }

    private func delete<T: Decodable>(path: String, authToken: String?) async throws -> T {
        try await execute(method: "DELETE", path: path, body: Optional<EmptyEncodable>.none, authToken: authToken)
    }

    private struct EmptyEncodable: Encodable {}

    private func execute<Body: Encodable, T: Decodable>(
        method: String,
        path: String,
        body: Body?,
        authToken: String?
    ) async throws -> T {
        guard let url = URL(string: path, relativeTo: Self.baseURL) else {
            throw CloudflareAuthError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try encoder.encode(body)
            } catch {
                throw CloudflareAuthError.decoding(error)
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CloudflareAuthError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CloudflareAuthError.http(status: -1, message: "不正なレスポンス")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message: String
            if let body = try? decoder.decode(APIErrorBody.self, from: data) {
                message = body.error
            } else if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                message = text
            } else {
                message = "HTTP \(http.statusCode)"
            }
            throw CloudflareAuthError.http(status: http.statusCode, message: message)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw CloudflareAuthError.decoding(error)
        }
    }
}

// MARK: - APIProfile → UserProfile 変換

extension CloudflareAuthClient.APIProfile {
    /// Worker レスポンスを既存の `UserProfile` 型へ変換する。
    /// `customAvatarPath` はローカルのみで、サーバーは保持しない。
    func toUserProfile(customAvatarPath: String? = nil) -> UserProfile {
        let provider: UserProfile.AuthProvider = {
            switch authProvider {
            case "google": return .google
            case "email": return .email
            default: return .anonymous
            }
        }()

        let links = UserProfile.SocialLinks(
            twitter: socialLinks.twitter,
            instagram: socialLinks.instagram,
            pixiv: socialLinks.pixiv,
            // skeb は Worker 側未対応のため nil 固定 (ローカルのみ運用)
            skeb: nil,
            youtube: socialLinks.youtube
        )
        let prefs = UserProfile.SyncPreferences(
            syncCollections: syncPreferences.syncCollections,
            syncSchedules: syncPreferences.syncSchedules,
            syncEnvironmentRules: syncPreferences.syncEnvironmentRules,
            syncSettings: syncPreferences.syncSettings
        )
        return UserProfile(
            uid: uid,
            displayName: displayName,
            email: email,
            photoURL: photoURL,
            authProvider: provider,
            createdAt: Date(timeIntervalSince1970: createdAt),
            lastSyncAt: Date(timeIntervalSince1970: updatedAt),
            isAdmin: isAdmin,
            customAvatarPath: customAvatarPath,
            bio: bio,
            socialLinks: links,
            syncPreferences: prefs
        )
    }
}
