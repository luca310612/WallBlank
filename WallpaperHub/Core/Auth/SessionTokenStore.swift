import Foundation
import Security

/// 認証セッショントークンの永続化。
/// Keychain (kSecClassGenericPassword) に保存し、アプリ再起動後も復元可能にする。
enum SessionTokenStore {

    private static let service = "com.artia.app.auth"
    private static let tokenAccount = "session.token"
    private static let expiresAccount = "session.expiresAt"

    static func save(token: String, expiresAt: TimeInterval) {
        setKeychainString(token, account: tokenAccount)
        setKeychainString(String(expiresAt), account: expiresAccount)
    }

    static func loadToken() -> String? {
        guard let token = getKeychainString(account: tokenAccount), !token.isEmpty else { return nil }
        // 有効期限切れなら破棄
        if let expiresStr = getKeychainString(account: expiresAccount),
           let expires = TimeInterval(expiresStr),
           Date().timeIntervalSince1970 >= expires {
            clear()
            return nil
        }
        return token
    }

    static func clear() {
        deleteKeychain(account: tokenAccount)
        deleteKeychain(account: expiresAccount)
    }

    // MARK: - Keychain ヘルパー

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func setKeychainString(_ value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query = baseQuery(account: account)

        // 既存があれば更新、無ければ追加
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    private static func getKeychainString(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteKeychain(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}
