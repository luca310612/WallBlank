import Cocoa
import MetalKit
import SwiftUI
import WebKit

// MARK: - DisplayWallpaperInstance + Playback
// Why: 再生/一時停止と強制リドローのロジックを集約。

extension DisplayWallpaperInstance {

    func setWebWallpaperPlaybackPaused(_ paused: Bool, reason: String, force: Bool = false) {
        guard isWebWallpaperActive, let webView = webWallpaperView else { return }
        guard force || isWebWallpaperPlaybackPaused != paused else { return }

        isWebWallpaperPlaybackPaused = paused
        let script = paused
            ? "window.__artiaPlaybackControl && window.__artiaPlaybackControl.pause && window.__artiaPlaybackControl.pause();"
            : "window.__artiaPlaybackControl && window.__artiaPlaybackControl.resume && window.__artiaPlaybackControl.resume();"
        webView.evaluateJavaScript(script, completionHandler: nil)
        debugLog("[Instance:\(displayID)] Web playback \(paused ? "paused" : "resumed"): \(reason)")
    }

    func syncWebWallpaperPlaybackState(reason: String, force: Bool = false) {
        setWebWallpaperPlaybackPaused(shouldPauseWebWallpaperPlayback, reason: reason, force: force)
    }

    func pause() {
        userRequestedPause = true
        metalView?.isPaused = true
        renderer?.pauseVideo()
        videoRuntime?.pause()
        setWebWallpaperPlaybackPaused(true, reason: "userPause", force: true)
    }

    func resume() {
        userRequestedPause = false
        syncWebWallpaperPlaybackState(reason: "userResume", force: true)
        // Web 壁紙表示中は Metal を再開しない（背面で描画を走らせない）
        guard !isWebWallpaperActive else { return }
        // フルスクリーンでカバーされていない場合のみ再生
        if !isScreenCoveredByFullscreen {
            metalView?.isPaused = false
            renderer?.resumeVideo()
            videoRuntime?.play()
        }
    }

    func pauseInternal() {
        metalView?.isPaused = true
        renderer?.pauseVideo()
        videoRuntime?.pause()
        setWebWallpaperPlaybackPaused(true, reason: "pauseInternal")
    }

    func resumeInternal() {
        // ユーザーが一時停止を要求していない場合のみ再生
        if !userRequestedPause, !isWebWallpaperActive {
            metalView?.isPaused = false
            renderer?.resumeVideo()
            videoRuntime?.play()
        }
        syncWebWallpaperPlaybackState(reason: "resumeInternal")
    }

    func forceRedraw() {
        guard !isDestroyed else { return }

        if isWebWallpaperActive {
            resumeCachedWebWallpaperIfNeeded(reason: "forceRedraw")
            return
        }

        // ユーザーが一時停止していない場合のみ再開
        if !userRequestedPause {
            metalView?.isPaused = false
            renderer?.resumeVideo()
        }

        // 復帰直後は Metal の状態が不安定なことがあるため、レンダラー側の描画コンテキストも再初期化する
        renderer?.reinitializeRenderContext(reason: "forceRedraw")

        // Rendererに再描画を要求
        renderer?.markDirty()
        metalView?.setNeedsDisplay(metalView?.bounds ?? .zero)
        metalView?.draw()

        debugLog("[Instance:\(displayID)] 強制再描画実行")
    }
}
