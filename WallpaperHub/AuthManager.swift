import Foundation
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif
import AppKit

/// 認証状態
enum AuthState: Equatable {
    case loading
    case signedOut
    case signedIn

    static func == (lhs: AuthState, rhs: AuthState) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading), (.signedOut, .signedOut), (.signedIn, .signedIn):
            return true
        default:
            return false
        }
    }
}

/// 認証エラー
enum AuthError: LocalizedError {
    case configurationMissing
    case tokenMissing
    case windowNotFound
    case userNotFound
    case displayNameTooLong
    case bioTooLong
    case passwordTooWeak
    case invalidSocialLinkURL
    /// バックエンド未対応の機能
    case notSupported(String)
    /// バックエンドからのエラー (ネットワーク含む)
    case backend(String)

    var errorDescription: String? {
        switch self {
        case .configurationMissing: return "認証設定が見つかりません"
        case .tokenMissing: return "認証トークンを取得できませんでした"
        case .windowNotFound: return "ウィンドウが見つかりません"
        case .userNotFound: return "ユーザーが見つかりません"
        case .displayNameTooLong: return "表示名は50文字以内で入力してください"
        case .bioTooLong: return "自己紹介文は500文字以内で入力してください"
        case .passwordTooWeak: return "パスワードは8文字以上で入力してください"
        case .invalidSocialLinkURL: return "SNSリンクのURLはhttps://またはhttp://で始まる必要があります"
        case .notSupported(let m): return "現在この機能は利用できません: \(m)"
        case .backend(let m): return m
        }
    }
}

/// 認証管理クラス（Cloudflare Workers + D1 バックエンド）
///
/// 役割:
/// - メール/パスワードと Google サインインの両対応
/// - Bearer トークンを Keychain (`SessionTokenStore`) に保存し、再起動後も復元
/// - プロフィールはオフラインキャッシュ（UserDefaults）も維持
class AuthManager: ObservableObject {
    static let shared = AuthManager()

    @Published var authState: AuthState = .loading
    @Published var currentProfile: UserProfile?
    @Published var errorMessage: String?
    @Published var isProcessing: Bool = false

    /// プロフィール JSON のローカルキャッシュキー
    private let profileCacheKey = "com.artia.auth.profileCache"

    /// 管理者メールアドレス（バックエンドでも判定するが、UI 即時反映用に保持）
    private let adminEmail = "REDACTED@example.com"

    /// バックエンドクライアント
    private let client = CloudflareAuthClient()

    #if DEBUG
    /// プレビュー用オーバーライド
    var _previewIsAuthenticated: Bool?
    var _previewIsAdminMode: Bool?
    #endif

    /// 管理者モードかどうか
    var isAdminMode: Bool {
        #if DEBUG
        if let override = _previewIsAdminMode { return override }
        #endif
        return currentProfile?.isAdmin == true
    }

    /// 認証中かどうか（Keychain にトークンがあり、プロフィールも揃っている）
    var isAuthenticated: Bool {
        #if DEBUG
        if let override = _previewIsAuthenticated { return override }
        #endif
        guard SessionTokenStore.loadToken() != nil else { return false }
        return currentProfile != nil
    }

    /// 現在のユーザーの UID（バックエンド発行）
    var currentUID: String? { currentProfile?.uid }

    private init() {
        loadCachedProfile()
    }

    // MARK: - 初期化

