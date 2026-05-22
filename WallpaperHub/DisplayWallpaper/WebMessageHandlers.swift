import Foundation
import WebKit

// MARK: - WKWebView ログ／設定ハンドラ
// Why: Web 壁紙からのメッセージ (`artiaLog` / `artiaSettings` / `artiaWebBridge`) を受信して
// アプリ側ログ・設定 JSON 永続化・Wallpaper Engine 互換 API への橋渡しを行う。
// `DisplayWallpaperInstance.swift` から分離し、責務を明確化する。

/// Web 壁紙の `artiaLog` メッセージをアプリログへ転送する。
final class WebLogHandler: NSObject, WKScriptMessageHandler {
    private let displayID: String

    init(displayID: String) {
        self.displayID = displayID
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "artiaLog" else { return }
        if let dict = message.body as? [String: Any] {
            let level = (dict["level"] as? String) ?? "log"
            let text = (dict["message"] as? String) ?? "\(dict)"
            debugLog("[Web:\(displayID)] [\(level)] \(text)")
            if level == "error" || level == "warn" {
                artiaWebLog("[Web:\(displayID)] [\(level)] \(text)")
            }
        } else {
            debugLog("[Web:\(displayID)] \(message.body)")
        }
    }
}

/// Web 壁紙の `artiaSettings` (read/write/clear) を `setting.json` に永続化する。
final class WebWallpaperSettingsHandler: NSObject, WKScriptMessageHandler {
    private let rootDirectory: URL
    private let settingsURL: URL

    init(rootDirectory: URL, displayID: String, isDisplaySynchronized: Bool) {
        self.rootDirectory = rootDirectory
        if isDisplaySynchronized {
            self.settingsURL = rootDirectory.appendingPathComponent("setting.json")
        } else {
            self.settingsURL = rootDirectory.appendingPathComponent("setting.\(displayID).json")
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "artiaSettings",
              let body = message.body as? [String: Any],
              let command = body["command"] as? String else {
            return
        }

        switch command {
        case "read":
            handleRead(message: message)
        case "write":
            handleWrite(body: body, message: message)
        case "clear":
            handleClear(message: message)
        default:
            respond(to: message, payload: ["ok": false, "error": "unsupported_command"])
        }
    }

    private func handleRead(message: WKScriptMessage) {
        do {
            guard FileManager.default.fileExists(atPath: settingsURL.path) else {
                respond(to: message, payload: ["ok": true, "exists": false])
                return
            }

            let data = try Data(contentsOf: settingsURL)
            let object = try JSONSerialization.jsonObject(with: data, options: [])
            respond(to: message, payload: ["ok": true, "exists": true, "data": object])
        } catch {
            respond(to: message, payload: ["ok": false, "error": error.localizedDescription])
        }
    }

    private func handleWrite(body: [String: Any], message: WKScriptMessage) {
        guard let data = body["data"], JSONSerialization.isValidJSONObject(data) else {
            respond(to: message, payload: ["ok": false, "error": "invalid_json"])
            return
        }

        do {
            try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true, attributes: nil)
            let jsonData = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
            try jsonData.write(to: settingsURL, options: .atomic)
            respond(to: message, payload: ["ok": true, "path": settingsURL.path])
        } catch {
            respond(to: message, payload: ["ok": false, "error": error.localizedDescription])
        }
    }

    private func handleClear(message: WKScriptMessage) {
        do {
            if FileManager.default.fileExists(atPath: settingsURL.path) {
                try FileManager.default.removeItem(at: settingsURL)
            }
            respond(to: message, payload: ["ok": true])
        } catch {
            respond(to: message, payload: ["ok": false, "error": error.localizedDescription])
        }
    }

    private func respond(to message: WKScriptMessage, payload: [String: Any]) {
        guard let body = message.body as? [String: Any],
              let callbackID = body["callbackID"] as? String,
              let webView = message.webView,
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return
        }

