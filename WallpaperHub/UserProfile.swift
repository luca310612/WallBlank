import Foundation
import AppKit

/// ユーザープロフィール
struct UserProfile: Codable, Equatable {
    let uid: String
    var displayName: String
    var email: String?
    var photoURL: String?
    var authProvider: AuthProvider
    var createdAt: Date
    var lastSyncAt: Date?

    /// 管理者フラグ
    var isAdmin: Bool = false

    /// カスタムアバター画像のローカルパス
    var customAvatarPath: String?

    /// 自己紹介文
    var bio: String?

    /// SNSリンク
    var socialLinks: SocialLinks

    /// 同期設定
    var syncPreferences: SyncPreferences

    enum AuthProvider: String, Codable {
        case anonymous
        case email
        case google
    }

    /// SNSリンク情報
    struct SocialLinks: Codable, Equatable {
        var twitter: String?
        var instagram: String?
        var pixiv: String?
        var skeb: String?
        var youtube: String?

        /// 設定されているリンクが1つ以上あるか
        var hasAnyLink: Bool {
            [twitter, instagram, pixiv, skeb, youtube].contains { $0?.isEmpty == false }
        }

        /// 各SNSリンクの必須プレフィックス
        private static let requiredPrefixes: [(KeyPath<SocialLinks, String?>, String)] = [
            (\.twitter, "https://x.com/"),
            (\.instagram, "https://www.instagram.com/"),
            (\.pixiv, "https://www.pixiv.net/users/"),
            (\.skeb, "https://skeb.jp/"),
            (\.youtube, "https://www.youtube.com/"),
        ]

        /// 入力されたリンクがすべて正しいURLプレフィックスを持っているか
        var isAllLinksValid: Bool {
            for (keyPath, prefix) in Self.requiredPrefixes {
                if let value = self[keyPath: keyPath], !value.isEmpty {
                    if !value.hasPrefix(prefix) {
                        return false
                    }
                }
            }
            return true
        }

        /// 指定フィールドのバリデーションエラーメッセージ（空欄ならnil）
        static func validationError(for value: String, prefix: String) -> String? {
            guard !value.isEmpty else { return nil }
            if !value.hasPrefix(prefix) {
                return "\(prefix) で始まるURLを入力してください"
            }
            return nil
        }
    }

    struct SyncPreferences: Codable, Equatable {
        var syncCollections: Bool = true
        var syncSchedules: Bool = true
        var syncEnvironmentRules: Bool = true
        var syncSettings: Bool = true
    }

    enum CodingKeys: String, CodingKey {
        case uid, displayName, email, photoURL, authProvider
        case createdAt, lastSyncAt, isAdmin
        case customAvatarPath, bio, socialLinks
        case syncPreferences
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uid = try container.decode(String.self, forKey: .uid)
        displayName = try container.decode(String.self, forKey: .displayName)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        photoURL = try container.decodeIfPresent(String.self, forKey: .photoURL)
        authProvider = try container.decode(AuthProvider.self, forKey: .authProvider)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastSyncAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncAt)
        isAdmin = try container.decodeIfPresent(Bool.self, forKey: .isAdmin) ?? false
        customAvatarPath = try container.decodeIfPresent(String.self, forKey: .customAvatarPath)
        bio = try container.decodeIfPresent(String.self, forKey: .bio)
        socialLinks = try container.decodeIfPresent(SocialLinks.self, forKey: .socialLinks) ?? SocialLinks()
        syncPreferences = try container.decodeIfPresent(SyncPreferences.self, forKey: .syncPreferences) ?? SyncPreferences()
    }

    init(
        uid: String,
        displayName: String,
        email: String? = nil,
        photoURL: String? = nil,
        authProvider: AuthProvider,
        createdAt: Date,
        lastSyncAt: Date? = nil,
        isAdmin: Bool = false,
        customAvatarPath: String? = nil,
        bio: String? = nil,
        socialLinks: SocialLinks = SocialLinks(),
        syncPreferences: SyncPreferences = SyncPreferences()
    ) {
        self.uid = uid
        self.displayName = displayName
        self.email = email
        self.photoURL = photoURL
        self.authProvider = authProvider
        self.createdAt = createdAt
        self.lastSyncAt = lastSyncAt
        self.isAdmin = isAdmin
        self.customAvatarPath = customAvatarPath
        self.bio = bio
        self.socialLinks = socialLinks
        self.syncPreferences = syncPreferences
    }

    /// デフォルト初期化
    static func create(
        uid: String,
        displayName: String = "ユーザー",
        email: String? = nil,
        photoURL: String? = nil,
        authProvider: AuthProvider = .anonymous,
        isAdmin: Bool = false
    ) -> UserProfile {
        UserProfile(
            uid: uid,
            displayName: displayName,
            email: email,
            photoURL: photoURL,
            authProvider: authProvider,
            createdAt: Date(),
            lastSyncAt: nil,
            isAdmin: isAdmin,
            syncPreferences: SyncPreferences()
        )
    }

    // MARK: - アバター画像の取得

    /// カスタムアバター → Google/メールのphotoURL → nil の優先順位で画像を返す
    var resolvedAvatarImage: NSImage? {
        // カスタムアバターが設定されている場合はそちらを優先
        if let path = customAvatarPath, !path.isEmpty {
            // アバターパスの安全性を検証（ディレクトリ外のファイルアクセスを防止）
            let avatarDir = UserProfile.avatarDirectory.path
            guard path.hasPrefix(avatarDir) else { return nil }
            return NSImage(contentsOfFile: path)
        }
        return nil
    }

    /// アバター画像の保存ディレクトリ
    static var avatarDirectory: URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("WallBlank/Avatars", isDirectory: true)
            try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
            return fallback
        }
        let dir = appSupport.appendingPathComponent("WallBlank/Avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
