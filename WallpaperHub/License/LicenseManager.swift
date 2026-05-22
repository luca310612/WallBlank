import Foundation
import Security

/// Phase 11F: シリアルキー署名検証 + 30 日体験版ロジック。
///
/// 仕様:
///   - 体験版: 初回起動から 30 日間は Pro 機能を無制限解放 (`isProEnabled == true`)
///   - 期限後はライセンスキー未入力なら Free モード
///   - シリアルキー: `<payload-base64>.<rsa-signature-base64>` 形式
///       - payload は JSON: `{"licenseId":"...","userEmail":"...","plan":"pro","issuedAt":1700000000}`
///       - 署名は Info.plist `ArtiaLicensePublicKey` の RSA-2048 公開鍵で検証
///   - 検証 OK → Keychain (`com.artia.license`) に保存し永続化
///   - Pro 限定機能フラグ: 今は機能制限ではなく公開フラグとして提供 (実際の隠蔽は Phase 11 後で)
///
/// テスト容易化のため、Keychain / Info.plist / 現在時刻 / 公開鍵 PEM はすべて DI 可能にしている。
@MainActor
final class LicenseManager: ObservableObject {

    // MARK: - 公開モード

    enum Mode: String, Codable, Equatable {
        case free
        case trial
        case pro
    }

    @Published private(set) var mode: Mode = .free
    @Published private(set) var trialDaysRemaining: Int = 0
    @Published private(set) var lastError: String?

    /// Pro 限定機能の有効性。Phase 11 では UI 表示のみで使用、実際の機能制限は将来導入。
    var isProEnabled: Bool {
        switch mode {
        case .pro, .trial: return true
        case .free: return false
        }
    }

    // MARK: - 依存性 (DI)

    /// Keychain への保存/読み出しを抽象化。テストでは in-memory モックに差し替える。
    protocol LicenseKeychain {
        func read() -> String?
        func write(_ value: String) -> Bool
        func delete() -> Bool
    }

    /// 現在時刻と "trial 開始時刻" を抽象化したストア。
    protocol TrialClock {
        var now: Date { get }
        var trialStartedAt: Date? { get set }
    }

    /// 公開鍵 PEM (Info.plist 経由)。テストでは固定値を渡す。
    private let publicKeyPEM: String?
    private let keychain: LicenseKeychain
    private var clock: TrialClock
    private let trialDuration: TimeInterval

    // MARK: - 初期化

    init(
        publicKeyPEM: String?,
        keychain: LicenseKeychain,
        clock: TrialClock,
        trialDuration: TimeInterval = 30 * 24 * 60 * 60
    ) {
        self.publicKeyPEM = publicKeyPEM
        self.keychain = keychain
        self.clock = clock
        self.trialDuration = trialDuration
        evaluate()
    }

    /// 本番ファクトリ。
    static func makeDefault() -> LicenseManager {
        return LicenseManager(
            publicKeyPEM: Bundle.main.object(forInfoDictionaryKey: "ArtiaLicensePublicKey") as? String,
            keychain: SecKeychainStore(account: "com.artia.license"),
            clock: UserDefaultsTrialClock()
        )
    }

    // MARK: - 公開 API

    /// 入力されたシリアルキーを検証し、OK なら Keychain に保存して Pro モードに切り替える。
    /// - Returns: 検証成功なら true
    @discardableResult
    func activate(serialKey: String) -> Bool {
        let trimmed = serialKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch verify(serialKey: trimmed) {
        case .success:
            _ = keychain.write(trimmed)
            mode = .pro
            lastError = nil
            return true
        case .failure(let reason):
            lastError = reason
            return false
        }
    }

    /// ライセンスを取り消し、Free モードに戻す。
    func deactivate() {
        _ = keychain.delete()
        evaluate()
    }

    /// 起動時または変更後に再評価する。
    func evaluate() {
        // 1) Keychain にライセンスがあるなら検証する
        if let stored = keychain.read() {
            switch verify(serialKey: stored) {
            case .success:
                mode = .pro
                trialDaysRemaining = 0
                lastError = nil
                return
            case .failure(let reason):
                lastError = reason
                _ = keychain.delete()
            }
        }

        // 2) trial 開始時刻が無ければ now を記録する
        if clock.trialStartedAt == nil {
            clock.trialStartedAt = clock.now
        }

        // 3) trial 残日数で mode を決定する
        let elapsed = clock.now.timeIntervalSince(clock.trialStartedAt ?? clock.now)
        if elapsed < trialDuration {
            let remainingSec = trialDuration - elapsed
            let days = Int(ceil(remainingSec / (24 * 60 * 60)))
            trialDaysRemaining = max(0, days)
            mode = .trial
        } else {
            trialDaysRemaining = 0
            mode = .free
        }
    }