        let escapedCallbackID = callbackID
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let script = "window.__artiaSettingsBridgeResolve && window.__artiaSettingsBridgeResolve('\(escapedCallbackID)', \(json));"
        DispatchQueue.main.async {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }
}

// MARK: - WebWallpaperBridgeHandler
// Why: Wallpaper Engine 互換 JS API (`wallpaperRegisterAudioListener` 等) を Native 側で受け取り、
// Audio / Media / User Properties / RandomFile の各経路に振り分ける単一エントリ。
// 1 つのハンドラに集約しているのは、JS 側 (`window.webkit.messageHandlers.artiaWebBridge`) の参照を 1 系統で済ませ、
// 壁紙 JS の互換性確認を簡潔にするため。`type` フィールドで Sub-command を切り替える。

/// Wallpaper Engine 互換 API を受け取り Audio / Media / Property に振り分ける。
final class WebWallpaperBridgeHandler: NSObject, WKScriptMessageHandler {

    /// `wallpaper-bridge.js` を `WKUserContentController` 登録名と JS 側参照名を統一するための定数。
    static let messageName = "artiaWebBridge"

    /// User Properties の現在値。`project.json` 由来の defaults をベースに JS 側からの更新を反映する。
    /// シリアライズ可能な辞書として保持し、`evaluateJavaScript` で再 dispatch する。
    private var userProperties: [String: [String: Any]]

    /// Audio dispatch ループ (ゼロフィル PCM) を回す Timer。Phase 6A で実機サンプルへ差し替え予定。
    private var audioTimer: Timer?

    /// Media properties / playback の購読フラグ。Phase 3B では subscribe 受領のみ記録し、ペイロードは空で配信する。
    private(set) var mediaPropertiesSubscribed = false
    private(set) var mediaPlaybackSubscribed = false

    /// 紐付く WKWebView。Native → JS dispatch のために弱参照。
    weak var webView: WKWebView?

    /// 直前に `artia.property.update` で受領したキー / 値（テスト spy 用に保持）。
    private(set) var lastPropertyUpdate: (name: String, value: Any)?

    /// 受信メッセージの履歴（テスト spy 用）
    private(set) var receivedMessages: [[String: Any]] = []

    init(initialUserProperties: [String: [String: Any]] = [:]) {
        self.userProperties = initialUserProperties
        super.init()
    }

    deinit {
        audioTimer?.invalidate()
        audioTimer = nil
    }

    /// 現在キャッシュされている User Properties を返す（読み取り専用 view）。
    func currentUserProperties() -> [String: [String: Any]] {
        userProperties
    }

    /// Native 側から User Property を更新し、JS 側 listener へ再 dispatch する。
    /// Why: アプリ UI (SwiftUI 設定画面など) から壁紙へ値を流し込むユースケース。
    func updateUserProperty(name: String, value: Any) {
        userProperties[name] = ["value": value]
        broadcastUserProperties()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName else { return }
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else {
            return
        }
        receivedMessages.append(body)

        switch type {
        case "artia.audio.subscribe":
            startAudioDispatch()
        case "artia.audio.unsubscribe":
            stopAudioDispatch()
        case "artia.property.update":
            applyPropertyUpdate(body: body)
        case "artia.property.requestRandomFile":
            handleRandomFileRequest(body: body)
        case "artia.media.subscribe":
            applyMediaSubscribe(body: body)
        case "artia.media.unsubscribe":
            applyMediaUnsubscribe(body: body)
        default:
            // 未知タイプは黙って無視する。壁紙 JS の前方互換のため。
            break
        }
    }

    // MARK: - Property

    private func applyPropertyUpdate(body: [String: Any]) {
        guard let name = body["name"] as? String, !name.isEmpty else { return }
        let value = body["value"] ?? NSNull()
        userProperties[name] = ["value": value]
        lastPropertyUpdate = (name, value)
        broadcastUserProperties()
    }

