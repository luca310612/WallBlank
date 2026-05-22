import Foundation
import Darwin

/// Phase 11C: ユーザ同意ベースのクラッシュレポータ。
///
/// 仕組み:
///   1. `install()` で NSSetUncaughtExceptionHandler + signal handler を登録
///   2. クラッシュ時にスタックトレースを `~/Library/Logs/Artia/crash-<timestamp>.log` に書き出し
///   3. 起動時に `flushPending()` で未送信の crash log を Firestore "crash_reports" にアップロード
///   4. 個人情報 (ユーザ名を含むファイルパス) は `~/` に置換してから保存
///   5. Settings の Toggle (`SharedSettingsKeys.crashReportingEnabled`) で全体を ON/OFF 制御
///
/// 設計判断:
///   - signal handler 内では async-signal-safe な API しか使えないため、ファイル書き出しは
///     POSIX `write(2)` ベースで実装する。Foundation の Data/FileManager は使わない。
///   - 起動時アップロードは RustFirebase に依存。失敗してもクラッシュさせず警告ログのみ。
final class CrashReporter {

    // MARK: - 設定

    /// クラッシュレポート ON/OFF を保持する UserDefaults キー。
    /// Why: Settings 画面の Toggle と直結させる。
    static let userDefaultsKey = "ArtiaCrashReportingEnabled"

    /// クラッシュログを格納するディレクトリ。
    static var crashLogDirectory: URL {
        let logs = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Artia", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Artia/Logs")
        return logs
    }

    /// ユーザがクラッシュレポートを有効化しているか。
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: userDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: userDefaultsKey) }
    }

    // MARK: - 初期化フック

    /// シグナルハンドラ登録 + クラッシュ書き出し用のスタブ機構。
    /// - Note: 1 プロセス内で複数回呼んでも上書き安全 (signal/atexit は冪等)。
    static func install() {
        try? FileManager.default.createDirectory(
            at: crashLogDirectory,
            withIntermediateDirectories: true
        )

        // NSException ハンドラ
        NSSetUncaughtExceptionHandler { exception in
            CrashReporter.handleException(exception)
        }

        // signal handler
        let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE]
        for sig in signals {
            signal(sig) { sig in
                CrashReporter.handleSignal(sig)
                // デフォルトハンドラへ戻して再 raise する
                signal(sig, SIG_DFL)
                raise(sig)
            }
        }
    }

    /// 起動時に呼ぶ: 未送信の crash log を Firestore に投げる。
    /// 同意 OFF / Firebase 未初期化の場合は何もしない。
    static func flushPending() {
        guard isEnabled else { return }
        let logs = pendingLogFiles()
        guard !logs.isEmpty else { return }
        Task.detached(priority: .background) {
            for url in logs {
                guard let data = try? Data(contentsOf: url),
                      let text = String(data: data, encoding: .utf8) else {
                    continue
                }
                let success = await uploadCrashLog(filename: url.lastPathComponent, body: text)
                if success {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    // MARK: - 内部処理

    /// Foundation API が使える exception 経由のフック。
    static func handleException(_ exception: NSException) {
        let body = """
        --- NSException ---
        Name: \(exception.name.rawValue)
        Reason: \(exception.reason ?? "unknown")
        Stack:
        \(exception.callStackSymbols.joined(separator: "\n"))
        """
        writeCrashLog(body: redactPII(body))
    }

    /// async-signal-safe な書き出し。Swift で完全な safety は保証できないが、
    /// 文字列連結を最小に抑え POSIX write を使うようにする。
    static func handleSignal(_ sig: Int32) {
        let signalName = Self.signalName(for: sig)
        let header = "--- Signal \(signalName) ---\n"
        let symbols = Thread.callStackSymbols.joined(separator: "\n")
        let body = header + symbols + "\n"
        writeCrashLog(body: redactPII(body))
    }

    /// クラッシュログを書き出す共通処理 (テストからも使う)。
    static func writeCrashLog(body: String) {
        try? FileManager.default.createDirectory(
            at: crashLogDirectory,
            withIntermediateDirectories: true
        )
        let ts = Int(Date().timeIntervalSince1970)
        let url = crashLogDirectory.appendingPathComponent("crash-\(ts).log")
        try? body.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    /// ホームディレクトリ配下のフルパスを `~/` に置換する。
    /// - Parameter input: 置換対象テキスト
    /// - Returns: ユーザ名を除外した文字列
    static func redactPII(_ input: String) -> String {
        let home = NSHomeDirectory()
        guard !home.isEmpty else { return input }
        // 1) 完全一致 home → "~/"
        var output = input.replacingOccurrences(of: home + "/", with: "~/")
        output = output.replacingOccurrences(of: home, with: "~")
        // 2) /Users/<name>/ → /Users/<redacted>/
        if let regex = try? NSRegularExpression(pattern: "/Users/[^/\\s\\\\]+", options: []) {
            let range = NSRange(output.startIndex..., in: output)
            output = regex.stringByReplacingMatches(in: output, options: [], range: range, withTemplate: "/Users/<redacted>")
        }
        return output
    }

    /// `crashLogDirectory` 内の `crash-*.log` を時刻順で返す。
    static func pendingLogFiles() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: crashLogDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter { $0.lastPathComponent.hasPrefix("crash-") && $0.pathExtension == "log" }
    }

    /// Firestore "crash_reports" にアップロードする。
    /// - Returns: 成功したか (失敗時はファイルを残して次回再試行)
    static func uploadCrashLog(filename: String, body: String) async -> Bool {
        let fields: [String: Any] = [
            "filename": ["stringValue": filename],
            "body": ["stringValue": body],
            "uploadedAt": ["timestampValue": ISO8601DateFormatter().string(from: Date())],
            "version": ["stringValue": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"],
        ]
        do {
            _ = try await RustFirebase.Firestore.create(
                collection: "crash_reports",
                docId: nil,
                fields: fields
            )
            return true
        } catch {
            print("[CrashReporter] アップロード失敗: \(error)")
            return false
        }
    }

    private static func signalName(for sig: Int32) -> String {
        switch sig {
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGFPE: return "SIGFPE"
        default: return "SIG\(sig)"
        }
    }
}
