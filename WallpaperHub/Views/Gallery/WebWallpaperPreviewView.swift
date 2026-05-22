import SwiftUI
import MetalKit
import AVFoundation
import ImageIO
import WebKit

// MARK: - WebWallpaperPreviewView
// Why: Web 壁紙のプレビュー WKWebView と Preloader 群を集約。

struct WebWallpaperPreviewView: NSViewRepresentable {
    let rootURL: URL
    let onLoadFinished: () -> Void

    func makeNSView(context: Context) -> PreviewWKWebView {
        artiaWebLog("[PreviewDiag] makeNSView root=\(rootURL.path)")
        if let prewarmed = WebWallpaperPreviewPreloader.shared.take(
            rootURL: rootURL,
            coordinator: context.coordinator,
            onLoadFinished: onLoadFinished
        ) {
            artiaWebLog("[PreviewDiag] makeNSView using PREWARMED webView frame=\(prewarmed.frame) hasFinishedLoading=\(context.coordinator.hasFinishedLoading)")
            return prewarmed
        }
        artiaWebLog("[PreviewDiag] makeNSView creating NEW webView (no prewarm cache)")
        return Self.makeWebView(rootURL: rootURL, coordinator: context.coordinator)
    }

    func updateNSView(_ webView: PreviewWKWebView, context: Context) {
        context.coordinator.onLoadFinished = onLoadFinished
        let oldFrame = context.coordinator.lastObservedFrame
        let newFrame = webView.frame
        if oldFrame != newFrame {
            artiaWebLog("[PreviewDiag] updateNSView frame change \(oldFrame) -> \(newFrame)")
            context.coordinator.lastObservedFrame = newFrame
            // SwiftUI でサイズが拡大された後、Web 壁紙の vh/vw 計算を作り直すため resize を発火させる
            webView.evaluateJavaScript("try{window.dispatchEvent(new Event('resize'));}catch(e){}", completionHandler: nil)
        }
        if context.coordinator.rootURL?.standardizedFileURL.path != rootURL.standardizedFileURL.path {
            artiaWebLog("[PreviewDiag] updateNSView rootURL changed -> reload \(rootURL.path)")
            context.coordinator.reset(for: rootURL)
            webView.configuration.userContentController.removeAllUserScripts()
            webView.configuration.userContentController.addUserScript(WKUserScript(
                source: Self.previewBootstrapJavaScript(rootURL: rootURL),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
            webView.loadWebWallpaper(rootURL: rootURL, coordinator: context.coordinator)
        }
    }

    static func dismantleNSView(_ webView: PreviewWKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "artiaPreviewLog")
        // LocalHTTPFileServer.stop() は I/O で主スレッドを占有するため background へ逃がす
        let coord = coordinator
        DispatchQueue.global(qos: .utility).async {
            coord.stopServer()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(rootURL: rootURL, onLoadFinished: onLoadFinished)
    }

    fileprivate static func makeWebView(rootURL: URL, coordinator: Coordinator) -> PreviewWKWebView {
        let webView = PreviewWKWebView(frame: .zero, configuration: makeConfiguration(rootURL: rootURL, coordinator: coordinator))
        webView.navigationDelegate = coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(true, forKey: "drawsBackground")
        webView.loadWebWallpaper(rootURL: rootURL, coordinator: coordinator)
        return webView
    }

    fileprivate static func makeConfiguration(rootURL: URL, coordinator: Coordinator) -> WKWebViewConfiguration {
        // Tier 1 サンドボックスを基盤に組み立てる。
        // - websiteDataStore = .nonPersistent() / 危険 API 全無効化 / 外部ネット遮断
        // - 既存の artiaPreviewLog ハンドラと previewBootstrap スクリプトはサンドボックス上に重ねて
        //   注入する（順序: ハードニング → bootstrap）。
        let config = WebWallpaperSandbox.makeSandboxedConfiguration(rootDirectory: rootURL)

        let ucc = config.userContentController
        ucc.add(PreviewWebLogHandler(), name: "artiaPreviewLog")
        ucc.addUserScript(WKUserScript(
            source: previewBootstrapJavaScript(rootURL: rootURL),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        return config
    }

    fileprivate static func previewBootstrapJavaScript(rootURL: URL) -> String {
        let user = WallpaperEngineWebUserProperties.defaultUserProperties(forProjectRoot: rootURL)
        let general = WallpaperEngineWebUserProperties.defaultGeneralProperties()
        let propertyBridge = WallpaperEngineWebUserProperties.propertyBridgeJavaScript(
            userProperties: user,
            generalProperties: general
        ) ?? ""

        return """
        (function() {
          try {
            Object.defineProperty(document, 'hidden', { configurable: true, get: function() { return false; } });
            Object.defineProperty(document, 'visibilityState', { configurable: true, get: function() { return 'visible'; } });
          } catch (_) {}
        })();
        \(Self.previewConsoleBridgeJavaScript())
        \(Self.dataJsonDurationBypassJavaScript())
        \(Self.obfuscatedImageShimJavaScript())
        \(Self.obfuscatedMediaShimJavaScript())
        \(Self.imageProbePolyfillJavaScript())
        \(Self.previewPlaybackNudgeJavaScript())
        \(Self.webKitStackFixJavaScript())
        \(Self.previewDiagnosticsJavaScript())
        \(propertyBridge)
        """
    }

    /// `<audio>` / `<video>` 要素も Image 同様に難読化キー経由で `src` に代入されるケース（例: 3679122549）。
    /// `document.getElementById` で取得された HTMLMediaElement を Proxy で包み、未知プロパティへの URL 代入を
    /// `src` にマッピングする。`previewPlaybackNudgeJavaScript` が定期的に `el.play()` を蹴るため、src さえ
    /// 入れば再生は始まる。
    fileprivate static func obfuscatedMediaShimJavaScript() -> String {
        """
        (function() {
          if (window.__artiaPreviewObfuscatedMediaShim) return;
          window.__artiaPreviewObfuscatedMediaShim = true;
          if (typeof Proxy !== 'function') return;
          var KNOWN_PROPS = {
            src:1, srcObject:1, currentTime:1, duration:1, muted:1, volume:1, paused:1, ended:1,
            playbackRate:1, defaultPlaybackRate:1, preservesPitch:1, autoplay:1, loop:1, controls:1,
            preload:1, crossOrigin:1, networkState:1, readyState:1, seeking:1, seekable:1, buffered:1,
            played:1, currentSrc:1, error:1, mediaKeys:1, controller:1, audioTracks:1, videoTracks:1,
            textTracks:1, mediaGroup:1, sinkId:1, disableRemotePlayback:1, srcset:1,
            id:1, className:1, style:1, title:1, lang:1, dir:1, tabIndex:1, hidden:1, draggable:1, dataset:1,
            innerHTML:1, outerHTML:1, textContent:1, width:1, height:1, alt:1, name:1
          };
          function isLikelyMediaURL(v) {
            if (typeof v !== 'string' || v.length === 0) return false;
            if (/^(data:|blob:|https?:|file:)/i.test(v)) return true;
            if (/\\.(mp3|m4a|aac|wav|flac|opus|ogg|mp4|mov|webm)(\\?|#|$)/i.test(v)) return true;
            if (v.indexOf('/') !== -1 && v.indexOf('.') !== -1) return true;
            return false;
          }
          function wrap(el) {
            if (!el || el.__artiaShimWrapped) return el;
            try {
              Object.defineProperty(el, '__artiaShimWrapped', { value: true });
            } catch (_) { return el; }
            return new Proxy(el, {
              set: function(target, prop, value) {
                if (typeof prop !== 'string') { target[prop] = value; return true; }
                if (KNOWN_PROPS[prop] === 1 || prop.indexOf('on') === 0) {
                  target[prop] = value;
                  return true;
                }
                if (typeof value === 'function') {
                  // メディアでは未知 fn 代入は基本ノイズ（イベントハンドラの再マップは行わない）
                  target[prop] = value;
                  return true;
                }
                if (isLikelyMediaURL(value) && (!target.src || target.src === window.location.href)) {
                  try { console.log('[ArtiaMediaShim] ' + (target.tagName || '?') + ' str-prop ' + prop + ' -> src (' + String(value).slice(-60) + ')'); } catch (_) {}
                  target.src = value;
                  try { target.load && target.load(); } catch (_) {}
                  return true;
                }
                target[prop] = value;
                return true;
              },
              get: function(target, prop) {
                var v = target[prop];
                return typeof v === 'function' ? v.bind(target) : v;
              }
            });
          }
          var nativeGetById = document.getElementById.bind(document);
          document.getElementById = function(id) {
            var el = nativeGetById(id);
            if (!el) return el;
            var t = (el.tagName || '').toLowerCase();
            if (t === 'audio' || t === 'video') return wrap(el);
            return el;
          };
          var nativeQuerySelector = document.querySelector.bind(document);
          document.querySelector = function(sel) {
            var el = nativeQuerySelector(sel);
            if (!el) return el;
            var t = (el.tagName || '').toLowerCase();
            if (t === 'audio' || t === 'video') return wrap(el);
            return el;
          };
        })();
        """
    }

    /// Workshop 製の難読化 Web 壁紙では `new Image()` のプロパティ名が `src` / `onload` ではなく
    /// `prdRH` / `select` のような実行時キーになっているケースがある（例: 3679122549 系の音楽プレイヤー）。
    /// この場合 `await checkImageExists(...)` の Promise が永久に resolve せず `initBackgrounds()` が固まり、
    /// 背景・音楽・MV が真っ黒のまま UI だけ表示される。Proxy で未知プロパティ書き込みを `onload`/`onerror`/`src` に
    /// マッピングしてプレビューを生かす。
    fileprivate static func obfuscatedImageShimJavaScript() -> String {
        """
        (function() {
          if (window.__artiaPreviewObfuscatedImageShim) return;
          window.__artiaPreviewObfuscatedImageShim = true;
          var NativeImage = window.Image;
          if (typeof NativeImage !== 'function' || typeof Proxy !== 'function') return;
          var KNOWN_PROPS = {
            src:1, srcset:1, onload:1, onerror:1, onabort:1, onloadstart:1, onloadend:1, onprogress:1,
            crossOrigin:1, referrerPolicy:1, alt:1, width:1, height:1, decoding:1, loading:1, sizes:1,
            useMap:1, isMap:1, complete:1, naturalWidth:1, naturalHeight:1, currentSrc:1, id:1,
            className:1, style:1, title:1, lang:1, dir:1, tabIndex:1, hidden:1, draggable:1, dataset:1
          };
          function isLikelyURL(v) {
            if (typeof v !== 'string' || v.length === 0) return false;
            if (/^(data:|blob:|https?:|file:)/i.test(v)) return true;
            if (/\\.(png|jpe?g|webp|gif|svg|bmp|ico)(\\?|#|$)/i.test(v)) return true;
            if (v.indexOf('/') !== -1 || v.indexOf('.') !== -1) return true;
            return false;
          }
          window.Image = function ArtiaShimImage(w, h) {
            var img = (arguments.length >= 2) ? new NativeImage(w, h) : new NativeImage();
            return new Proxy(img, {
              set: function(target, prop, value) {
                if (typeof prop !== 'string') { target[prop] = value; return true; }
                if (KNOWN_PROPS[prop] === 1 || prop.indexOf('on') === 0) {
                  target[prop] = value;
                  return true;
                }
                if (typeof value === 'function') {
                  if (typeof target.onload !== 'function') {
                    target.onload = value;
                    try { console.log('[ArtiaImgShim] fn-prop ' + prop + ' -> onload'); } catch (_) {}
                    return true;
                  }
                  if (typeof target.onerror !== 'function') {
                    target.onerror = value;
                    try { console.log('[ArtiaImgShim] fn-prop ' + prop + ' -> onerror'); } catch (_) {}
                    return true;
                  }
                  target[prop] = value;
                  return true;
                }
                if (isLikelyURL(value) && !target.src) {
                  try { console.log('[ArtiaImgShim] str-prop ' + prop + ' -> src (' + String(value).slice(-60) + ')'); } catch (_) {}
                  target.src = value;
                  return true;
                }
                target[prop] = value;
                return true;
              },
              get: function(target, prop) {
                var v = target[prop];
                return typeof v === 'function' ? v.bind(target) : v;
              }
            });
          };
          window.Image.prototype = NativeImage.prototype;
        })();
        """
    }

    /// 真っ白原因を Web 側から記録するための簡易診断（bg-layer の computed style や img タグの状態を一定間隔で console に出す）。
    fileprivate static func previewDiagnosticsJavaScript() -> String {
        """
        (function() {
          if (window.__artiaPreviewDiagnostics) return;
          window.__artiaPreviewDiagnostics = true;
          function snapshot(tag) {
            try {
              var bg1 = document.getElementById('bg-layer-1');
              var bg2 = document.getElementById('bg-layer-2');
              var s1 = bg1 ? getComputedStyle(bg1) : null;
              var s2 = bg2 ? getComputedStyle(bg2) : null;
              var imgs = document.getElementsByTagName('img');
              var first = [];
              for (var i = 0; i < Math.min(imgs.length, 3); i++) {
                first.push((imgs[i].src || '').slice(-60) + '#nw=' + imgs[i].naturalWidth);
              }
              var info = {
                tag: tag,
                w: window.innerWidth,
                h: window.innerHeight,
                children: document.body ? document.body.children.length : -1,
                bg1: s1 ? (s1.backgroundImage + '|' + s1.opacity + '|' + s1.display) : 'none',
                bg2: s2 ? (s2.backgroundImage + '|' + s2.opacity + '|' + s2.display) : 'none',
                imgN: imgs.length,
                imgs: first,
                hasListener: !!window.wallpaperPropertyListener
              };
              console.log('[ArtiaDiag]', JSON.stringify(info));
            } catch (e) {
              console.log('[ArtiaDiag] error', String(e));
            }
          }
          document.addEventListener('DOMContentLoaded', function() { snapshot('DOMContentLoaded'); }, { once: true });
          window.addEventListener('load', function() { snapshot('load'); }, { once: true });
          window.addEventListener('resize', function() { snapshot('resize:' + window.innerWidth + 'x' + window.innerHeight); });
          setTimeout(function(){ snapshot('1s'); }, 1000);
          setTimeout(function(){ snapshot('3s'); }, 3000);
          setTimeout(function(){ snapshot('6s'); }, 6000);
        })();
        """
    }

    fileprivate static func previewConsoleBridgeJavaScript() -> String {
        """
        (function() {
          if (window.__artiaPreviewConsoleBridge) return;
          window.__artiaPreviewConsoleBridge = true;
          function post(level, args) {
            try {
              window.webkit.messageHandlers.artiaPreviewLog.postMessage({
                level: level,
                message: Array.prototype.map.call(args, function(v) {
                  try { return typeof v === 'string' ? v : JSON.stringify(v); }
                  catch (_) { return String(v); }
                }).join(' ')
              });
            } catch (_) {}
          }
          ['log','info','warn','error'].forEach(function(level) {
            var original = console[level];
            console[level] = function() {
              post(level, arguments);
              if (original) {
                try { original.apply(console, arguments); } catch (_) {}
              }
            };
          });
          window.addEventListener('error', function(event) {
            post('error', ['GLOBAL_ERROR:', event.message, event.filename + ':' + event.lineno + ':' + event.colno]);
          });
          window.addEventListener('unhandledrejection', function(event) {
            post('error', ['UNHANDLED_REJECTION:', event.reason]);
          });
        })();
        """
    }

    fileprivate static func dataJsonDurationBypassJavaScript() -> String {
        """
        (function() {
          if (window.__artiaPreviewDataJsonDurationBypass) return;
          window.__artiaPreviewDataJsonDurationBypass = true;
          if (typeof window.fetch !== 'function' || typeof window.Response !== 'function') return;

          var nativeFetch = window.fetch.bind(window);
          function isDataJson(input) {
            try {
              var raw = typeof input === 'string' ? input : (input && input.url);
              if (!raw) return false;
              var url = new URL(raw, window.location.href);
              return /(^|\\/)data\\.json$/i.test(url.pathname);
            } catch (_) {
              return false;
            }
          }

          window.fetch = function(input, init) {
            var rawUrl = typeof input === 'string' ? input : (input && input.url) || '';
            var isData = isDataJson(input);
            if (isData) {
              try { console.log('[ArtiaFetch] data.json START url=' + rawUrl); } catch (_) {}
            }
            return nativeFetch(input, init).then(function(response) {
              if (isData) {
                try { console.log('[ArtiaFetch] data.json RES status=' + (response && response.status) + ' ok=' + (response && response.ok)); } catch (_) {}
              }
              if (!isData || !response || !response.ok) return response;
              return response.clone().json().then(function(items) {
                try { console.log('[ArtiaFetch] data.json PARSED isArray=' + Array.isArray(items) + ' len=' + (Array.isArray(items) ? items.length : -1)); } catch (_) {}
                if (!Array.isArray(items)) return response;
                for (var i = 0; i < items.length; i++) {
                  if (items[i] && !items[i].durationSec) {
                    items[i].durationSec = 180;
                  }
                }
                return new Response(JSON.stringify(items), {
                  status: response.status,
                  statusText: response.statusText,
                  headers: response.headers
                });
              }).catch(function(e) {
                try { console.log('[ArtiaFetch] data.json PARSE_ERROR ' + String(e)); } catch (_) {}
                return response;
              });
            }).catch(function(e) {
              if (isData) {
                try { console.log('[ArtiaFetch] data.json FETCH_ERROR ' + String(e)); } catch (_) {}
              }
              throw e;
            });
          };
        })();
        """
    }

    fileprivate static func imageProbePolyfillJavaScript() -> String {
        // 以前は HEAD で存在確認だけして onload を呼ぶ実装になっていたが、ネイティブの src セッターを呼ばないため
        // `img.src` が空のままになり `bg-layer.style.backgroundImage = url(img.src)` が `url("")` になり背景が真っ黒になっていた。
        // HEAD で 200 が返ったら通常通り src をネイティブセットして実画像をロードする。404 系のときだけ onerror へショートカットする。
        """
        (function() {
          if (window.__artiaPreviewImageProbePolyfill) return;
          window.__artiaPreviewImageProbePolyfill = true;
          var NativeImage = window.Image;
          function shouldProbe(url) {
            return typeof url === 'string' && url.length > 0 &&
              (url.indexOf('background/') !== -1 || url.indexOf('thumb/') !== -1);
          }
          window.Image = function ArtiaPreviewImage(width, height) {
            var img = (arguments.length >= 2) ? new NativeImage(width, height) : new NativeImage();
            var desc = Object.getOwnPropertyDescriptor(HTMLImageElement.prototype, 'src');
            if (!desc || !desc.get || !desc.set) return img;
            Object.defineProperty(img, 'src', {
              configurable: true,
              enumerable: true,
              get: function() { return desc.get.call(img); },
              set: function(val) {
                if (!shouldProbe(val)) {
                  desc.set.call(img, val);
                  return;
                }
                fetch(val, { method: 'HEAD', cache: 'no-store' })
                  .then(function(r) {
                    if (r && r.ok) {
                      desc.set.call(img, val);
                    } else if (typeof img.onerror === 'function') {
                      try { img.onerror.call(img); } catch (e) {}
                    }
                  })
                  .catch(function() {
                    if (typeof img.onerror === 'function') {
                      try { img.onerror.call(img); } catch (e2) {}
                    }
                  });
              }
            });
            return img;
          };
          window.Image.prototype = NativeImage.prototype;
        })();
        """
    }

    fileprivate static func previewPlaybackNudgeJavaScript() -> String {
        """
        (function() {
          if (window.__artiaPreviewPlaybackNudge) return;
          window.__artiaPreviewPlaybackNudge = true;
          function nudgeMedia() {
            var media = document.querySelectorAll('video, audio');
            for (var i = 0; i < media.length; i++) {
              var el = media[i];
              try {
                el.muted = el.tagName.toLowerCase() === 'video' ? true : el.muted;
                var p = el.play && el.play();
                if (p && typeof p.catch === 'function') p.catch(function() {});
              } catch (_) {}
            }
            try { window.dispatchEvent(new Event('resize')); } catch (_) {}
          }
          document.addEventListener('DOMContentLoaded', nudgeMedia, { once: true });
          window.addEventListener('load', nudgeMedia, { once: true });
          window.addEventListener('pageshow', nudgeMedia);
          document.addEventListener('visibilitychange', nudgeMedia);
          setTimeout(nudgeMedia, 300);
          setTimeout(nudgeMedia, 1200);
          setTimeout(nudgeMedia, 3000);
        })();
        """
    }

    /// Workshop の音楽プレイヤー型 Web 壁紙が `Loading...` で固まらないように、
    /// 本番 (`DisplayWallpaperInstance`) の `nudgePlaybackJS` 相当をプレビューでも `didFinish` 後に流す。
    /// playlist の URL を絶対化し、`loadSong` / `applyBackground` / `playSong` を蹴って起動を完了させる。
    fileprivate static func playbackKickJavaScript() -> String {
        """
        (function() {
          if (window.__artiaPreviewPlaybackRepairInstalled) return;
          window.__artiaPreviewPlaybackRepairInstalled = true;

          // playlist がいつ・誰によってセットされるか追跡する（既にセットされていれば現状値を即時表示）
          try {
            if (Object.prototype.hasOwnProperty.call(window, 'playlist')) {
              console.log('[ArtiaKick] playlist ALREADY present at install: isArray=' + Array.isArray(window.playlist) + ' len=' + (Array.isArray(window.playlist) ? window.playlist.length : -1));
            } else {
              var __pl;
              Object.defineProperty(window, 'playlist', {
                configurable: true,
                enumerable: true,
                get: function() { return __pl; },
                set: function(v) {
                  __pl = v;
                  try {
                    console.log('[ArtiaKick] playlist SET isArray=' + Array.isArray(v) + ' len=' + (Array.isArray(v) ? v.length : -1));
                  } catch (_) {}
                }
              });
            }
          } catch (eDef) {
            try { console.log('[ArtiaKick] playlist defineProperty FAILED ' + String(eDef)); } catch (_) {}
          }

          function abs(url) {
            if (typeof url !== 'string' || !url) return url;
            try { return new URL(url, location.href).href; } catch (_) { return url; }
          }

          function normalizePlaylistURLs() {
            if (!Array.isArray(window.playlist)) return false;
            window.playlist.forEach(function(track) {
              if (!track || typeof track !== 'object') return;
              if (track.musicFile) track.musicFile = abs(track.musicFile);
              if (track.coverImage) track.coverImage = abs(track.coverImage);
              if (track.mv) track.mv = abs(track.mv);
              if (track.subtitle && typeof track.subtitle === 'object') {
                if (track.subtitle.ja) track.subtitle.ja = abs(track.subtitle.ja);
                if (track.subtitle.ko) track.subtitle.ko = abs(track.subtitle.ko);
              }
            });
            return true;
          }

          function restoreCurrentVisuals() {
            try { if (typeof window.applyBackground === 'function') window.applyBackground(); } catch (_) {}
            try { if (typeof window.renderBgGrid === 'function') window.renderBgGrid(); } catch (_) {}
          }

          function startPlayback() {
            try {
              if (typeof window.playSong === 'function') {
                window.playSong();
                return;
              }
            } catch (_) {}

            try { window.isPlaying = true; } catch (_) {}

            try {
              var btn = document.getElementById('btn-play');
              if (btn) btn.innerHTML = '<i class="fas fa-pause"></i>';
            } catch (_) {}

            try {
              var a = document.getElementById('audio-player');
              if (a && a.play) {
                var ap = a.play();
                if (ap && ap.catch) ap.catch(function() {});
              }
            } catch (_) {}

            try {
              var v = document.getElementById('local-video');
              if (v) {
                v.muted = true;
                var vp = v.play ? v.play() : null;
                if (vp && vp.catch) vp.catch(function() {});
              }
            } catch (_) {}
          }

          function reloadCurrentSongIfPossible() {
            if (typeof window.loadSong !== 'function') {
              restoreCurrentVisuals();
              startPlayback();
              return;
            }
            var idx = (typeof window.currentIndex === 'number' && isFinite(window.currentIndex)) ? window.currentIndex : 0;
            try {
              var result = window.loadSong(idx);
              if (result && typeof result.then === 'function') {
                result.then(function() { restoreCurrentVisuals(); startPlayback(); })
                      .catch(function() { restoreCurrentVisuals(); startPlayback(); });
              } else {
                restoreCurrentVisuals();
                startPlayback();
              }
            } catch (_) {
              restoreCurrentVisuals();
              startPlayback();
            }
          }

          function kick(attempt) {
            normalizePlaylistURLs();
            var hasPlaylist = Array.isArray(window.playlist);
            var len = hasPlaylist ? window.playlist.length : -1;
            var hasLoadSong = typeof window.loadSong === 'function';
            var ready = hasPlaylist && len > 0 && hasLoadSong;
            try {
              console.log('[ArtiaKick] attempt=' + attempt +
                ' hasPlaylist=' + hasPlaylist +
                ' len=' + len +
                ' hasLoadSong=' + hasLoadSong +
                ' typeofPlaySong=' + typeof window.playSong +
                ' typeofApplyBg=' + typeof window.applyBackground +
                ' currentIndex=' + window.currentIndex);
            } catch (_) {}
            if (ready) {
              reloadCurrentSongIfPossible();
              return;
            }
            if (attempt >= 30) {
              try { console.log('[ArtiaKick] giving up, fallback startPlayback'); } catch (_) {}
              restoreCurrentVisuals();
              startPlayback();
              return;
            }
            setTimeout(function() { kick(attempt + 1); }, attempt < 6 ? 120 : 350);
          }

          kick(0);
        })();
        """
    }

    fileprivate static func webKitStackFixJavaScript() -> String {
        """
        (function() {
          var css = '#app-wrapper{isolation:isolate}.bg-layer,.bg-layer.active{z-index:0!important}.bg-overlay{z-index:1!important}#local-video-container{z-index:1!important}';
          var el = document.createElement('style');
          el.id = 'artia-preview-webkit-stack-fix';
          el.textContent = css;
          (document.head || document.documentElement).appendChild(el);
        })();
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var rootURL: URL?
        var onLoadFinished: () -> Void
        var lastObservedFrame: CGRect = .zero
        private var server: LocalHTTPFileServer?
        private var didFinish = false

        var hasFinishedLoading: Bool {
            didFinish
        }

        init(rootURL: URL, onLoadFinished: @escaping () -> Void) {
            self.rootURL = rootURL
            self.onLoadFinished = onLoadFinished
        }

        func reset(for rootURL: URL) {
            stopServer()
            self.rootURL = rootURL
            didFinish = false
        }

        func makePreviewURL(for resolved: WallpaperEngineWebResolver.Resolved) -> URL? {
            stopServer()
            do {
                let newServer = LocalHTTPFileServer(rootDirectory: resolved.rootDirectory)
                try newServer.start()
                server = newServer
                let url = try newServer.makeURL(path: Self.relativePath(from: resolved.rootDirectory, to: resolved.entryFile))
                artiaWebLog("[PreviewDiag] LocalHTTP started port=\(newServer.port ?? 0) url=\(url.absoluteString)")
                return url
            } catch {
                debugLog("[Gallery] Web preview LocalHTTP failed: \(error)")
                artiaWebLog("[PreviewDiag] LocalHTTP start FAILED: \(String(describing: error))")
                stopServer()
                return nil
            }
        }

        func stopServer() {
            server?.stop()
            server = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            artiaWebLog("[PreviewDiag] didFinish frame=\(webView.frame) url=\(webView.url?.absoluteString ?? "nil")")
            fireFinished()
            injectWallpaperEngineProperties(into: webView)
            kickPlaybackIfNeeded(into: webView)
            scheduleDOMSnapshot(on: webView)
        }

        /// 音楽プレイヤー型の Workshop Web 壁紙が `Loading...` で固まらないよう playlist の起動を蹴る。
        private func kickPlaybackIfNeeded(into webView: WKWebView) {
            webView.evaluateJavaScript(WebWallpaperPreviewView.playbackKickJavaScript()) { _, error in
                if let error {
                    artiaWebLog("[PreviewDiag] playback kick error: \(error)")
                }
            }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            artiaWebLog("[PreviewDiag] didCommit frame=\(webView.frame) url=\(webView.url?.absoluteString ?? "nil")")
            injectWallpaperEngineProperties(into: webView)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.fireFinished()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            debugLog("[Gallery] Web preview navigation failed: \(error)")
            artiaWebLog("[PreviewDiag] didFail: \(error)")
            fireFinished()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            debugLog("[Gallery] Web preview provisional navigation failed: \(error)")
            artiaWebLog("[PreviewDiag] didFailProvisional: \(error)")
            fireFinished()
        }

        /// 真っ白原因切り分け用: ロード後 0.8s/2.5s/5.0s 時点で DOM の主要状態を記録する。
        private func scheduleDOMSnapshot(on webView: WKWebView) {
            let delays: [TimeInterval] = [0.8, 2.5, 5.0]
            let snapshotJS = """
            (function(){
              try {
                var bg1 = document.getElementById('bg-layer-1');
                var bg2 = document.getElementById('bg-layer-2');
                var wrapper = document.getElementById('app-wrapper');
                var imgs = document.getElementsByTagName('img');
                var imgInfo = [];
                for (var i = 0; i < Math.min(imgs.length, 4); i++) {
                  imgInfo.push({src: imgs[i].src || '', complete: imgs[i].complete, naturalWidth: imgs[i].naturalWidth});
                }
                var s1 = bg1 ? getComputedStyle(bg1) : null;
                var s2 = bg2 ? getComputedStyle(bg2) : null;
                return JSON.stringify({
                  innerWidth: window.innerWidth,
                  innerHeight: window.innerHeight,
                  bodyChildren: document.body ? document.body.children.length : -1,
                  wrapperPresent: !!wrapper,
                  bg1BackgroundImage: s1 ? s1.backgroundImage : null,
                  bg1Width: s1 ? s1.width : null,
                  bg1Height: s1 ? s1.height : null,
                  bg1Display: s1 ? s1.display : null,
                  bg1Opacity: s1 ? s1.opacity : null,
                  bg2BackgroundImage: s2 ? s2.backgroundImage : null,
                  bg2Opacity: s2 ? s2.opacity : null,
                  imgCount: imgs.length,
                  firstImgs: imgInfo,
                  hasWallpaperPropertyListener: !!window.wallpaperPropertyListener
                });
              } catch (e) {
                return 'snapshot error: ' + e.message;
              }
            })();
            """
            for delay in delays {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak webView] in
                    guard let webView else { return }
                    webView.evaluateJavaScript(snapshotJS) { result, error in
                        if let err = error {
                            artiaWebLog("[PreviewDiag] snapshot@\(delay)s error: \(err)")
                            return
                        }
                        let s = (result as? String) ?? "<nil>"
                        artiaWebLog("[PreviewDiag] snapshot@\(delay)s frame=\(webView.frame) \(s)")
                    }
                }
            }
        }

        private func fireFinished() {
            guard !didFinish else { return }
            didFinish = true
            DispatchQueue.main.async {
                self.onLoadFinished()
            }
        }

        private func injectWallpaperEngineProperties(into webView: WKWebView) {
            guard let rootURL else { return }
            let user = WallpaperEngineWebUserProperties.defaultUserProperties(forProjectRoot: rootURL)
            let general = WallpaperEngineWebUserProperties.defaultGeneralProperties()
            guard let js = WallpaperEngineWebUserProperties.propertyBridgeJavaScript(
                userProperties: user,
                generalProperties: general
            ) else { return }

            webView.evaluateJavaScript(js)
            for delay in [1.0, 3.0, 6.0] as [TimeInterval] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak webView] in
                    webView?.evaluateJavaScript(js)
                }
            }
        }

        private static func relativePath(from root: URL, to file: URL) -> String {
            let rootPath = root.standardizedFileURL.path
            let filePath = file.standardizedFileURL.path
            guard filePath.hasPrefix(rootPath) else {
                return file.lastPathComponent
            }
            let rel = String(filePath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return rel.isEmpty ? file.lastPathComponent : rel
        }
    }
}

@MainActor
final class WebWallpaperPreviewPreloader {
    static let shared = WebWallpaperPreviewPreloader()

    private struct Entry {
        let rootPath: String
        let webView: PreviewWKWebView
        let coordinator: WebWallpaperPreviewView.Coordinator
    }

    private var entry: Entry?

    func prewarm(rootURL: URL) {
        let root = WallpaperEngineWebResolver.canonicalFilesystemURL(matching: rootURL) ?? rootURL.standardizedFileURL
        let rootPath = root.path
        if entry?.rootPath == rootPath {
            artiaWebLog("[PreviewDiag] prewarm SKIP (already warmed) root=\(rootPath)")
            return
        }

        discard()

        artiaWebLog("[PreviewDiag] prewarm START root=\(rootPath)")
        let coordinator = WebWallpaperPreviewView.Coordinator(rootURL: root, onLoadFinished: {})
        let webView = WebWallpaperPreviewView.makeWebView(rootURL: root, coordinator: coordinator)
        // 1×1 で起動すると vh/vw 依存の壁紙レイアウトが押し潰されてバグるので、実プレビュー領域に近いサイズで先読みする。
        webView.frame = CGRect(x: 0, y: 0, width: 1280, height: 800)
        coordinator.lastObservedFrame = webView.frame
        entry = Entry(rootPath: rootPath, webView: webView, coordinator: coordinator)
    }

    func take(
        rootURL: URL,
        coordinator: WebWallpaperPreviewView.Coordinator,
        onLoadFinished: @escaping () -> Void
    ) -> PreviewWKWebView? {
        let root = WallpaperEngineWebResolver.canonicalFilesystemURL(matching: rootURL) ?? rootURL.standardizedFileURL
        guard let cached = entry, cached.rootPath == root.path else {
            artiaWebLog("[PreviewDiag] take MISS (no cache for root=\(root.path), cached=\(entry?.rootPath ?? "nil"))")
            return nil
        }

        entry = nil
        cached.webView.removeFromSuperview()
        cached.webView.navigationDelegate = coordinator
        coordinator.rootURL = root
        coordinator.onLoadFinished = onLoadFinished
        coordinator.lastObservedFrame = cached.webView.frame

        artiaWebLog("[PreviewDiag] take HIT root=\(root.path) prewarmedFrame=\(cached.webView.frame) hadFinishedLoading=\(cached.coordinator.hasFinishedLoading)")

        if cached.coordinator.hasFinishedLoading {
            DispatchQueue.main.async {
                onLoadFinished()
            }
        }

        return cached.webView
    }

    private func discard() {
        guard let cached = entry else { return }
        cached.webView.stopLoading()
        cached.webView.navigationDelegate = nil
        cached.webView.configuration.userContentController.removeScriptMessageHandler(forName: "artiaPreviewLog")
        cached.coordinator.stopServer()
        entry = nil
    }
}

final class PreviewWKWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private final class PreviewWebLogHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "artiaPreviewLog" else { return }
        if let dict = message.body as? [String: Any] {
            let level = (dict["level"] as? String) ?? "log"
            let text = (dict["message"] as? String) ?? "\(dict)"
            debugLog("[GalleryPreviewWeb] [\(level)] \(text)")
            // 真っ白原因切り分け中は ArtiaDiag / ArtiaKick / ArtiaFetch を含む console 出力を全て採取する。
            if level == "error" || level == "warn"
                || text.contains("[ArtiaDiag]")
                || text.contains("[ArtiaKick]")
                || text.contains("[ArtiaFetch]") {
                artiaWebLog("[GalleryPreviewWeb] [\(level)] \(text)")
            }
        } else {
            debugLog("[GalleryPreviewWeb] \(message.body)")
            artiaWebLog("[GalleryPreviewWeb] \(message.body)")
        }
    }
}

private extension WKWebView {
    func loadWebWallpaper(rootURL: URL, coordinator: WebWallpaperPreviewView.Coordinator) {
        guard let resolved = WallpaperEngineWebResolver.resolve(rootDirectory: rootURL) else {
            debugLog("[Gallery] Web preview resolve failed: \(rootURL.path)")
            artiaWebLog("[PreviewDiag] loadWebWallpaper resolve FAILED root=\(rootURL.path)")
            coordinator.onLoadFinished()
            return
        }
        artiaWebLog("[PreviewDiag] loadWebWallpaper resolved entry=\(resolved.entryFile.path) root=\(resolved.rootDirectory.path)")

        if let previewURL = coordinator.makePreviewURL(for: resolved) {
            artiaWebLog("[PreviewDiag] load via LocalHTTP url=\(previewURL.absoluteString) currentFrame=\(self.frame)")
            load(URLRequest(url: previewURL))
        } else {
            artiaWebLog("[PreviewDiag] load via file:// fallback entry=\(resolved.entryFile.path)")
            loadFileURL(resolved.entryFile, allowingReadAccessTo: resolved.rootDirectory)
        }
    }
}
