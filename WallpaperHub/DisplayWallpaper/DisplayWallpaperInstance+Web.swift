import Cocoa
import MetalKit
import SwiftUI
import WebKit

// MARK: - DisplayWallpaperInstance + Web
// Why: WKWebView 系の壁紙ロード・設定・ライフサイクル・JS ブリッジを集約。

extension DisplayWallpaperInstance {

    func isWebWallpaperDirectory(_ url: URL) -> Bool {
        WallpaperEngineWebResolver.resolve(rootDirectory: url) != nil
    }

    func declaredAspectRatio(forWebProjectRoot root: URL) -> CGFloat? {
        let projectURL = root.appendingPathComponent("project.json")
        let resolved = WallpaperEngineWebResolver.canonicalFilesystemURL(matching: projectURL) ?? projectURL
        guard let data = try? Data(contentsOf: resolved),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let candidates = [
            obj["description"] as? String,
            obj["title"] as? String
        ].compactMap { $0 }

        let pattern = #"(?:^|[^\d])(\d{1,2})\s*:\s*(\d{1,2})(?:[^\d]|$)"#
        let regex = try? NSRegularExpression(pattern: pattern)

        for candidate in candidates {
            let nsRange = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex?.firstMatch(in: candidate, options: [], range: nsRange),
                  match.numberOfRanges >= 3,
                  let widthRange = Range(match.range(at: 1), in: candidate),
                  let heightRange = Range(match.range(at: 2), in: candidate),
                  let width = Double(candidate[widthRange]),
                  let height = Double(candidate[heightRange]),
                  height > 0 else {
                continue
            }
            return CGFloat(width) / CGFloat(height)
        }

        return nil
    }

    func shouldForceAspectFitForWebWallpaper(projectRoot root: URL) -> Bool {
        guard let declaredAspect = declaredAspectRatio(forWebProjectRoot: root) else { return false }
        let screenAspect = screen.frame.width / max(screen.frame.height, 1)
        return abs(screenAspect - declaredAspect) > 0.015
    }

