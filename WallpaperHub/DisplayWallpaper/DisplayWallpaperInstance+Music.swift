import Cocoa
import MetalKit
import SwiftUI
import WebKit

// MARK: - DisplayWallpaperInstance + Music
// Why: 音楽プレイヤー型壁紙の起動と後始末を集約。

extension DisplayWallpaperInstance {

    func loadMusicWallpaper(from directoryURL: URL) {
        let apply: () -> Void = { [weak self] in
            guard let self = self else { return }
            guard let root = self.wallpaperRootView else {
                artiaWebLog("[Instance:\(self.displayID)] Music apply ABORT: wallpaperRootView nil")
                return
            }

            // 同じルートで既に表示中なら再生成しない
            if self.musicWallpaperActiveRoot?.standardizedFileURL.path == directoryURL.standardizedFileURL.path,
               self.musicWallpaperHostView != nil {
                debugLog("[Instance:\(self.displayID)] 同一の音楽プレイヤー型壁紙を表示中のため再ロードを抑制")
                return
            }

            // 既存の Web/音楽壁紙を片付ける
            self.stopPlaylist()
            self.webServer?.stop()
            self.webServer = nil
            self.discardPendingWebWallpaper()
            self.removeMusicWallpaperHostView()
            // 既存の WKWebView 壁紙も片付ける（音楽型は WKWebView を使わない）
            self.webWallpaperView?.stopLoading()
            self.webWallpaperView?.removeFromSuperview()
            self.webWallpaperView = nil

            // Player を外側で先に生成し、HostView 取り外し時に確実に音/MV を停止できるよう保持しておく。
            // `MusicWallpaperPlayer` は @MainActor 隔離だが、この apply ブロックは常に main thread で実行される。
            guard let manifest = MusicWallpaperDetector.loadManifest(rootURL: directoryURL) else {
                artiaWebLog("[Instance:\(self.displayID)] MusicWallpaperView の生成に失敗: \(directoryURL.path)")
                return
            }
            let player = MainActor.assumeIsolated { MusicWallpaperPlayer(manifest: manifest) }
            let view = MusicWallpaperView(rootURL: directoryURL, player: player)

            let host = NSHostingView(rootView: view)
            host.frame = root.bounds
            host.autoresizingMask = [.width, .height]
            // wallpaperTransitionOverlayView が無いときは relativeTo: nil + .below で最背面行きになり、
            // MTKView（前の画像/動画レイヤ）の下に隠れてしまう。常に最前面相当に貼ってから、
            // 必要なら trans overlay の下に並べ替える。
            if let overlay = self.wallpaperTransitionOverlayView {
                root.addSubview(host, positioned: .below, relativeTo: overlay)
            } else {
                root.addSubview(host, positioned: .above, relativeTo: nil)
            }
            // 既存の MTKView（画像/動画レイヤ）を隠して音楽壁紙だけが見える状態にする。
            self.metalView?.isHidden = true
            self.metalView?.isPaused = true

            self.musicWallpaperHostView = host
            self.musicWallpaperActiveRoot = directoryURL
            self.musicWallpaperActivePlayer = player
            self.webWallpaperProjectRoot = directoryURL
            self.webWallpaperEntryFileURL = nil
            self.isWebWallpaperActive = true
            self.isWebWallpaperPendingActivation = false
            // Web/音楽壁紙へ切り替わった直後にウィンドウのマウスイベント受付を有効化する。
            self.updateWindowPresentation()

            artiaWebLog("[Instance:\(self.displayID)] Music wallpaper started root=\(directoryURL.path)")
        }

        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    func removeMusicWallpaperHostView() {
        // 取り外し前に音楽/MV を停止して、クライアント表示に戻ったあとに音が残らないようにする。
        // MusicWallpaperPlayer は @MainActor 隔離だが、本メソッドは main thread からのみ呼ばれる。
        if let player = musicWallpaperActivePlayer {
            MainActor.assumeIsolated { player.stop() }
        }
        musicWallpaperActivePlayer = nil
        musicWallpaperHostView?.removeFromSuperview()
        musicWallpaperHostView = nil
        musicWallpaperActiveRoot = nil
    }
}
