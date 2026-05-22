import Foundation
import WebKit
import XCTest

@testable import WallBlank

/// Phase 3B: Wallpaper Engine 互換 JS API ブリッジが期待通りに振る舞うことを確認する。
/// - bridge.js が WKWebView 上で評価され `wallpaperRegister*` が定義される
/// - JS → Native: `artia.property.update` メッセージ受信で `WebWallpaperBridgeHandler` の
///   userProperties が更新される
/// - Native → JS: `dispatchProperty` 経由で listener の最終値が JS 側に届く
/// - Audio listener 登録から native dispatch まで実際に listener が呼ばれることを確認する
///
/// テスト方針:
/// - 実 WKWebView を `about:blank` にロードし、bridge.js を WKUserScript として注入する。
/// - DisplayWallpaperInstance 経路を通すと依存が大きいので、UI 層を介さず直接 ucc に bridge handler を差し込む。
/// - 非同期は `XCTestExpectation` + `evaluateJavaScript` の completion を組み合わせる。
@MainActor
final class WebBridgeTests: XCTestCase {

    private func makeWebView(handler: WebWallpaperBridgeHandler) async -> WKWebView {
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(handler, name: WebWallpaperBridgeHandler.messageName)

        guard let bridgeJS = DisplayWallpaperInstance.loadWallpaperBridgeScript() else {
            XCTFail("wallpaper-bridge.js をバンドルから読み出せませんでした")
            return WKWebView()
        }
        ucc.addUserScript(WKUserScript(
            source: bridgeJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        config.userContentController = ucc

        let webView = WKWebView(frame: .zero, configuration: config)
        handler.webView = webView

        // bridge.js を確実に走らせるために about:blank をロードして DOM を作る。
        let html = "<!doctype html><html><head><meta charset='utf-8'></head><body></body></html>"
        let loaded = expectation(description: "loadHTMLString")
        let observer = NavigationObserver { loaded.fulfill() }
        webView.navigationDelegate = observer
        webView.loadHTMLString(html, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 5)
        // observer は test 終了まで保持しておく必要がある。
        objc_setAssociatedObject(webView, &Self.observerKey, observer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return webView
    }

    private static var observerKey: UInt8 = 0

    private final class NavigationObserver: NSObject, WKNavigationDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onFinish() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { onFinish() }
    }

    /// 全 register* が JS 側に定義され、type 判定が "function" になっていることを確認する。
    func test_bridgeJS_definesAllWallpaperEngineAPIs() async throws {
        let handler = WebWallpaperBridgeHandler()
        let webView = await makeWebView(handler: handler)

        let probe = """
        JSON.stringify({
          audio: typeof window.wallpaperRegisterAudioListener,
          props: typeof window.wallpaperRegisterMediaPropertiesListener,
          playback: typeof window.wallpaperRegisterMediaPlaybackListener,
          random: typeof window.wallpaperRequestRandomFileForProperty,
          dispatch: typeof window.__artiaBridge,
          dispatchAudio: typeof (window.__artiaBridge && window.__artiaBridge.dispatchAudio),
          updateProperty: typeof (window.__artiaBridge && window.__artiaBridge.updateProperty)
        });
        """
        let resultString = try await evaluate(webView, probe) as? String ?? ""
        let data = Data(resultString.utf8)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            XCTFail("JS の typeof レポートが JSON として解釈できなかった: \(resultString)")
            return
        }
        XCTAssertEqual(dict["audio"], "function", "wallpaperRegisterAudioListener が未定義")
        XCTAssertEqual(dict["props"], "function", "wallpaperRegisterMediaPropertiesListener が未定義")
        XCTAssertEqual(dict["playback"], "function", "wallpaperRegisterMediaPlaybackListener が未定義")
        XCTAssertEqual(dict["random"], "function", "wallpaperRequestRandomFileForProperty が未定義")
        XCTAssertEqual(dict["dispatch"], "object", "__artiaBridge が生えていない")
        XCTAssertEqual(dict["dispatchAudio"], "function", "__artiaBridge.dispatchAudio が未定義")
        XCTAssertEqual(dict["updateProperty"], "function", "__artiaBridge.updateProperty が未定義")
    }

    /// JS → Native: `__artiaBridge.updateProperty(name, value)` が
    /// `artia.property.update` として handler に届き userProperties が更新されること。
    func test_jsUpdateProperty_propagatesToNativeStore() async throws {
        let handler = WebWallpaperBridgeHandler(initialUserProperties: [
            "speed": ["value": 0.5]
        ])
        let webView = await makeWebView(handler: handler)

        _ = try await evaluate(webView, "window.__artiaBridge.updateProperty('speed', 0.9); 'ok';")

        // postMessage はメインスレッドへ非同期で届くため、短いポーリングで完了を待つ。
        try await waitUntil(timeout: 3.0) {
            handler.lastPropertyUpdate?.name == "speed"
        }
        XCTAssertEqual(handler.lastPropertyUpdate?.name, "speed")
        let stored = handler.currentUserProperties()["speed"]?["value"] as? Double
        XCTAssertEqual(stored, 0.9, "JS 側 updateProperty で Native の userProperties が更新されるべき")
    }

    /// Native → JS: `updateUserProperty` で broadcast すると JS 側で
    /// `wallpaperPropertyListener.applyUserProperties(values)` が発火し最後の値を保持できる。
    func test_nativeUpdate_broadcastsToJSPropertyListener() async throws {
        let handler = WebWallpaperBridgeHandler()
        let webView = await makeWebView(handler: handler)

        // 壁紙側は wallpaperPropertyListener.applyUserProperties を独自実装する想定。
        _ = try await evaluate(webView, """
        window.__artiaWPLastValues = null;
        if (!window.wallpaperPropertyListener) { window.wallpaperPropertyListener = {}; }
        window.wallpaperPropertyListener.applyUserProperties = function(v) {
          window.__artiaWPLastValues = v;
        };
        'ok';
        """)

        handler.updateUserProperty(name: "tint", value: "#ffaabb")

        // broadcastUserProperties は DispatchQueue.main.async で evaluateJavaScript を発行するため待つ。
        try await waitUntil(timeout: 3.0) {
            let result = try? await self.evaluate(webView, "JSON.stringify(window.__artiaWPLastValues)") as? String
            return result?.contains("#ffaabb") == true
        }
    }

    /// Audio listener 登録から native の dispatchAudio で listener が実際に呼ばれることを確認する。
    func test_audioListener_receivesNativeDispatch() async throws {
        let handler = WebWallpaperBridgeHandler()
        let webView = await makeWebView(handler: handler)

        _ = try await evaluate(webView, """
        window.__artiaAudioCallCount = 0;
        window.__artiaAudioLastBins = -1;
        window.wallpaperRegisterAudioListener(function(samples) {
          window.__artiaAudioCallCount++;
          window.__artiaAudioLastBins = samples.length;
        });
        'ok';
        """)

        // Audio timer (30Hz) は subscribe で動き始めるが、テスト時間を読まずに済むよう
        // dispatchMediaPlayback 同様に明示的に dispatch をエミュレートする。
        _ = try await evaluate(webView, """
        window.__artiaBridge.dispatchAudio({ samples: new Array(64).fill(0), fft: new Array(64).fill(0), sampleRate: 44100 });
        'ok';
        """)

        let bins = try await evaluate(webView, "window.__artiaAudioLastBins") as? Int
        let calls = try await evaluate(webView, "window.__artiaAudioCallCount") as? Int
        XCTAssertEqual(bins, 64, "audio listener には 64 bin の payload が届くべき")
        XCTAssertEqual(calls, 1, "audio listener は dispatchAudio に同期で呼ばれるべき")
    }

    // MARK: - Helpers

    /// `evaluateJavaScript` を async/await で扱う薄いヘルパ。
    private func evaluate(_ webView: WKWebView, _ js: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                webView.evaluateJavaScript(js) { result, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: result)
                    }
                }
            }
        }
    }

    /// 条件が true になるまで指数バックオフでポーリング。
    /// Why: WKScriptMessageHandler は postMessage 後に非同期でメインスレッドに届くので、
    ///      テストは短いリポーリングで反映を待つ必要がある。
    private func waitUntil(timeout: TimeInterval, predicate: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var delay: UInt64 = 30_000_000
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: delay)
            delay = min(delay * 2, 250_000_000)
        }
        XCTFail("waitUntil タイムアウト (\(timeout)s)")
    }
}
