import Cocoa
import MetalKit
import SwiftUI
import WebKit

// MARK: - DisplayWallpaperInstance + WKNavigationDelegate
// Why: WKNavigationDelegate 実装をまとめ、Web 壁紙の遷移結果を扱う。

extension DisplayWallpaperInstance: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if webView === pendingWebWallpaperView {
            activatePendingWebWallpaperIfNeeded(webView)
            finalizeLoadedWebWallpaperIfNeeded(webView)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        debugLog("[Web:\(displayID)] didFail navigation: \(error)")
        artiaWebLog("[Web:\(displayID)] didFail url=\(webView.url?.absoluteString ?? "?") code=\(ns.code) \(error.localizedDescription)")
        if webView === pendingWebWallpaperView {
            discardPendingWebWallpaper()
            clearWallpaperTransitionOverlay()
        }
        if webView === webWallpaperView {
            noteWebWallpaperLoadFinished(for: webWallpaperProjectRoot)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        debugLog("[Web:\(displayID)] didFailProvisionalNavigation: \(error)")
        artiaWebLog("[Web:\(displayID)] didFailProvisional url=\(webView.url?.absoluteString ?? "?") code=\(ns.code) domain=\(ns.domain) \(error.localizedDescription)")
        if webView === pendingWebWallpaperView {
            discardPendingWebWallpaper()
            clearWallpaperTransitionOverlay()
        }
        if webView === webWallpaperView {
            noteWebWallpaperLoadFinished(for: webWallpaperProjectRoot)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        debugLog("[Web:\(displayID)] didFinish")
        artiaWebLog("[Web:\(displayID)] didFinish url=\(webView.url?.absoluteString ?? "?")")
        if webView === pendingWebWallpaperView {
            schedulePendingWebWallpaperActivationIfReady(webView)
            return
        }
        if webView === webWallpaperView {
            finalizeLoadedWebWallpaperIfNeeded(webView)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if isSystemSuspended || isDetachedFromDisplay {
            artiaWebLog("[Web:\(displayID)] WebContent process terminated while suspended/detached → defer reload")
            return
        }

        let now = Date()
        if let windowStarted = webContentTerminationWindowStartedAt,
           now.timeIntervalSince(windowStarted) <= Self.webContentTerminationReloadWindow {
            webContentTerminationReloadCount += 1
        } else {
            webContentTerminationWindowStartedAt = now
            webContentTerminationReloadCount = 1
        }

        guard webContentTerminationReloadCount <= Self.maxWebContentTerminationReloads else {
            artiaWebLog("[Web:\(displayID)] WebContent process terminated repeatedly → auto reload stopped")
            return
        }

        artiaWebLog("[Web:\(displayID)] WebContent process terminated → recreate WebView")
        if webView === webWallpaperView, let root = webWallpaperProjectRoot {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !self.isSystemSuspended, !self.isDetachedFromDisplay else { return }
                self.loadWebWallpaper(from: root)
            }
        } else {
            webView.reload()
        }
    }
}