    func scheduleWebAspectFitBridge(for webView: WKWebView) {
        guard let root = webWallpaperProjectRoot else { return }
        let shouldForceAspectFit = shouldForceAspectFitForWebWallpaper(projectRoot: root)
        let fitBackgroundSize = shouldForceAspectFit ? "contain" : "cover"
        let fitObjectMode = shouldForceAspectFit ? "contain" : "cover"

        let js = #"""
        (function() {
          var styleId = 'artia-web-aspect-fit-fix';
          var bgScale = \#(currentWebWallpaperScale);
          var css = [
            '.bg-layer,',
            '[id^="bg-layer"],',
            '[class^="bg-layer"],',
            '[class*=" bg-layer"] {',
            '  background-size: \#(fitBackgroundSize) !important;',
            '  background-repeat: no-repeat !important;',
            '  background-position: center center !important;',
            '  transform: translate(-50%, -50%) scale(' + bgScale + ') !important;',
            '}',
            '#local-video,',
            '#local-video-container video {',
            '  object-fit: \#(fitObjectMode) !important;',
            '  transform: scale(' + bgScale + ') !important;',
            '  transform-origin: center center !important;',
            '}'
          ].join('\n');

          var style = document.getElementById(styleId);
          if (!style) {
            style = document.createElement('style');
            style.id = styleId;
            style.textContent = css;
            (document.head || document.documentElement).appendChild(style);
          } else if (style.textContent !== css) {
            style.textContent = css;
          }

          try { window.dispatchEvent(new Event('resize')); } catch (e) {}
        })();
        """#

        webView.evaluateJavaScript(js) { [weak self] _, err in
            guard let self else { return }
            if let err {
                debugLog("[Web:\(self.displayID)] aspect fit bridge eval: \(err)")
            } else {
                artiaWebLog("[Web:\(self.displayID)] aspect fit bridge enabled scale=\(String(format: "%.2f", self.currentWebWallpaperScale))")
            }
        }
    }

    static func isSameResolvedDirectory(_ a: URL, _ b: URL) -> Bool {
        let ca = WallpaperEngineWebResolver.canonicalFilesystemURL(matching: a.standardizedFileURL) ?? a.standardizedFileURL
        let cb = WallpaperEngineWebResolver.canonicalFilesystemURL(matching: b.standardizedFileURL) ?? b.standardizedFileURL
        return ca.path == cb.path
    }

    func noteWebWallpaperLoadStarted(for root: URL) {
        webWallpaperLastRequestedRoot = root
        webWallpaperLastLoadStartedAt = Date()
        webWallpaperLastLoadFinishedAt = nil
    }

    func noteWebWallpaperLoadFinished(for root: URL?) {
        if let root {
            webWallpaperLastRequestedRoot = root
        }
        webWallpaperLastLoadFinishedAt = Date()
        webContentTerminationWindowStartedAt = nil
        webContentTerminationReloadCount = 0
    }

    func resetWebWallpaperLoadTracking() {
        webWallpaperLastLoadStartedAt = nil
        webWallpaperLastLoadFinishedAt = nil
        webWallpaperLastRequestedRoot = nil
    }

    func discardPendingWebWallpaper() {
        pendingWebWallpaperView?.stopLoading()
        pendingWebWallpaperView?.removeFromSuperview()
        pendingWebWallpaperView = nil
        pendingWebSchemeHandler = nil
        pendingWebWallpaperProjectRoot = nil
        pendingWebWallpaperEntryFileURL = nil
        pendingWebReadinessProbeTargetID = nil
        endPendingWebWallpaperPresentation(restoreVisibleWallpaper: true)
    }

    func beginPendingWebWallpaperPresentation() {
        isWebWallpaperPendingActivation = true
        clearWallpaperTransitionOverlay()
    }

    func endPendingWebWallpaperPresentation(restoreVisibleWallpaper: Bool) {
        let wasPending = isWebWallpaperPendingActivation
        isWebWallpaperPendingActivation = false
        guard wasPending else { return }

        if restoreVisibleWallpaper {
            if isWebWallpaperActive {
                webWallpaperView?.isHidden = false
                metalView?.isHidden = true
            } else {
                metalView?.isHidden = false
            }
        }
        updateWindowPresentation()
    }

    func activatePendingWebWallpaperIfNeeded(_ webView: WKWebView) {
        guard let pendingView = pendingWebWallpaperView, webView === pendingView else { return }
        guard let root = wallpaperRootView, let metal = metalView else { return }

        webWallpaperView?.stopLoading()
        webWallpaperView?.removeFromSuperview()
        webWallpaperView = pendingView
        pendingWebWallpaperView = nil

        webSchemeHandler = pendingWebSchemeHandler
        pendingWebSchemeHandler = nil
        webWallpaperProjectRoot = pendingWebWallpaperProjectRoot
        pendingWebWallpaperProjectRoot = nil
        webWallpaperEntryFileURL = pendingWebWallpaperEntryFileURL
        pendingWebWallpaperEntryFileURL = nil
        pendingWebReadinessProbeTargetID = nil

        let stackAnchor = menuBarBlendView ?? metal
        if pendingView.superview !== root {
            root.addSubview(pendingView, positioned: .above, relativeTo: stackAnchor)
        } else {
            root.addSubview(pendingView, positioned: .above, relativeTo: stackAnchor)
        }
        isWebWallpaperPendingActivation = false
        pendingView.isHidden = false

        isWebWallpaperActive = true
        isWebWallpaperPlaybackPaused = false
        updateWindowPresentation()
        metal.isHidden = true
        metal.isPaused = true
        clearWallpaperTransitionOverlay()
        // Phase 3B: bridge handler に活性 WebView を紐付け、Native → JS dispatch を可能にする。
        webBridgeHandler?.webView = pendingView
        syncWebWallpaperPlaybackState(reason: "activatePendingWebWallpaper", force: true)
    }

    func schedulePendingWebWallpaperActivationIfReady(
        _ webView: WKWebView,
        startedAt: Date = Date(),
        isRecursiveProbe: Bool = false
    ) {
        guard webView === pendingWebWallpaperView else { return }
        let probeID = ObjectIdentifier(webView)
        if !isRecursiveProbe {
            if pendingWebReadinessProbeTargetID == probeID {
                return
            }
            pendingWebReadinessProbeTargetID = probeID
        }

        let readinessJS = #"""
        (function() {
          function safePlay(el) {
            if (!el || typeof el.play !== 'function') return;
            try {
              var p = el.play();
              if (p && typeof p.catch === 'function') p.catch(function() {});
            } catch (e) {}
          }

          function kickPlaybackBootstrap() {
            try {
              if (typeof window.loadSong === 'function' &&
                  Array.isArray(window.playlist) &&
                  window.playlist.length > 0 &&
                  !window.__artiaPendingSongLoadTriggered) {
                window.__artiaPendingSongLoadTriggered = true;
                var idx = (typeof window.currentIndex === 'number' && isFinite(window.currentIndex)) ? window.currentIndex : 0;
                try {
                  var result = window.loadSong(idx);
                  if (result && typeof result.catch === 'function') {
                    result.catch(function() {});
                  }
                } catch (e) {}
              }
            } catch (e) {}

            try { safePlay(document.getElementById('audio-player')); } catch (e) {}
            try {
              var v = document.getElementById('local-video');
              if (v) v.muted = true;
              safePlay(v);
            } catch (e) {}
          }

          var images = Array.prototype.slice.call(document.images || []);
          var videos = Array.prototype.slice.call(document.querySelectorAll('video'));
          var audios = Array.prototype.slice.call(document.querySelectorAll('audio'));
          kickPlaybackBootstrap();

          var imagesReady = images.every(function(img) { return !!img.complete; });
          var videosReady = videos.every(function(el) {
            var src = el.currentSrc || el.src || '';
            if (!src) return true;
            return el.readyState >= 2 || el.ended;
          });

          var audiosReady = audios.every(function(el) {
            var src = el.currentSrc || el.src || '';
            if (!src) return false;
            var hasDuration = Number.isFinite(el.duration) && el.duration > 0;
            var canRenderAudioUI = el.readyState >= 3 || el.ended;
            return hasDuration && canRenderAudioUI;
          });

          var titleEl = document.getElementById('track-title');
          var titleReady = !titleEl || (titleEl.textContent || '').trim().toLowerCase() !== 'loading...';

          var playlistReady = !audios.length || (
            Array.isArray(window.playlist) &&
            window.playlist.length > 0 &&
            typeof window.loadSong === 'function'
          );

          return document.readyState === 'complete' &&
            imagesReady &&
            videosReady &&
            audiosReady &&
            titleReady &&
            playlistReady;
        })();
        """#

        webView.evaluateJavaScript(readinessJS) { [weak self, weak webView] result, error in
            guard let self, let webView, webView === self.pendingWebWallpaperView else { return }

            let timedOut = Date().timeIntervalSince(startedAt) >= Self.webWallpaperReadyTimeout
            if let error {
                debugLog("[Web:\(self.displayID)] readiness probe error: \(error)")
            }

            if let ready = result as? Bool, ready {
                self.pendingWebReadinessProbeTargetID = nil
                self.activatePendingWebWallpaperIfNeeded(webView)
                self.finalizeLoadedWebWallpaperIfNeeded(webView)
                return
            }

            if timedOut {
                artiaWebLog("[Web:\(self.displayID)] readiness wait timed out after \(Self.webWallpaperReadyTimeout)s")
                self.pendingWebReadinessProbeTargetID = nil
                self.activatePendingWebWallpaperIfNeeded(webView)
                self.finalizeLoadedWebWallpaperIfNeeded(webView)
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + Self.webWallpaperReadyPollInterval) { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.schedulePendingWebWallpaperActivationIfReady(webView, startedAt: startedAt, isRecursiveProbe: true)
            }
        }
    }

    func finalizeLoadedWebWallpaperIfNeeded(_ webView: WKWebView) {
        guard webView === webWallpaperView else { return }
        noteWebWallpaperLoadFinished(for: webWallpaperProjectRoot)
        scheduleWallpaperEnginePropertyBridge(for: webView)
        scheduleWebAspectFitBridge(for: webView)
        scheduleWebLayoutRefreshNudge(for: webView)

        let probeJS = """
        (function () {
          try {
            var xhr = new XMLHttpRequest();
            xhr.open('GET', 'data.json', false);
            xhr.send(null);
            return JSON.stringify({
              artiaProbe: 'web-wallpaper',
              dataJson: { status: xhr.status, ok: xhr.status >= 200 && xhr.status < 300 }
            });
          } catch (e) {
            return JSON.stringify({
              artiaProbe: 'web-wallpaper',
              dataJson: { error: String(e) }
            });
          }
        })();
        """
        webView.evaluateJavaScript(probeJS) { [weak self] result, error in
            guard let self else { return }
            if let error {
                debugLog("[Web:\(self.displayID)] startup probe: \(error)")
                return
            }
            if let s = result as? String {
                artiaWebLog("[Web:\(self.displayID)] startup probe \(s)")
            } else {
                artiaWebLog("[Web:\(self.displayID)] startup probe result=\(String(describing: result))")
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak webView] in
            guard let self, let wv = webView, wv === self.webWallpaperView else { return }
            self.clearWKScrollChromeBackgrounds(in: wv)
        }

        let nudgePlaybackJS = """
        (function() {
          if (window.__artiaPlaybackRepairInstalled) return;
          window.__artiaPlaybackRepairInstalled = true;

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
            try {
              if (typeof window.applyBackground === 'function') window.applyBackground();
            } catch (_) {}
            try {
              if (typeof window.renderBgGrid === 'function') window.renderBgGrid();
            } catch (_) {}
          }

          function startPlayback() {
            try {
              if (typeof window.playSong === 'function') {
                window.playSong();
                return;
              }
            } catch (_) {}

            try {
              window.isPlaying = true;
            } catch (_) {}

            try {
              var btn = document.getElementById('btn-play');
              if (btn) {
                btn.innerHTML = '<i class="fas fa-pause"></i>';
              }
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
                result.then(function() {
                  restoreCurrentVisuals();
                  startPlayback();
                }).catch(function() {
                  restoreCurrentVisuals();
                  startPlayback();
                });
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

            var ready = Array.isArray(window.playlist) &&
              window.playlist.length > 0 &&
              typeof window.loadSong === 'function';
            if (ready) {
              reloadCurrentSongIfPossible();
              return;
            }
            if (attempt >= 18) {
              restoreCurrentVisuals();
              startPlayback();
              return;
            }
            setTimeout(function() { kick(attempt + 1); }, attempt < 6 ? 120 : 350);
          }

          kick(0);
        })();
        """
        webView.evaluateJavaScript(nudgePlaybackJS) { [weak self] _, error in
            guard let self else { return }
            if let error {
                debugLog("[Web:\(self.displayID)] playback nudge JS: \(error)")
            }
        }
    }

    func loadPreparedNonWebWallpaper(from url: URL) {
        hideWebWallpaperIfNeeded(preservingTransitionOverlay: true)
        clearWallpaperTransitionOverlay()
        // enableTransparentMode を直接呼ぶと backgroundTexture が即時にクリアされ、
        // 旧壁紙が一瞬透けて見えてからロードされる挙動になる。
        // loadBackground 側で keepTransparentUntilReady を立てるだけで十分。

        // Phase 3C: Application 壁紙 (.bundle / .app) を先に判定する。
        // .bundle → BundlePluginRuntime に mount。.app → 未対応説明ビューをホスト。
        // どちらも Renderer 経路には乗せず、関連する videoRuntime/host を解放する。
        if let appFormat = WallpaperItem.detectApplicationFormat(for: url) {
            unmountVideoRuntime()
            switch appFormat {
            case .bundle:
                if mountApplicationRuntime(bundleURL: url) {
                    return
                }
                // ロードに失敗した場合は通常壁紙経路へフォールバック (黒画面回避)。
                debugLog("[Instance:\(displayID)] Application (.bundle) の mount 失敗。通常壁紙へフォールバック: \(url.lastPathComponent)")
            case .appBlocked:
                mountApplicationUnsupportedNotice(for: url)
                return
            }
        } else {
            // Application 経路でない場合は前回の Application ホスト/ランタイムを解放する。
            unmountApplicationRuntime()
        }

        // Phase 3A: 新規動画形式 (webm/avi/wmv) は VideoWallpaperRuntime に振り分け、
        // 失敗時のみ既存 Renderer 経路へフォールバックして黒画面を回避する。
        let ext = url.pathExtension.lowercased()
        let newVideoExtensions: Set<String> = ["webm", "avi", "wmv"]
        if newVideoExtensions.contains(ext) {
            if mountVideoRuntime(url: url) {
                return
            }
            debugLog("[Instance:\(displayID)] 新規動画形式の起動に失敗したため通常壁紙へフォールバック: \(url.lastPathComponent)")
        } else {
            // 既存形式 (mp4/mov/m4v) の場合は Renderer の AVPlayer 経路をそのまま利用するため、
            // ここで残っている videoRuntime を解放する (壁紙切替時のリソースリーク対策)。
            unmountVideoRuntime()
        }
        renderer?.loadBackground(from: url, keepTransparentUntilReady: true)
    }

    /// VideoWallpaperRuntime を新規にマウントして再生を開始する。
    /// - Returns: 起動成功時 true。AVAsset が動画トラックを持たない / コーデック未対応の場合 false。
    /// - Why: AVURLAsset 解決でビデオトラックが取れないコンテナ (壊れた webm 等) を即座に検出し、
    ///        UX 配慮として通常壁紙へフォールバックできるよう Bool で返却する。
    @discardableResult
    func mountVideoRuntime(url: URL) -> Bool {
        unmountVideoRuntime()
        do {
            let runtime = try VideoWallpaperRuntime(url: url, metalDevice: metalView?.device)
            runtime.play()
            videoRuntime = runtime
            return true
        } catch {
            debugLog("[Instance:\(displayID)] VideoWallpaperRuntime 起動失敗: \(error.localizedDescription)")
            return false
        }
    }

    /// 既存の VideoWallpaperRuntime を解放する。
    func unmountVideoRuntime() {
        guard let runtime = videoRuntime else { return }
        runtime.pause()
        runtime.stop()
        videoRuntime = nil
    }

    func shouldSkipReloadForSameWebWallpaper(root: URL, now: Date = Date()) -> Bool {
        guard let requestedRoot = webWallpaperLastRequestedRoot,
              Self.isSameResolvedDirectory(requestedRoot, root) else {
            return false
        }

        let startAge = now.timeIntervalSince(webWallpaperLastLoadStartedAt ?? .distantPast)
        let finishAge = now.timeIntervalSince(webWallpaperLastLoadFinishedAt ?? .distantPast)
        return startAge < Self.sameWebWallpaperReloadCooldown
            || finishAge < Self.sameWebWallpaperReloadCooldown
    }

    func makeWebWallpaperConfiguration(for rootDirectory: URL) -> WKWebViewConfiguration {
        // Tier 1 サンドボックスを基盤にして組み立てる:
        // - websiteDataStore = .nonPersistent()
        // - 危険 API 無効化スクリプトを document-start で全フレーム注入
        // - 全外部 URL をブロックする WKContentRuleList を非同期登録
        //
        // 既存の artiaLog / artiaSettings ハンドラと imageProbe / visibility / playbackControl
        // などのポリフィル群はこの後で同じ ucc にぶら下げる。
        let config = WebWallpaperSandbox.makeSandboxedConfiguration(rootDirectory: rootDirectory)
        webSchemeHandler = nil

        // console / window.onerror をアプリ側に中継してデバッグ可能にする
        let ucc = config.userContentController
        let handler = WebLogHandler(displayID: displayID)
        ucc.add(handler, name: "artiaLog")
        webLogHandler = handler
        let isDisplaySynchronized = settings.isWebWallpaperDisplaySyncEnabled(for: rootDirectory)
        ucc.add(
            WebWallpaperSettingsHandler(
                rootDirectory: rootDirectory,
                displayID: displayID,
                isDisplaySynchronized: isDisplaySynchronized
            ),
            name: "artiaSettings"
        )

        // Phase 3B: Wallpaper Engine 互換 JS API (artiaWebBridge) の登録。
        // - bridge.js は document-start で全フレームへ注入し、`window.wallpaperRegister*` を生やす。
        // - native 受信ハンドラは User Properties の defaults を握ってから activate 時に webView を紐付ける。
        let initialUserProperties = WallpaperEngineWebUserProperties.defaultUserProperties(forProjectRoot: rootDirectory)
        let bridgeHandler = WebWallpaperBridgeHandler(initialUserProperties: initialUserProperties)
        ucc.add(bridgeHandler, name: WebWallpaperBridgeHandler.messageName)
        webBridgeHandler = bridgeHandler

        if let bridgeScript = Self.loadWallpaperBridgeScript() {
            ucc.addUserScript(WKUserScript(
                source: bridgeScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
        }

        // WE Web 壁紙の checkImageExists が new Image() + onload/onerror に依存するが、
        // WKWebView では相対パスの画像プローブでイベントが来ず initBackgrounds が await で固まる事例がある。
        // background/・thumb/ の URL だけ HEAD fetch で存在判定し、200 ならネイティブの src セッターで実体ロードまで走らせる。
        // 旧版は HEAD だけで onload を呼んでいたため `img.src` が空のままになり、CSS で `url(img.src)` を組み立てる壁紙が真っ黒になっていた。
        let imageProbePolyfillJS = """
        (function() {
          if (window.__artiaImageProbePolyfill) return;
          window.__artiaImageProbePolyfill = true;
          var NativeImage = window.Image;
          function shouldProbe(url) {
            return typeof url === 'string' && url.length > 0 &&
              (url.indexOf('background/') !== -1 || url.indexOf('thumb/') !== -1);
          }
          window.Image = function ArtiaImage(width, height) {
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
        ucc.addUserScript(WKUserScript(source: imageProbePolyfillJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        // デスクトップ奥の WKWebView では Page Visibility が hidden になり、音楽プレイヤーが再生しないことがある。
        let visibilityFixJS = """
        (function() {
          try {
            Object.defineProperty(document, 'hidden', { configurable: true, get: function() { return false; } });
          } catch (e) {}
          try {
            Object.defineProperty(document, 'visibilityState', { configurable: true, get: function() { return 'visible'; } });
          } catch (e2) {}
        })();
        """
        ucc.addUserScript(WKUserScript(source: visibilityFixJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let playbackControlJS = """
        (function() {
          if (window.__artiaPlaybackControl) return;

          var paused = false;
          var nextAnimationFrameID = 1;
          var nativeRequestAnimationFrame = typeof window.requestAnimationFrame === 'function'
            ? window.requestAnimationFrame.bind(window)
            : null;
          var nativeCancelAnimationFrame = typeof window.cancelAnimationFrame === 'function'
            ? window.cancelAnimationFrame.bind(window)
            : null;
          var activeAnimationFrames = new Map();
          var queuedAnimationFrames = new Map();

          function ensurePauseStyle() {
            if (document.getElementById('artia-playback-pause-style')) return;
            var style = document.createElement('style');
            style.id = 'artia-playback-pause-style';
            style.textContent = '[data-artia-paused="true"] *, [data-artia-paused="true"] *::before, [data-artia-paused="true"] *::after { animation-play-state: paused !important; }';
            (document.head || document.documentElement).appendChild(style);
          }

          function markRootPaused(nextPaused) {
            var root = document.documentElement;
            if (!root) return;
            if (nextPaused) {
              root.setAttribute('data-artia-paused', 'true');
            } else {
              root.removeAttribute('data-artia-paused');
            }
          }

          function cancelActiveAnimationFrames() {
            if (!nativeCancelAnimationFrame) return;
            activeAnimationFrames.forEach(function(nativeID, id) {
              if (nativeID != null) {
                try { nativeCancelAnimationFrame(nativeID); } catch (e) {}
                activeAnimationFrames.set(id, null);
              }
            });
          }

          function scheduleAnimationFrame(id, callback) {
            if (!nativeRequestAnimationFrame) return;
            var nativeID = nativeRequestAnimationFrame(function(timestamp) {
              if (!activeAnimationFrames.has(id)) return;
              activeAnimationFrames.delete(id);
              if (paused) {
                queuedAnimationFrames.set(id, callback);
                activeAnimationFrames.set(id, null);
                return;
              }
              try {
                callback(timestamp);
              } catch (error) {
                setTimeout(function() { throw error; }, 0);
              }
            });
            activeAnimationFrames.set(id, nativeID);
          }

          function flushQueuedAnimationFrames() {
            if (!nativeRequestAnimationFrame || queuedAnimationFrames.size === 0) return;
            var entries = Array.from(queuedAnimationFrames.entries());
            queuedAnimationFrames.clear();
            entries.forEach(function(entry) {
              var id = entry[0];
              var callback = entry[1];
              if (!activeAnimationFrames.has(id)) return;
              scheduleAnimationFrame(id, callback);
            });
          }

          function pauseMedia() {
            document.querySelectorAll('video, audio').forEach(function(el) {
              try {
                el.__artiaShouldResume = !el.paused;
                el.pause();
              } catch (e) {}
            });
          }

          function resumeMedia() {
            document.querySelectorAll('video, audio').forEach(function(el) {
              if (!el.__artiaShouldResume) return;
              el.__artiaShouldResume = false;
              try {
                var playPromise = el.play();
                if (playPromise && typeof playPromise.catch === 'function') {
                  playPromise.catch(function() {});
                }
              } catch (e) {}
            });
          }

          if (nativeRequestAnimationFrame && nativeCancelAnimationFrame) {
            window.requestAnimationFrame = function(callback) {
              if (typeof callback !== 'function') {
                return nativeRequestAnimationFrame(callback);
              }
              var id = nextAnimationFrameID++;
              if (paused) {
                queuedAnimationFrames.set(id, callback);
                activeAnimationFrames.set(id, null);
                return id;
              }
              scheduleAnimationFrame(id, callback);
              return id;
            };

            window.cancelAnimationFrame = function(id) {
              if (!activeAnimationFrames.has(id)) {
                try { nativeCancelAnimationFrame(id); } catch (e) {}
                return;
              }
              var nativeID = activeAnimationFrames.get(id);
              activeAnimationFrames.delete(id);
              queuedAnimationFrames.delete(id);
              if (nativeID != null) {
                try { nativeCancelAnimationFrame(nativeID); } catch (e) {}
              }
            };
          }

          window.__artiaPlaybackControl = {
            pause: function() {
              if (paused) return;
              paused = true;
              ensurePauseStyle();
              markRootPaused(true);
              cancelActiveAnimationFrames();
              pauseMedia();
              try { window.dispatchEvent(new Event('pause')); } catch (e) {}
              try { window.dispatchEvent(new Event('blur')); } catch (e) {}
              try { document.dispatchEvent(new Event('visibilitychange')); } catch (e) {}
            },
            resume: function() {
              if (!paused) return;
              paused = false;
              markRootPaused(false);
              flushQueuedAnimationFrames();
              resumeMedia();
              try { window.dispatchEvent(new Event('focus')); } catch (e) {}
              try { window.dispatchEvent(new Event('pageshow')); } catch (e) {}
              try { window.dispatchEvent(new Event('resume')); } catch (e) {}
              try { document.dispatchEvent(new Event('visibilitychange')); } catch (e) {}
            },
            isPaused: function() {
              return paused;
            }
          };
        })();
        """
        // b1f5a80 時点では playbackControlJS は無く、これが原因で playlist の初期化が阻害されている疑いがあるため一旦無効化。
        _ = playbackControlJS
        // ucc.addUserScript(WKUserScript(source: playbackControlJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let bridgeJS = """
        (function() {
          function safeStringify(x) {
            try {
              if (typeof x === 'string') return x;
              return JSON.stringify(x);
            } catch (e) {
              try { return String(x); } catch (_) { return '[unserializable]'; }
            }
          }
          function post(level, args) {
            try {
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.artiaLog) {
                window.webkit.messageHandlers.artiaLog.postMessage({
                  level: level,
                  message: args.map(safeStringify).join(' ')
                });
              }
            } catch (_) {}
          }
          ['log','info','warn','error'].forEach(function(level) {
            var orig = console[level];
            console[level] = function() {
              try { post(level, Array.prototype.slice.call(arguments)); } catch (_) {}
              if (orig) { try { orig.apply(console, arguments); } catch (_) {} }
            };
          });
          window.addEventListener('error', function(ev) {
            post('error', ['GLOBAL_ERROR:', ev.message, ev.filename + ':' + ev.lineno + ':' + ev.colno]);
          });
          window.addEventListener('unhandledrejection', function(ev) {
            post('error', ['UNHANDLED_REJECTION:', safeStringify(ev.reason)]);
          });
        })();
        """
        let userScript = WKUserScript(source: bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        ucc.addUserScript(userScript)

        let settingsBridgeJS = """
        (function() {
          if (window.artiaSettingsBridge) return;
          var pending = Object.create(null);
          function request(command, data) {
            return new Promise(function(resolve) {
              var callbackID = 'artia_' + Date.now() + '_' + Math.random().toString(36).slice(2);
              pending[callbackID] = resolve;
              try {
                window.webkit.messageHandlers.artiaSettings.postMessage({
                  command: command,
                  callbackID: callbackID,
                  data: data
                });
              } catch (error) {
                delete pending[callbackID];
                resolve({ ok: false, error: String(error) });
              }
            });
          }
          window.__artiaSettingsBridgeResolve = function(callbackID, payload) {
            var resolver = pending[callbackID];
            if (!resolver) return;
            delete pending[callbackID];
            resolver(payload);
          };
          window.artiaSettingsBridge = {
            read: function() { return request('read'); },
            write: function(data) { return request('write', data); },
            clear: function() { return request('clear'); }
          };
        })();
        """
        ucc.addUserScript(WKUserScript(source: settingsBridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        // WebKit: 負の z-index が body 背面に回り背景・動画レイヤーが消える事例への互換（WE Web 壁紙で多い）
        let stackFixJS = """
        (function() {
          var css = '#app-wrapper{isolation:isolate}.bg-layer,.bg-layer.active{z-index:0!important}.bg-overlay{z-index:1!important}#local-video-container{z-index:1!important}';
          var el = document.createElement('style');
          el.id = 'artia-webkit-stack-fix';
          el.textContent = css;
          (document.head || document.documentElement).appendChild(el);
        })();
        """
        ucc.addUserScript(WKUserScript(source: stackFixJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        config.userContentController = ucc

        return config
    }

    func configureWallpaperWebViewTransparency(_ wv: WKWebView) {
        wv.setValue(true, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            wv.underPageBackgroundColor = .black
        }
        clearWKScrollChromeBackgrounds(in: wv)
    }

    /// `Resources/WebWallpaper/wallpaper-bridge.js` を読み出して文字列で返す。
    /// Why: バンドルから JS を読み込み、document-start で WKUserScript として注入する。
    /// テストでも同じ JS を再利用するため static にしている。
    static func loadWallpaperBridgeScript() -> String? {
        let bundle = Bundle.main
        if let url = bundle.url(forResource: "wallpaper-bridge", withExtension: "js"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            return source
        }
        // テストターゲットや SPM 経由で main bundle に乗らない場合のフォールバック。
        let fallback = Bundle(for: WebLogHandler.self)
        if let url = fallback.url(forResource: "wallpaper-bridge", withExtension: "js"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            return source
        }
        return nil
    }

    func clearWKScrollChromeBackgrounds(in wv: WKWebView) {
        func walk(_ view: NSView) {
            for sub in view.subviews {
                // KVC の drawsBackground を全サブビューに当てると、WebKit 内部の WKFlippedView 等で
                // NSUnknownKeyException になる（macOS 26 以降で再現）。対応型だけ直に触る。
                if let clip = sub as? NSClipView {
                    clip.drawsBackground = false
                } else if let scroll = sub as? NSScrollView {
                    scroll.drawsBackground = false
                } else if let text = sub as? NSTextView {
                    text.drawsBackground = false
                }
                walk(sub)
            }
        }
        walk(wv)
    }

    func loadWebWallpaper(from directoryURL: URL) {
        // 音楽プレイヤー型 Workshop 壁紙は難読化 JS が WKWebView で動かないため、
        // Artia ネイティブの SwiftUI ビュー（MusicWallpaperView）で再生する。
        if MusicWallpaperDetector.isMusicWallpaper(rootURL: directoryURL) {
            loadMusicWallpaper(from: directoryURL)
            return
        }

        guard let resolved = WallpaperEngineWebResolver.resolve(rootDirectory: directoryURL) else {
            debugLog("[Instance:\(displayID)] Web 壁紙として解決できません: \(directoryURL.path)")
            artiaWebLog("[Instance:\(displayID)] Web resolve FAILED for \(directoryURL.path)")
            return
        }

        if isWebWallpaperActive,
           let activeRoot = webWallpaperProjectRoot,
           let activeEntry = webWallpaperEntryFileURL,
           let webWallpaperView,
           Self.isSameResolvedDirectory(activeRoot, resolved.rootDirectory),
           activeEntry.standardizedFileURL.path == resolved.entryFile.standardizedFileURL.path {
            debugLog("[Instance:\(displayID)] 同一 Web 壁紙を表示中のため再ロードを抑制")
            scheduleWallpaperEnginePropertyBridge(for: webWallpaperView)
            scheduleWebAspectFitBridge(for: webWallpaperView)
            scheduleWebLayoutRefreshNudge(for: webWallpaperView)
            return
        }

        let apply: () -> Void = { [weak self] in
            guard let self = self else { return }
            guard let root = self.wallpaperRootView, self.metalView != nil else {
                artiaWebLog("[Instance:\(self.displayID)] Web apply ABORT: wallpaperRootView or metalView nil")
                return
            }

            self.noteWebWallpaperLoadStarted(for: resolved.rootDirectory)
            self.stopPlaylist()
            self.webServer?.stop()
            self.webServer = nil
            self.discardPendingWebWallpaper()
            self.beginPendingWebWallpaperPresentation()

            let config = self.makeWebWallpaperConfiguration(for: resolved.rootDirectory)
            let wv = DroppableWKWebView(frame: root.bounds, configuration: config)
            wv.autoresizingMask = [.width, .height]
            self.configureWallpaperWebViewTransparency(wv)
            wv.onFilesDropped = { [weak self] urls in
                self?.handleDroppedFiles(urls)
            }
            wv.navigationDelegate = self
            wv.frame = root.bounds
            wv.isHidden = true
            // wallpaperTransitionOverlayView が nil のときは relativeTo: nil + .below で最背面行きになり、
            // MTKView（前の画像/動画レイヤ）の下に隠れてしまう。overlay があるときだけその真下に、
            // ない場合は最前面相当に貼る。
            if let overlay = self.wallpaperTransitionOverlayView {
                root.addSubview(wv, positioned: .below, relativeTo: overlay)
            } else {
                root.addSubview(wv, positioned: .above, relativeTo: nil)
            }
            self.pendingWebWallpaperView = wv
            self.pendingWebSchemeHandler = self.webSchemeHandler
            self.webSchemeHandler = nil
            self.pendingWebWallpaperProjectRoot = resolved.rootDirectory
            self.pendingWebWallpaperEntryFileURL = resolved.entryFile

            let relPath = self.relativePath(from: resolved.rootDirectory, to: resolved.entryFile)
            if let httpURL = self.startLocalHTTPAndMakeURL(for: resolved.rootDirectory, relativePath: relPath) {
                wv.load(URLRequest(url: httpURL))
                debugLog("[Instance:\(displayID)] Web 壁紙を LocalHTTP で読み込み: \(httpURL.absoluteString)")
                artiaWebLog("[Instance:\(displayID)] Web HTTP load url=\(httpURL.absoluteString) root=\(resolved.rootDirectory.path)")
            } else {
                debugLog("[Instance:\(displayID)] LocalHTTP URL 生成に失敗 → file:// にフォールバック")
                artiaWebLog("[Instance:\(displayID)] Web HTTP URL build FAILED → file:// fallback")
                wv.loadFileURL(resolved.entryFile, allowingReadAccessTo: resolved.rootDirectory)
            }
        }

        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    func activeWebWallpaperPageURL() -> URL? {
        guard isWebWallpaperActive,
              let root = webWallpaperProjectRoot,
              let entryFile = webWallpaperEntryFileURL else {
            return nil
        }

        let relPath = relativePath(from: root, to: entryFile)
        if let httpURL = startLocalHTTPAndMakeURL(for: root, relativePath: relPath) {
            return httpURL
        }
        return entryFile
    }

    func startLocalHTTPAndMakeURL(for root: URL, relativePath: String) -> URL? {
        if webServer == nil {
            do {
                let server = LocalHTTPFileServer(rootDirectory: root)
                try server.start()
                webServer = server
            } catch {
                debugLog("[Instance:\(displayID)] LocalHTTP 起動に失敗: \(error)")
                artiaWebLog("[Instance:\(displayID)] LocalHTTP start FAILED: \(String(describing: error))")
            }
        }

        guard let server = webServer else { return nil }
        if let httpURL = try? server.makeURL(path: relativePath) {
            return httpURL
        }

        debugLog("[Instance:\(displayID)] LocalHTTP URL 生成に失敗: \(relativePath)")
        artiaWebLog("[Instance:\(displayID)] LocalHTTP URL build FAILED path=\(relativePath)")
        return nil
    }

    func hideWebWallpaperIfNeeded(preservingTransitionOverlay: Bool = false) {
        discardPendingWebWallpaper()
        guard isWebWallpaperActive else { return }
        webWallpaperView?.stopLoading()
        webWallpaperView?.removeFromSuperview()
        webWallpaperView = nil
        // 音楽プレイヤー型壁紙の NSHostingView も併せて片付ける（画像/動画への戻り経路で残らないように）。
        removeMusicWallpaperHostView()
        isWebWallpaperActive = false
        isWebWallpaperPlaybackPaused = false
        webLogHandler = nil
        webBridgeHandler = nil
        webWallpaperProjectRoot = nil
        webWallpaperEntryFileURL = nil
        webSchemeHandler = nil
        resetWebWallpaperLoadTracking()
        webServer?.stop()
        webServer = nil
        metalView?.isHidden = false
        updateWindowPresentation()
        if !preservingTransitionOverlay {
            clearWallpaperTransitionOverlay()
        }
        if !userRequestedPause {
            if !isScreenCoveredByFullscreen {
                metalView?.isPaused = false
                renderer?.resumeVideo()
            } else {
                metalView?.isPaused = true
                renderer?.pauseVideo()
            }
        }
    }

    func setWebWallpaperScale(_ scale: Float) {
        let clamped = CGFloat(max(0.5, min(scale, 2.0)))
        currentWebWallpaperScale = clamped
        if let webView = webWallpaperView {
            scheduleWebAspectFitBridge(for: webView)
        }
    }

    func reloadCurrentWebWallpaperIfMatches(rootDirectory: URL) {
        let resolved = WallpaperEngineWebResolver.canonicalFilesystemURL(matching: rootDirectory) ?? rootDirectory.standardizedFileURL

        if let currentRoot = webWallpaperProjectRoot,
           Self.isSameResolvedDirectory(currentRoot, resolved) {
            webWallpaperLastRequestedRoot = nil
            webWallpaperLastLoadStartedAt = nil
            webWallpaperLastLoadFinishedAt = nil
            loadWebWallpaper(from: resolved)
            return
        }

        if let pendingRoot = pendingWebWallpaperProjectRoot,
           Self.isSameResolvedDirectory(pendingRoot, resolved) {
            webWallpaperLastRequestedRoot = nil
            webWallpaperLastLoadStartedAt = nil
            webWallpaperLastLoadFinishedAt = nil
            loadWebWallpaper(from: resolved)
        }
    }

    func relativePath(from root: URL, to file: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        if filePath == rootPath { return "/" }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if filePath.hasPrefix(prefix) {
            let rel = String(filePath.dropFirst(prefix.count))
            return "/" + rel
        }
        return "/" + file.lastPathComponent
    }

    /// Wallpaper Engine 互換: ホストが初回に送る `applyUserProperties` / `applyGeneralProperties` を `project.json` から再現する。
    /// 未送信だと、リスナー内でしか初期化しない Web 壁紙ではメディア・コントロールが動かないことがある。
    func scheduleWallpaperEnginePropertyBridge(for webView: WKWebView) {
        guard let root = webWallpaperProjectRoot else { return }
        let user = WallpaperEngineWebUserProperties.defaultUserProperties(forProjectRoot: root)
        // b1f5a80 版の `WallpaperEngineWebUserProperties` には fps 引数がない。当時のシグネチャに合わせて固定。
        let general = WallpaperEngineWebUserProperties.defaultGeneralProperties()
        guard let js = WallpaperEngineWebUserProperties.propertyBridgeJavaScript(userProperties: user, generalProperties: general) else {
            artiaWebLog("[Web:\(displayID)] WE bridge skipped (JSON build failed)")
            return
        }
        webView.evaluateJavaScript(js) { [weak self] _, err in
            guard let self, let err else { return }
            debugLog("[Web:\(self.displayID)] WE bridge eval: \(err)")
        }
        // 遅延読み込みスクリプト用。巨大 JS のパース後にリスナーが付く壁紙向けに複数回だけ再注入（成功済みなら bridge 内で即 return）
        for delay in [1.5, 4.0, 8.0] as [TimeInterval] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                guard let self, let wv = webView, wv === self.webWallpaperView else { return }
                wv.evaluateJavaScript(js) { _, err in
                    if let err {
                        debugLog("[Web:\(self.displayID)] WE bridge retry eval (+\(delay)s): \(err)")
                    }
                }
            }
        }
        artiaWebLog("[Web:\(displayID)] WE bridge injected fps=\(currentWebWallpaperFPS) userKeys=\(user.keys.sorted().joined(separator: ","))")
    }

    /// 一部の Web 壁紙は保存済み UI 値を表示していても、初回ロード時の再レイアウトが走らず
    /// 手動で値を変えるまで古い位置のままになる。主要イベントを数回だけ再送して初期配置を安定させる。
    func scheduleWebLayoutRefreshNudge(for webView: WKWebView) {
        let js = #"""
        (function() {
          try { window.dispatchEvent(new Event('resize')); } catch (e) {}
          try { window.dispatchEvent(new Event('orientationchange')); } catch (e) {}
          try { window.dispatchEvent(new Event('pageshow')); } catch (e) {}
          try { document.dispatchEvent(new Event('visibilitychange')); } catch (e) {}
        })();
        """#

        for delay in [0.05, 0.2, 0.6, 1.2] as [TimeInterval] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                guard let self, let wv = webView, wv === self.webWallpaperView else { return }
                wv.evaluateJavaScript(js) { _, error in
                    if let error {
                        debugLog("[Web:\(self.displayID)] layout refresh nudge (+\(delay)s): \(error)")
                    }
                }
            }
        }
    }
}
