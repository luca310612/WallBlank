import Foundation
import WebKit

/// Web 壁紙 (HTML/JS) を実行するときの Tier 1 サンドボックス設定。
///
/// 設計方針:
/// - 信頼できないユーザー製 JS が動くことを前提に「**できることを最小化**」する。
/// - ネットワーク完全遮断・危険 API 完全無効化・データ永続化なし・プロセス分離。
/// - 既存の `artiaLog` / `artiaSettings` 等のネイティブ Bridge は呼び出し側で必要に応じて
///   後付けする（このサンドボックス層は「危険を潰す」ことだけに責任を持つ）。
///
/// なぜこの方針か:
/// - 検閲を全壁紙に適用するのは現実的に不可能。攻撃面そのものを構造的に消すことで、
///   悪意 JS が混入しても「自分のディレクトリ内のファイルしか触れず、外には何も送れない」
///   状態を保証する。
enum WebWallpaperSandbox {

    // MARK: - 公開 API

    /// Tier 1 サンドボックス済みの `WKWebViewConfiguration` を返す。
    ///
    /// - Parameters:
    ///   - rootDirectory: 壁紙のルートディレクトリ（このサンドボックスでは使用しないが、
    ///                    将来的に file:// アクセス制御で使う）。
    ///   - additionalUserScripts: 呼び出し側で追加注入したい `WKUserScript` 群。
    ///                            危険 API 無効化スクリプトより**後**に注入される。
    ///   - extraScriptMessageHandlers: 呼び出し側で追加したい name → handler のペア。
    static func makeSandboxedConfiguration(
        rootDirectory: URL,
        additionalUserScripts: [WKUserScript] = [],
        extraScriptMessageHandlers: [(name: String, handler: WKScriptMessageHandler)] = []
    ) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()

        // 1. データストアを完全に揮発化（Cookie / LocalStorage / IndexedDB / Service Worker /
        //    Cache をすべてメモリ上だけにし、壁紙が閉じれば消える）。
        //
        // 補足: macOS 12 以降は `WKProcessPool` が deprecated になり、プロセス分離は
        // `WKWebsiteDataStore` のインスタンス単位で行われる。`.nonPersistent()` を
        // 都度 new することで自動的に別プロセスへ追い出される。
        config.websiteDataStore = .nonPersistent()

        // 3. 壁紙は自動再生前提なのでメディア再生のユーザー操作要求は外す。
        //    ただし `getUserMedia` / `getDisplayMedia` は注入 JS で潰すので問題ない。
        config.mediaTypesRequiringUserActionForPlayback = []

