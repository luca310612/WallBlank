import Foundation
import Combine

/// Phase 8.1: Razer Chroma SDK 連携。
/// macOS では Razer Synapse 3 が起動していると http://localhost:54235/razer/chromasdk/ に
/// ローカル REST エンドポイントが立ち上がる前提で接続する。
/// SDK が無い場合は `connect()` が失敗するだけで、アプリ全体は問題なく動作する。
@MainActor
final class RazerChromaClient: ObservableObject {

    // MARK: - 公開状態

    /// 現在接続中かどうか (UI バインド用)
    @Published private(set) var isConnected: Bool = false
    /// 最終エラー文字列 (UI 表示用、診断目的)
    @Published private(set) var lastError: String?
    /// 取得済みの sessionid。`/chromasdk/{sessionid}` の構築に使う
    @Published private(set) var sessionURL: URL?

    // MARK: - 依存注入

    /// REST 通信用 URLSession (テストでは MockProtocol を差し込み可能)
    let session: URLSession
    /// SDK ベース URL (デフォルト: http://localhost:54235)
    let baseURL: URL

    /// Razer SDK init で送信するアプリ情報
    struct ChromaAppInfo: Codable {
        let title: String
        let description: String
        let author: ChromaAuthor
        let device_supported: [String]
        let category: String

        struct ChromaAuthor: Codable {
            let name: String
            let contact: String
        }

        static var artiaDefault: ChromaAppInfo {
            ChromaAppInfo(
                title: "Artia",
                description: "Artia 壁紙エンジン (macOS) のキーボード/デバイス連動",
                author: ChromaAuthor(name: "Artia Team", contact: "https://artia.app"),
                device_supported: ["keyboard", "mouse", "headset", "mousepad", "keypad", "chromalink"],
                category: "application"
            )
        }
    }

    /// Razer SDK init レスポンス
    private struct ChromaInitResponse: Codable {
        let sessionid: Int
        let uri: String
    }

    /// PUT /chromasdk/keyboard/custom 用ペイロード
    /// 6x22 行列 (= 132 個) の BGR (=> ARGB の Int32) を要求するが、ここでは効果(EFFECT_CUSTOM)を簡略化し
    /// `effect: "CHROMA_STATIC"` で単色のみを送る最小実装にとどめる。
    /// LedColorMirror はベースとなる色を渡すだけでよい。
    struct ChromaKeyboardPayload: Codable {
        let effect: String
        let param: ChromaColorParam
    }
    struct ChromaColorParam: Codable {
        let color: Int  // BGR 24bit (= 0x00BBGGRR)
    }

    /// ハートビート用タイマー (5 秒間隔; 30 秒以内に呼ばないと SDK 側がセッションを破棄する)
    private var heartbeatTimer: Timer?

    init(
        baseURL: URL = URL(string: "http://localhost:54235")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - 接続/切断

    /// SDK init を呼び出し、sessionid を取得する。
    /// 成功時は `isConnected = true` + `sessionURL` を保持し、ハートビートを開始する。
    /// 失敗時は warning ログを残すだけで例外は投げない (graceful degradation)。
    func connect(appInfo: ChromaAppInfo = .artiaDefault) async {
        let initURL = baseURL.appendingPathComponent("razer/chromasdk")
        do {
            var request = URLRequest(url: initURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(appInfo)

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                await handleConnectFailure("Razer Chroma init: HTTP \(code)")
                return
            }
            let decoded = try JSONDecoder().decode(ChromaInitResponse.self, from: data)
            // SDK 側 uri をそのまま使う (例: http://localhost:54236/sid=<n>)
            guard let url = URL(string: decoded.uri) else {
                await handleConnectFailure("Razer Chroma init: 不正な uri")
                return
            }
            self.sessionURL = url
            self.isConnected = true
            self.lastError = nil
            startHeartbeat()
            debugChromaLog("[Chroma] 接続成功: sessionid=\(decoded.sessionid)")
        } catch {
            await handleConnectFailure("Razer Chroma init: \(error.localizedDescription)")
        }
    }

    /// セッションを終了する (DELETE /chromasdk/{sessionid})。
    /// 接続中でなければ何もしない。
    func disconnect() async {
        stopHeartbeat()
        guard let sessionURL else {
            isConnected = false
            return
        }
        do {
            var request = URLRequest(url: sessionURL)
            request.httpMethod = "DELETE"
            _ = try await session.data(for: request)
        } catch {
            // 切断は成功しなくても致命的ではない
            debugChromaLog("[Chroma] disconnect 失敗 (無視): \(error.localizedDescription)")
        }
        self.sessionURL = nil
        self.isConnected = false
    }

    /// 単色をキーボード全体に送信する (LedColorMirror から呼ばれる)。
    /// 接続前に呼ばれた場合は no-op。
    /// - Parameter bgr: 0x00BBGGRR の 24bit カラー
    func sendKeyboardSolidColor(bgr: Int) async {
        guard isConnected, let sessionURL else { return }
        let endpoint = sessionURL.appendingPathComponent("keyboard")
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let payload = ChromaKeyboardPayload(
                effect: "CHROMA_STATIC",
                param: ChromaColorParam(color: bgr)
            )
            request.httpBody = try JSONEncoder().encode(payload)
            _ = try await session.data(for: request)
        } catch {
            debugChromaLog("[Chroma] keyboard PUT 失敗: \(error.localizedDescription)")
        }
    }

    /// 24bit RGB を Razer の BGR (Int) に変換する純粋関数。テストから直接呼べる。
    /// - Parameters:
    ///   - red, green, blue: 0..255
    /// - Returns: 0x00BBGGRR
    nonisolated static func bgrInt(red: Int, green: Int, blue: Int) -> Int {
        let r = max(0, min(255, red))
        let g = max(0, min(255, green))
        let b = max(0, min(255, blue))
        return (b << 16) | (g << 8) | r
    }

    // MARK: - ハートビート

    private func startHeartbeat() {
        stopHeartbeat()
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.sendHeartbeat()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.heartbeatTimer = timer
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    /// PUT /heartbeat (空 body) でセッションを保つ
    private func sendHeartbeat() async {
        guard isConnected, let sessionURL else { return }
        let endpoint = sessionURL.appendingPathComponent("heartbeat")
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "PUT"
            _ = try await session.data(for: request)
        } catch {
            // ハートビート失敗は警告のみ。次回接続で再試行可能。
            debugChromaLog("[Chroma] heartbeat 失敗: \(error.localizedDescription)")
        }
    }

    // MARK: - エラー時共通処理

    private func handleConnectFailure(_ message: String) async {
        self.isConnected = false
        self.sessionURL = nil
        self.lastError = message
        debugChromaLog("[Chroma] WARN \(message) — 機能を自動 disable")
    }
}

/// 内部用簡易ロガー (debugLog がアプリターゲット内でしか定義されていないテストでも使える)
private func debugChromaLog(_ message: String) {
    #if DEBUG
    print(message)
    #endif
}