    /// 現在の値を `wallpaperPropertyListener.applyUserProperties` 経由で JS 側へ届ける。
    private func broadcastUserProperties() {
        guard let webView else { return }
        guard JSONSerialization.isValidJSONObject(userProperties),
              let data = try? JSONSerialization.data(withJSONObject: userProperties, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        let script = """
        (function(){
          if (window.__artiaBridge && typeof window.__artiaBridge.dispatchProperty === 'function') {
            try { window.__artiaBridge.dispatchProperty(\(json)); } catch (_) {}
          }
        })();
        """
        DispatchQueue.main.async {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    // MARK: - Random File

    private func handleRandomFileRequest(body: [String: Any]) {
        guard let token = body["token"] as? String, !token.isEmpty else { return }
        // Phase 3B: 実装雛形のみ。空文字列 (= 「対象なし」) を返して JS 側コールバックを必ず resolve させる。
        // Phase 6 で User Properties に紐付くフォルダから抽選する実装に差し替える。
        let escapedToken = token
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let script = "window.__artiaBridge && window.__artiaBridge.resolveRandomFile && window.__artiaBridge.resolveRandomFile('\(escapedToken)', '');"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    // MARK: - Media

    private func applyMediaSubscribe(body: [String: Any]) {
        let kind = (body["kind"] as? String) ?? ""
        switch kind {
        case "properties":
            mediaPropertiesSubscribed = true
            // Phase 3B: 即時に空ペイロードを 1 度だけ届け、API 形を固める。
            dispatchMediaProperties(payload: [:])
        case "playback":
            mediaPlaybackSubscribed = true
            dispatchMediaPlayback(payload: ["state": "stopped", "position": 0])
        default:
            break
        }
    }

    private func applyMediaUnsubscribe(body: [String: Any]) {
        let kind = (body["kind"] as? String) ?? ""
        switch kind {
        case "properties": mediaPropertiesSubscribed = false
        case "playback": mediaPlaybackSubscribed = false
        default:
            mediaPropertiesSubscribed = false
            mediaPlaybackSubscribed = false
        }
    }

    func dispatchMediaProperties(payload: [String: Any]) {
        guard let webView, JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        let script = "window.__artiaBridge && window.__artiaBridge.dispatchMediaProperties && window.__artiaBridge.dispatchMediaProperties(\(json));"
        DispatchQueue.main.async {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    func dispatchMediaPlayback(payload: [String: Any]) {
        guard let webView, JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        let script = "window.__artiaBridge && window.__artiaBridge.dispatchMediaPlayback && window.__artiaBridge.dispatchMediaPlayback(\(json));"
        DispatchQueue.main.async {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    // MARK: - Audio

    /// Phase 3B 雛形: 30Hz でゼロフィル 64 bin を流す。Phase 6A で実 PCM/FFT に差し替える。
    /// Why: WE 壁紙の中には「audio listener が呼ばれる」前提で UI 更新を駆動するものがあり、
    /// payload が空でも呼び出し自体が起きていれば壁紙ロジックが進むケースが多いため、まず callback を回し続ける。
    private func startAudioDispatch() {
        stopAudioDispatch()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tickAudioDispatch()
        }
        audioTimer = timer
        // Run loop に明示的に登録（タイマーが scrollTracking モードでも止まらないようにする）。
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopAudioDispatch() {
        audioTimer?.invalidate()
        audioTimer = nil
    }

    private func tickAudioDispatch() {
        guard let webView else { return }
        // 64 bin のゼロフィル PCM サンプル / FFT を JS 側 dispatchAudio に流す。
        let zeros = Array(repeating: 0.0, count: 64)
        let payload: [String: Any] = [
            "samples": zeros,
            "fft": zeros,
            "sampleRate": 44100
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        let script = "window.__artiaBridge && window.__artiaBridge.dispatchAudio && window.__artiaBridge.dispatchAudio(\(json));"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}