    /// アプリ起動時に呼び出す
    func configure() {
        // Keychain にセッショントークンがあれば、それを使ってプロフィールを再取得
        guard let token = SessionTokenStore.loadToken() else {
            DispatchQueue.main.async {
                self.authState = .signedOut
                self.currentProfile = nil
            }
            return
        }

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let api = try await self.client.fetchProfile(token: token)
                let profile = api.toUserProfile(customAvatarPath: self.currentProfile?.customAvatarPath)
                await MainActor.run {
                    self.currentProfile = profile
                    self.cacheProfile(profile)
                    self.authState = .signedIn
                }
            } catch {
                debugLog("[Auth] プロフィール再取得失敗: \(error.localizedDescription) → サインアウト")
                SessionTokenStore.clear()
                await MainActor.run {
                    self.currentProfile = nil
                    self.clearCachedProfile()
                    self.authState = .signedOut
                }
            }
        }
    }

    // MARK: - Google Sign-In

    func signInWithGoogle(presenting window: NSWindow) async throws {
        #if canImport(GoogleSignIn)
        await MainActor.run { isProcessing = true }
        defer { Task { @MainActor in isProcessing = false } }

        // GIDSignIn の Client ID は Info.plist の GIDClientID を使う想定。
        // 既存のFirebase時代の設定がそのまま流用される。
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: window)
        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthError.tokenMissing
        }

        do {
            let res = try await self.client.signInWithGoogle(idToken: idToken)
            await applyAuthResponse(res)
        } catch {
            await MainActor.run { self.errorMessage = error.localizedDescription }
            throw error
        }
        debugLog("[Auth] Googleサインイン成功: \(currentProfile?.uid ?? "?")")
        #else
        throw AuthError.notSupported("GoogleSignIn SDK が利用できません")
        #endif
    }

    // MARK: - メール/パスワード認証

    func signUpWithEmail(email: String, password: String, displayName: String) async throws {
        guard password.count >= 8 else { throw AuthError.passwordTooWeak }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 50 else { throw AuthError.displayNameTooLong }

        await MainActor.run { isProcessing = true }
        defer { Task { @MainActor in isProcessing = false } }

        do {
            let res = try await self.client.signUp(email: email, password: password, displayName: trimmedName)
            await applyAuthResponse(res)
        } catch {
            await MainActor.run { self.errorMessage = error.localizedDescription }
            throw error
        }
        debugLog("[Auth] メール新規登録成功: \(currentProfile?.uid ?? "?")")
    }

    func signInWithEmail(email: String, password: String) async throws {
        await MainActor.run { isProcessing = true }
        defer { Task { @MainActor in isProcessing = false } }

        do {
            let res = try await self.client.signIn(email: email, password: password)
            await applyAuthResponse(res)
        } catch {
            await MainActor.run { self.errorMessage = error.localizedDescription }
            throw error
        }
        debugLog("[Auth] メールサインイン成功: \(currentProfile?.uid ?? "?")")
    }

    // MARK: - パスワードリセット

    /// 現状のCloudflare バックエンドはメール送信を実装していないため未対応。
    /// 必要になった段階で SendGrid / Resend / Mailgun の Worker 統合を追加する。
    func sendPasswordReset(email: String) async throws {
        _ = email
        throw AuthError.notSupported("パスワードリセットメール送信は現在未対応です")
    }

    // MARK: - サインアウト

    func signOut() throws {
        // バックエンドへ非同期で通知（失敗してもローカル状態は必ずクリア）
        if let token = SessionTokenStore.loadToken() {
            Task { [client] in
                do { try await client.signOut(token: token) }
                catch { debugLog("[Auth] サーバーサインアウト失敗 (無視): \(error.localizedDescription)") }
            }
        }

        SessionTokenStore.clear()

        let clearState = {
            self.currentProfile = nil
            self.clearCachedProfile()
            self.authState = .signedOut
            self.errorMessage = nil
        }
        if Thread.isMainThread {
            clearState()
        } else {
            DispatchQueue.main.sync { clearState() }
        }

        #if canImport(GoogleSignIn)
        GIDSignIn.sharedInstance.signOut()
        #endif

        // ギャラリーデータをクリア
        GalleryManager.shared.clearData()

        debugLog("[Auth] サインアウト完了")
    }

    // MARK: - アカウント削除

    func deleteAccount() async throws {
        guard let token = SessionTokenStore.loadToken() else { throw AuthError.userNotFound }
        await MainActor.run { isProcessing = true }
        defer { Task { @MainActor in isProcessing = false } }

        try await client.deleteAccount(token: token)

        SessionTokenStore.clear()
        await MainActor.run {
            self.currentProfile = nil
            self.clearCachedProfile()
            self.authState = .signedOut
            self.errorMessage = nil
        }

        #if canImport(GoogleSignIn)
        GIDSignIn.sharedInstance.signOut()
        #endif

        GalleryManager.shared.clearData()
        debugLog("[Auth] アカウント削除完了")
    }

    // MARK: - プロフィール管理

    func updateDisplayName(_ name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 50 else { throw AuthError.displayNameTooLong }
        try await applyProfileUpdate(
            CloudflareAuthClient.ProfilePatch(displayName: trimmed)
        )
    }

    /// カスタムアバター画像をローカルに保存（バックエンドには送らない）
    func updateCustomAvatar(_ image: NSImage) async throws {
        guard let uid = currentUID else { throw AuthError.userNotFound }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            throw AuthError.configurationMissing
        }

        let avatarURL = UserProfile.avatarDirectory.appendingPathComponent("\(uid).jpg")
        try jpeg.write(to: avatarURL)

        await MainActor.run {
            self.currentProfile?.customAvatarPath = avatarURL.path
            if let profile = self.currentProfile {
                self.cacheProfile(profile)
            }
        }
        debugLog("[Auth] カスタムアバター保存完了: \(avatarURL.path)")
    }

    /// カスタムアバターを削除（デフォルトに戻す）
    func removeCustomAvatar() async throws {
        guard let uid = currentUID else { throw AuthError.userNotFound }
        let avatarURL = UserProfile.avatarDirectory.appendingPathComponent("\(uid).jpg")
        try? FileManager.default.removeItem(at: avatarURL)

        await MainActor.run {
            self.currentProfile?.customAvatarPath = nil
            if let profile = self.currentProfile {
                self.cacheProfile(profile)
            }
        }
        debugLog("[Auth] カスタムアバター削除完了")
    }

    /// 自己紹介文を更新
    func updateBio(_ bio: String) async throws {
        let trimmed = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 500 else { throw AuthError.bioTooLong }
        try await applyProfileUpdate(
            CloudflareAuthClient.ProfilePatch(bio: trimmed.isEmpty ? nil : trimmed)
        )
    }

    /// SNSリンクを更新
    func updateSocialLinks(_ links: UserProfile.SocialLinks) async throws {
        // URLバリデーション: バックエンドにも検証はあるが、UX的に手前で弾く
        let allLinks: [String?] = [links.twitter, links.instagram, links.pixiv, links.youtube]
        for link in allLinks {
            if let s = link, !s.isEmpty,
               !s.hasPrefix("https://"), !s.hasPrefix("http://") {
                throw AuthError.invalidSocialLinkURL
            }
        }

        let payload = CloudflareAuthClient.APISocialLinks(
            twitter: links.twitter,
            instagram: links.instagram,
            pixiv: links.pixiv,
            youtube: links.youtube
        )
        try await applyProfileUpdate(
            CloudflareAuthClient.ProfilePatch(socialLinks: payload)
        )

        // Skeb はバックエンド未対応 → ローカルキャッシュのみ反映
        await MainActor.run {
            self.currentProfile?.socialLinks.skeb = links.skeb
            if let profile = self.currentProfile {
                self.cacheProfile(profile)
            }
        }
        debugLog("[Auth] SNSリンク更新完了")
    }

    /// プロフィール再取得（外部から明示的に呼ぶ場合用）
    func loadProfile() async {
        guard let token = SessionTokenStore.loadToken() else { return }
        do {
            let api = try await client.fetchProfile(token: token)
            let profile = api.toUserProfile(customAvatarPath: currentProfile?.customAvatarPath)
            await MainActor.run {
                self.currentProfile = profile
                self.cacheProfile(profile)
            }
        } catch {
            debugLog("[Auth] プロフィール読み込み失敗: \(error.localizedDescription)")
        }
    }

    // MARK: - 内部処理

    /// 認証API レスポンスを取り込み、状態を sign-in にする
    private func applyAuthResponse(_ res: CloudflareAuthClient.AuthResponse) async {
        SessionTokenStore.save(token: res.token, expiresAt: res.expiresAt)
        // カスタムアバターは UID ごとに作るため、サインイン直後は既存の `currentProfile` 参照は使わない
        let profile = res.profile.toUserProfile(customAvatarPath: nil)
        await MainActor.run {
            self.currentProfile = profile
            self.cacheProfile(profile)
            self.authState = .signedIn
            self.errorMessage = nil
        }
    }

    /// プロフィール部分更新を Worker に投げ、結果でローカル状態を更新
    private func applyProfileUpdate(_ patch: CloudflareAuthClient.ProfilePatch) async throws {
        guard let token = SessionTokenStore.loadToken() else { throw AuthError.userNotFound }
        do {
            let api = try await client.updateProfile(token: token, patch: patch)
            let profile = api.toUserProfile(customAvatarPath: currentProfile?.customAvatarPath)
            await MainActor.run {
                self.currentProfile = profile
                self.cacheProfile(profile)
            }
        } catch {
            await MainActor.run { self.errorMessage = error.localizedDescription }
            throw error
        }
    }

    // MARK: - ローカルキャッシュ

    private func cacheProfile(_ profile: UserProfile) {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: profileCacheKey)
        }
    }

    private func loadCachedProfile() {
        if let data = UserDefaults.standard.data(forKey: profileCacheKey),
           let profile = try? JSONDecoder().decode(UserProfile.self, from: data) {
            currentProfile = profile
        }
    }

    private func clearCachedProfile() {
        UserDefaults.standard.removeObject(forKey: profileCacheKey)
    }

    // MARK: - プレビュー用ファクトリ

    #if DEBUG
    /// Xcodeプレビュー用インスタンス生成
    static func previewInstance(
        isAuthenticated: Bool = true,
        isAdmin: Bool = false,
        profile: UserProfile? = nil
    ) -> AuthManager {
        let instance = AuthManager()
        instance._previewIsAuthenticated = isAuthenticated
        instance._previewIsAdminMode = isAdmin
        if isAuthenticated {
            instance.authState = .signedIn
            instance.currentProfile = profile ?? UserProfile.create(
                uid: "preview-user",
                displayName: "プレビューユーザー",
                email: "preview@example.com",
                authProvider: .email,
                isAdmin: isAdmin
            )
        } else {
            instance.authState = .signedOut
            instance.currentProfile = nil
        }
        return instance
    }
    #endif
}
