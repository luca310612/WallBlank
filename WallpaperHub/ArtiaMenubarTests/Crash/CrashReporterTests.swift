import XCTest
import Foundation

@testable import WallBlank

/// Phase 11H: CrashReporter のログ書き出しと PII 置換を検証する。
/// 実シグナルを発生させると XCTest プロセスが落ちるため、
/// 公開された pure helper (`writeCrashLog` / `redactPII` / `pendingLogFiles`) を直接テストする。
final class CrashReporterTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 既存ログを掃除してクリーンステートでテストする
        for url in CrashReporter.pendingLogFiles() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func test_writeCrashLog_createsFileInLogDir() {
        CrashReporter.writeCrashLog(body: "テストクラッシュ")
        let pending = CrashReporter.pendingLogFiles()
        XCTAssertFalse(pending.isEmpty)
        let body = (try? String(contentsOf: pending[0], encoding: .utf8)) ?? ""
        XCTAssertTrue(body.contains("テストクラッシュ"))
    }

    func test_redactPII_replacesHomePathWithTilde() {
        let home = NSHomeDirectory()
        let input = "stack frame at \(home)/Library/X.framework"
        let redacted = CrashReporter.redactPII(input)
        XCTAssertFalse(redacted.contains(home))
        XCTAssertTrue(redacted.contains("~/Library/X.framework"))
    }

    func test_redactPII_replacesUsersSlashName() {
        let input = "frame: /Users/alice/Documents/foo.swift:42"
        let redacted = CrashReporter.redactPII(input)
        XCTAssertFalse(redacted.contains("/Users/alice"))
        XCTAssertTrue(redacted.contains("/Users/<redacted>"))
    }

    func test_redactPII_keepsNonHomePaths() {
        let input = "/System/Library/Frameworks/AppKit.framework"
        let redacted = CrashReporter.redactPII(input)
        XCTAssertEqual(redacted, input)
    }

    func test_pendingLogFiles_filtersOnlyArtiaLogs() throws {
        // 1) 任意のファイルを WallBlank ログディレクトリに書く (フィルタ確認用)
        try? FileManager.default.createDirectory(
            at: CrashReporter.crashLogDirectory,
            withIntermediateDirectories: true
        )
        let unrelated = CrashReporter.crashLogDirectory.appendingPathComponent("unrelated.txt")
        try Data("noise".utf8).write(to: unrelated)
        defer { try? FileManager.default.removeItem(at: unrelated) }

        // 2) crash- log を書く
        CrashReporter.writeCrashLog(body: "x")
        let pending = CrashReporter.pendingLogFiles()
        XCTAssertTrue(pending.allSatisfy {
            $0.lastPathComponent.hasPrefix("crash-") && $0.pathExtension == "log"
        })
    }

    func test_isEnabled_defaultsToFalse() {
        // setUp 直後はユーザ同意 OFF を期待 (実装側 default false)
        UserDefaults.standard.removeObject(forKey: CrashReporter.userDefaultsKey)
        XCTAssertFalse(CrashReporter.isEnabled)
    }

    func test_isEnabled_canBeToggled() {
        CrashReporter.isEnabled = true
        XCTAssertTrue(CrashReporter.isEnabled)
        CrashReporter.isEnabled = false
        XCTAssertFalse(CrashReporter.isEnabled)
    }
}