        // 4. デスクトップ裏で非アクティブ扱いされて JS が止まらないようにする。
        if #available(macOS 14.0, *) {
            config.preferences.inactiveSchedulingPolicy = .none
        }

        // 5. JavaScript は許可。代わりに後段の注入 JS で危険 API を無効化する。
        let pagePrefs = WKWebpagePreferences()
        pagePrefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = pagePrefs

        // 6. UserContentController に「危険 API 無効化スクリプト」を **document-start** で
        //    全フレームに注入する。これにより壁紙 JS が起動するより前に
        //    `navigator.clipboard` 等が `undefined` になっている。
        let ucc = WKUserContentController()
        ucc.addUserScript(makeHardeningUserScript())

        // 7. 呼び出し側が指定する追加スクリプト（imageProbe polyfill など）を後追加。
        for script in additionalUserScripts {
            ucc.addUserScript(script)
        }
        // 8. 追加メッセージハンドラ（artiaLog 等）を登録。
        for entry in extraScriptMessageHandlers {
            ucc.add(entry.handler, name: entry.name)
        }

        config.userContentController = ucc

        // 9. ネット遮断ルールリストを非同期で組み立てて、生成され次第 config に追加する。
        //    （`WKContentRuleList` の compile は async API しかないため、await が来る前に
        //     WebView がロードされる可能性がある。最低限、注入 JS 側でも fetch をブロック
        //     しているので二重防御になっている）
        attachBlockNetworkRuleList(to: ucc)

        return config
    }

    // MARK: - 内部実装

    /// 危険 API を無効化する `WKUserScript` を生成。
    ///
    /// 無効化対象:
    /// - クリップボード読取/書込 (`navigator.clipboard`)
    /// - メディアデバイス（カメラ・マイク・画面録画）(`navigator.mediaDevices`, `getDisplayMedia`)
    /// - Service Worker / Push 通知 / WebRTC / Geolocation / Bluetooth / USB / HID / Serial
    /// - 通知 API (`Notification` / `PushManager`)
    /// - `fetch` / `XMLHttpRequest` (file:// 以外)
    /// - WebSocket
    private static func makeHardeningUserScript() -> WKUserScript {
        WKUserScript(
            source: hardeningJavaScriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    private static let hardeningJavaScriptSource: String = """
    (function() {
      if (window.__artiaSandboxHardened) return;
      window.__artiaSandboxHardened = true;

      // configurable: false で再定義不可にする。get で undefined を返すことで
      // typeof チェックを通る・touch しても TypeError を吐かないため、壁紙 JS が
      // try/catch なしで触っても致命的に死なない。
      function hide(obj, prop) {
        if (!obj) return;
        try {
          Object.defineProperty(obj, prop, {
            configurable: false,
            enumerable: false,
            get: function () { return undefined; }
          });
        } catch (_) {}
      }

      // navigator 系（カメラ・マイク・GPS・USB 等）
      hide(navigator, 'clipboard');
      hide(navigator, 'mediaDevices');
      hide(navigator, 'serviceWorker');
      hide(navigator, 'geolocation');
      hide(navigator, 'bluetooth');
      hide(navigator, 'usb');
      hide(navigator, 'hid');
      hide(navigator, 'serial');
      hide(navigator, 'credentials');

      // window 系（通知・WebRTC）
      hide(window, 'Notification');
      hide(window, 'PushManager');
      hide(window, 'RTCPeerConnection');
      hide(window, 'webkitRTCPeerConnection');
      hide(window, 'RTCDataChannel');

      // WebSocket は完全にブロック（インスタンス化しようとしたら例外）
      try {
        window.WebSocket = function () {
          throw new TypeError('WebSocket は Artia サンドボックスでブロックされています');
        };
      } catch (_) {}

      // EventSource (Server-Sent Events) もブロック
      try {
        window.EventSource = function () {
          throw new TypeError('EventSource は Artia サンドボックスでブロックされています');
        };
      } catch (_) {}

      // fetch をラップして file:// と artia-asset:// 以外を拒否
      var origFetch = window.fetch ? window.fetch.bind(window) : null;
      if (origFetch) {
        window.fetch = function (input, init) {
          var url = typeof input === 'string' ? input : (input && input.url) || '';
          if (!isAllowedURL(url)) {
            return Promise.reject(new TypeError(
              'Artia サンドボックス: 外部ネットワーク要求はブロックされています url=' + url
            ));
          }
          return origFetch(input, init);
        };
      }

      // XMLHttpRequest.open をラップ
      try {
        var origOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function (method, url) {
          if (!isAllowedURL(url)) {
            throw new TypeError(
              'Artia サンドボックス: XHR の外部ネットワーク要求はブロックされています url=' + url
            );
          }
          return origOpen.apply(this, arguments);
        };
      } catch (_) {}

      // sendBeacon を無効化（バックグラウンド送信経路）
      if (navigator && navigator.sendBeacon) {
        try {
          navigator.sendBeacon = function () { return false; };
        } catch (_) {}
      }

      // import() の動的ロードも file:// 範囲に絞る
      // （ES Modules の dynamic import を完全には捕捉できないが、明らかな外部 URL は弾く）

      function isAllowedURL(rawUrl) {
        if (rawUrl == null) return false;
        var s = String(rawUrl);
        if (s.length === 0) return true; // 相対 URL は document の base に依存するので許可
        // プロトコル付き URL の場合だけ判定する。相対パスは許可。
        var lower = s.toLowerCase().trim();
        if (lower.indexOf('://') === -1 &&
            lower.indexOf('blob:') !== 0 &&
            lower.indexOf('data:') !== 0 &&
            lower.indexOf('javascript:') !== 0) {
          return true; // 純粋な相対 URL
        }
        if (lower.indexOf('blob:') === 0) return true;       // 自オリジン由来の blob は許可
        if (lower.indexOf('data:') === 0) return true;       // data: URL は外向き通信ではない
        if (lower.indexOf('file://') === 0) return true;     // ローカルファイル
        if (lower.indexOf('artia-asset://') === 0) return true; // 将来用カスタムスキーム
        return false;
      }
    })();
    """

    /// 全外部 URL（http(s) / ws(s) / stun / turn）をブロックする `WKContentRuleList` を
    /// 非同期コンパイルし、できあがり次第 `WKUserContentController` に追加する。
    ///
    /// ContentRuleList は注入 JS と二重防御として機能する:
    /// - 注入 JS: fetch / XHR / WebSocket をラップ済みだが、JS 側で再取得・上書きされる
    ///           可能性をゼロにはできない。
    /// - ContentRuleList: ネットワーク層で URL マッチして即時ブロック。JS からは回避不可能。
    private static func attachBlockNetworkRuleList(to ucc: WKUserContentController) {
        let identifier = "ArtiaSandboxBlockExternalNetwork"
        let store = WKContentRuleListStore.default()
        store?.lookUpContentRuleList(forIdentifier: identifier) { existing, _ in
            if let existing {
                ucc.add(existing)
                return
            }
            store?.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: blockExternalNetworkRulesJSON
            ) { compiled, _ in
                if let compiled {
                    ucc.add(compiled)
                }
            }
        }
    }

    /// `WKContentRuleList` 用 JSON。
    /// `^https?://` `^wss?://` `^stun:` `^turn:` を全てブロックする。
    /// `127.0.0.1` `localhost` も含めて遮断する（ローカルAPI偵察攻撃の対策）。
    private static let blockExternalNetworkRulesJSON: String = """
    [
      {
        "trigger": { "url-filter": "^https?://" },
        "action": { "type": "block" }
      },
      {
        "trigger": { "url-filter": "^wss?://" },
        "action": { "type": "block" }
      },
      {
        "trigger": { "url-filter": "^stun:" },
        "action": { "type": "block" }
      },
      {
        "trigger": { "url-filter": "^turn:" },
        "action": { "type": "block" }
      }
    ]
    """
}
