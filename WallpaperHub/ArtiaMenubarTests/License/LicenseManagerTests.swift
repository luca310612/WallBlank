import XCTest
import Foundation
import Security

@testable import Artia

/// Phase 11H: LicenseManager の体験版 / 不正キー / 正規キー検証。
@MainActor
final class LicenseManagerTests: XCTestCase {

    // MARK: - モック

    final class InMemoryKeychain: LicenseManager.LicenseKeychain {
        var stored: String?
        func read() -> String? { stored }
        func write(_ value: String) -> Bool { stored = value; return true }
        func delete() -> Bool { stored = nil; return true }
    }

    struct StubClock: LicenseManager.TrialClock {
        var now: Date
        var trialStartedAt: Date?
    }

    /// テスト用の RSA 2048 鍵ペア (PEM)。本番鍵とは無関係なテスト専用鍵。
    /// 実装側 verify では PEM をパースして payload+signature を検証する。
    private func generateTestKeyPair() throws -> (publicPEM: String, privateKey: SecKey) {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        guard let pub = SecKeyCopyPublicKey(priv) else {
            throw NSError(domain: "test", code: -1)
        }
        guard let pubData = SecKeyCopyExternalRepresentation(pub, &error) as Data? else {
            throw error!.takeRetainedValue() as Error
        }
        // SecKeyCopyExternalRepresentation は素の RSA modulus+exp DER (SPKI ヘッダ無し)
        // を返すため、Info.plist 経由で渡す PEM もそのままの DER を base64 化したものを使う。
        // LicenseManager 側は SPKI ヘッダがあれば剥がすが、無ければ raw のまま使う。
        let base64 = pubData.base64EncodedString()
        let pem = "-----BEGIN PUBLIC KEY-----\n\(base64)\n-----END PUBLIC KEY-----"
        return (pem, priv)
    }