    // MARK: - 検証ロジック

    enum VerificationResult: Equatable {
        case success
        case failure(String)
    }

    /// シリアルキーを検証する。
    /// - シリアルキーが `payload.signature` 形式
    /// - payload は base64url
    /// - signature は base64url の RSA-2048 PKCS1 署名
    func verify(serialKey: String) -> VerificationResult {
        let parts = serialKey.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else {
            return .failure("シリアルキー形式が不正です")
        }
        guard let payloadData = Self.decodeBase64URL(String(parts[0])),
              let signatureData = Self.decodeBase64URL(String(parts[1])) else {
            return .failure("Base64URL デコードに失敗")
        }
        guard let pem = publicKeyPEM, !pem.contains("PLACEHOLDER") else {
            // placeholder 環境では検証パス不可なので明示的に失敗にする
            return .failure("公開鍵が未設定です")
        }
        guard let publicKey = Self.publicKey(fromPEM: pem) else {
            return .failure("公開鍵 PEM の読み取りに失敗")
        }

        var error: Unmanaged<CFError>?
        let ok = SecKeyVerifySignature(
            publicKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            payloadData as CFData,
            signatureData as CFData,
            &error
        )
        if !ok {
            let detail = error?.takeRetainedValue().localizedDescription ?? "署名検証失敗"
            return .failure(detail)
        }
        // payload 自体の妥当性 (JSON + plan == "pro")
        guard let dict = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any],
              let plan = dict["plan"] as? String else {
            return .failure("payload JSON の解釈に失敗")
        }
        guard plan == "pro" else {
            return .failure("payload.plan が pro ではありません: \(plan)")
        }
        return .success
    }

    // MARK: - 静的ヘルパー

    /// base64url ("-" / "_") を Data へ。パディング欠落も補正する。
    static func decodeBase64URL(_ input: String) -> Data? {
        var s = input.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - s.count % 4) % 4
        s += String(repeating: "=", count: padding)
        return Data(base64Encoded: s)
    }

    /// PEM 文字列から `SecKey` を生成する (RSA 公開鍵専用)。
    static func publicKey(fromPEM pem: String) -> SecKey? {
        let lines = pem
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
        let base64 = lines.joined()
        guard let der = Data(base64Encoded: base64) else { return nil }
        // SubjectPublicKeyInfo (SPKI) DER から RSA 鍵バイト列を取り出す
        let raw = stripSPKIHeader(der) ?? der

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var error: Unmanaged<CFError>?
        let key = SecKeyCreateWithData(raw as CFData, attributes as CFDictionary, &error)
        return key
    }

    /// SubjectPublicKeyInfo の SEQUENCE 内側の BIT STRING ペイロード (素の RSA modulus+exp DER) を取り出す。
    /// 失敗時は nil を返し、呼び出し側で raw DER をそのまま使うフォールバックを許す。
    private static func stripSPKIHeader(_ data: Data) -> Data? {
        // RFC5280 SubjectPublicKeyInfo:
        //   SEQUENCE {
        //     algorithm AlgorithmIdentifier,
        //     subjectPublicKey BIT STRING
        //   }
        let bytes = [UInt8](data)
        guard bytes.count > 30, bytes[0] == 0x30 else { return nil }
        // SubjectPublicKeyInfo の "RSA Encryption" SPKI ヘッダ固定 (24 バイト)
        let spkiPrefix: [UInt8] = [
            0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09,
            0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01,
            0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00,
        ]
        if bytes.count > spkiPrefix.count
            && Array(bytes.prefix(spkiPrefix.count)) == spkiPrefix {
            return Data(bytes.dropFirst(spkiPrefix.count))
        }
        return nil
    }
}

// MARK: - Keychain 実装

/// Security Framework 経由の本番 Keychain ストア。
struct SecKeychainStore: LicenseManager.LicenseKeychain {
    let account: String
    let service: String = "com.artia.license"

    func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String) -> Bool {
        let data = Data(value.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
        ]
        // 既存があれば update、無ければ add
        let updateAttr: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttr as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// UserDefaults ベースの trial 開始時刻ストア (本番デフォルト)。
struct UserDefaultsTrialClock: LicenseManager.TrialClock {
    static let key = "ArtiaTrialStartedAt"
    var now: Date { Date() }
    var trialStartedAt: Date? {
        get {
            let ts = UserDefaults.standard.double(forKey: Self.key)
            return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: Self.key)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.key)
            }
        }
    }
}
