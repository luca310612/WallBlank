import Cocoa
import MetalKit
import SwiftUI
import WebKit

// MARK: - DisplayWallpaperInstance + Lifecycle
// Why: スリープ/再アタッチ/破棄など生死管理を集約。

extension DisplayWallpaperInstance {

    func suspendForSystemEvent(reason: String) {
        guard !isDestroyed else { return }
        isSystemSuspended = true
        renderer?.pauseVideo()
        videoRuntime?.pause()
        metalView?.isPaused = true

        guard isWebWallpaperActive else { return }
        setWebWallpaperPlaybackPaused(true, reason: reason, force: true)
        debugLog("[Instance:\(displayID)] Web 壁紙をキャッシュ保持したまま停止: \(reason)")
    }

    func resumeFromSystemEvent(reason: String) {
        guard !isDestroyed else { return }
        isSystemSuspended = false
        guard !isDetachedFromDisplay else { return }

        if isWebWallpaperActive {
            resumeCachedWebWallpaperIfNeeded(reason: reason)
            return
        }

        if !userRequestedPause, !isScreenCoveredByFullscreen {
            metalView?.isPaused = false
            renderer?.resumeVideo()
            videoRuntime?.play()
        }
        renderer?.reinitializeRenderContext(reason: "resumeFromSystemEvent")
        renderer?.markDirty()
        metalView?.setNeedsDisplay(metalView?.bounds ?? .zero)
    }

    func detachForDisplaySleepOrRemoval(reason: String) {
        guard !isDestroyed else { return }
        isDetachedFromDisplay = true
        suspendForSystemEvent(reason: reason)
        window?.orderOut(nil)
        debugLog("[Instance:\(displayID)] ディスプレイ切断キャッシュへ退避: \(reason)")
    }

    func reattach(to newScreen: NSScreen, reason: String) {
        guard !isDestroyed else { return }
        screen = newScreen
        isDetachedFromDisplay = false
        updateWindowPresentation()
        updateFrame(for: newScreen)
        resumeFromSystemEvent(reason: reason)
        debugLog("[Instance:\(displayID)] キャッシュ済み壁紙インスタンスを再接続: \(reason)")
    }

    func resumeCachedWebWallpaperIfNeeded(reason: String) {
        guard isWebWallpaperActive, let webView = webWallpaperView else { return }
        updateWindowPresentation()
        webView.isHidden = false
        scheduleWallpaperEnginePropertyBridge(for: webView)
        scheduleWebAspectFitBridge(for: webView)
        scheduleWebLayoutRefreshNudge(for: webView)
        syncWebWallpaperPlaybackState(reason: reason, force: true)
        debugLog("[Instance:\(displayID)] Web 壁紙キャッシュ状態を同期: \(reason)")
    }

    func destroy() {
        // 二重解放防止
        guard !isDestroyed else {
            return
        }
        isDestroyed = true

        let cleanup = { [weak self] in
            guard let self = self else { return }

            // フルスクリーン監視を解除
            self.fullscreenCheckTimer?.invalidate()
            self.fullscreenCheckTimer = nil
            if let observer = self.appActivationObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
                self.appActivationObserver = nil
            }

            // プレイリストを停止
            self.stopPlaylist()

            // Phase 3A: VideoWallpaperRuntime を解放（CVDisplayLink / AssetReader を停止）
            self.unmountVideoRuntime()

            // Rendererを先に無効化して描画を停止
            self.renderer?.invalidate()

            self.webWallpaperView?.stopLoading()
            self.webWallpaperView?.removeFromSuperview()
            self.webWallpaperView = nil
            self.discardPendingWebWallpaper()
            self.isWebWallpaperActive = false
            self.webServer?.stop()
            self.webServer = nil
            self.webWallpaperProjectRoot = nil
            self.webWallpaperEntryFileURL = nil
            self.webSchemeHandler = nil
            self.resetWebWallpaperLoadTracking()
            self.menuBarBlendView?.removeFromSuperview()
            self.menuBarBlendView = nil
            self.clearWallpaperTransitionOverlay()

            // MTKViewの描画を停止してデリゲートを解除
            self.metalView?.isPaused = true
            self.metalView?.delegate = nil

            // ウィンドウを閉じる
            self.window?.orderOut(nil)

            // 参照をクリア
            self.window = nil
            self.wallpaperRootView = nil
            self.metalView = nil
            self.renderer = nil

            debugLog("[Instance:\(self.displayID)] Destroyed")
        }

        // デッドロック防止: asyncを使用
        if Thread.isMainThread {
            cleanup()
        } else {
            DispatchQueue.main.async {
                cleanup()
            }
        }
    }
}