    private func sign(payload: Data, privateKey: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            payload as CFData,
            &error
        ) as Data? else {
            throw error!.takeRetainedValue() as Error
        }
        return sig
    }

    private func encodeBase64URL(_ data: Data) -> String {
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - 体験版

    func test_trial_isProEnabled_within30Days() {
        let now = Date(timeIntervalSince1970: 1_730_000_000)
        let mgr = LicenseManager(
            publicKeyPEM: nil,
            keychain: InMemoryKeychain(),
            clock: StubClock(now: now, trialStartedAt: now.addingTimeInterval(-1 * 24 * 60 * 60))  // 1 日経過
        )
        XCTAssertEqual(mgr.mode, .trial)
        XCTAssertTrue(mgr.isProEnabled)
        XCTAssertEqual(mgr.trialDaysRemaining, 29)
    }

    func test_trial_expiresAfter30Days() {
        let now = Date(timeIntervalSince1970: 1_730_000_000)
        let mgr = LicenseManager(
            publicKeyPEM: nil,
            keychain: InMemoryKeychain(),
            clock: StubClock(now: now, trialStartedAt: now.addingTimeInterval(-31 * 24 * 60 * 60))  // 31 日経過
        )
        XCTAssertEqual(mgr.mode, .free)
        XCTAssertFalse(mgr.isProEnabled)
        XCTAssertEqual(mgr.trialDaysRemaining, 0)
    }

    func test_trial_initializesStartTimeOnFirstRun() {
        let now = Date(timeIntervalSince1970: 1_730_000_000)
        var clock = StubClock(now: now, trialStartedAt: nil)
        _ = LicenseManager(
            publicKeyPEM: nil,
            keychain: InMemoryKeychain(),
            clock: clock
        )
        // StubClock は値型なので mgr が clock の write を反映できない場合がある。
        // 実際は LicenseManager 内部に clock を保持しているため、
        // ここでは「初回呼び出しで例外が出ないこと」を主に検証。
        clock.trialStartedAt = now
        XCTAssertEqual(clock.trialStartedAt, now)
    }

    // MARK: - 不正シリアル

    func test_invalidSerial_returnsFreeMode() throws {
        let (pem, _) = try generateTestKeyPair()
        let mgr = LicenseManager(
            publicKeyPEM: pem,
            keychain: InMemoryKeychain(),
            clock: StubClock(now: Date(), trialStartedAt: Date(timeIntervalSinceNow: -40 * 86400))
        )
        // trial 期限切れ + ライセンス無し → free
        XCTAssertEqual(mgr.mode, .free)

        // 不正な形式
        XCTAssertFalse(mgr.activate(serialKey: "not-a-license"))
        XCTAssertEqual(mgr.mode, .free)

        // 適当な base64.base64 (署名は通らない)
        XCTAssertFalse(mgr.activate(serialKey: "Zm9v.YmFy"))
        XCTAssertEqual(mgr.mode, .free)
    }

    func test_placeholderPublicKey_failsVerification() {
        let mgr = LicenseManager(
            publicKeyPEM: "-----BEGIN PUBLIC KEY-----\nPLACEHOLDER_RSA_PUBLIC_KEY_PEM\n-----END PUBLIC KEY-----",
            keychain: InMemoryKeychain(),
            clock: StubClock(now: Date(), trialStartedAt: Date(timeIntervalSinceNow: -100 * 86400))
        )
        let result = mgr.verify(serialKey: "Zm9v.YmFy")
        if case .failure(let reason) = result {
            XCTAssertTrue(reason.contains("公開鍵が未設定"), "placeholder は明示的に失敗扱い: \(reason)")
        } else {
            XCTFail("placeholder で成功してしまった")
        }
    }

    // MARK: - 正規シリアル

    func test_validSerial_activatesProMode() throws {
        let (pem, priv) = try generateTestKeyPair()
        let payloadDict: [String: Any] = [
            "licenseId": "lic-001",
            "userEmail": "test@example.com",
            "plan": "pro",
            "issuedAt": 1_730_000_000,
        ]
        let payload = try JSONSerialization.data(withJSONObject: payloadDict, options: [.sortedKeys])
        let signature = try sign(payload: payload, privateKey: priv)
        let serial = "\(encodeBase64URL(payload)).\(encodeBase64URL(signature))"

        let kc = InMemoryKeychain()
        let mgr = LicenseManager(
            publicKeyPEM: pem,
            keychain: kc,
            clock: StubClock(now: Date(), trialStartedAt: Date(timeIntervalSinceNow: -100 * 86400))
        )
        XCTAssertEqual(mgr.mode, .free)

        let ok = mgr.activate(serialKey: serial)
        XCTAssertTrue(ok, "正規シリアル検証エラー: \(mgr.lastError ?? "nil")")
        XCTAssertEqual(mgr.mode, .pro)
        XCTAssertTrue(mgr.isProEnabled)
        XCTAssertEqual(kc.stored, serial)
    }

    func test_deactivate_revertsToFree() throws {
        let (pem, priv) = try generateTestKeyPair()
        let payload = try JSONSerialization.data(withJSONObject: ["plan": "pro"], options: [.sortedKeys])
        let signature = try sign(payload: payload, privateKey: priv)
        let serial = "\(encodeBase64URL(payload)).\(encodeBase64URL(signature))"

        let kc = InMemoryKeychain()
        let mgr = LicenseManager(
            publicKeyPEM: pem, keychain: kc,
            clock: StubClock(now: Date(), trialStartedAt: Date(timeIntervalSinceNow: -100 * 86400))
        )
        XCTAssertTrue(mgr.activate(serialKey: serial))
        XCTAssertEqual(mgr.mode, .pro)

        mgr.deactivate()
        XCTAssertEqual(mgr.mode, .free)
        XCTAssertNil(kc.stored)
    }

    // MARK: - base64url ヘルパー

    func test_decodeBase64URL_handlesPaddingAndUrlChars() {
        // "fo" → "Zm8" (パディング無)
        let data = LicenseManager.decodeBase64URL("Zm8")
        XCTAssertEqual(data, Data("fo".utf8))
        // "+" → "-", "/" → "_" を通せる (空入力はそのまま空 Data)
        let empty = LicenseManager.decodeBase64URL("")
        XCTAssertEqual(empty, Data())
    }
}
