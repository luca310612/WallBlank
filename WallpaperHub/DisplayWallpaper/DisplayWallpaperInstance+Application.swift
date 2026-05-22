import AppKit
import SwiftUI

// MARK: - DisplayWallpaperInstance + Application (Phase 3C)
// Why: Application 壁紙 (.bundle / .app) の mount / unmount / 未対応 UI を集約する。
//      VideoWallpaperRuntime と同列のレイヤーで NSWindow.level を desktopIcon の裏に配置する。

extension DisplayWallpaperInstance {

    // MARK: - Mount

    /// 内製 .bundle プラグインを Application 壁紙としてマウントする。
    /// - Parameter url: 対象の .bundle URL。
    /// - Returns: 起動成功時 true。BundlePluginRuntime のロード失敗時は false。
    /// - Note: .app の場合は別途 `mountApplicationUnsupportedNotice(for:)` を呼ぶこと。
    @discardableResult
    func mountApplicationRuntime(bundleURL: URL) -> Bool {
        unmountApplicationRuntime()

        guard let root = wallpaperRootView else {
            debugLog("[Instance:\(displayID)] Application 壁紙: wallpaperRootView 未生成のため mount 不可")
            return false
        }

        let runtime = BundlePluginRuntime()
        do {
            try runtime.load(bundleURL: bundleURL)
        } catch {
            debugLog("[Instance:\(displayID)] BundlePluginRuntime ロード失敗: \(error.localizedDescription)")
            return false
        }

        guard let vc = runtime.viewController() else {
            debugLog("[Instance:\(displayID)] BundlePluginRuntime から NSViewController を取得できませんでした")
            return false
        }

        // ホストビューを root のサイズで作り、その中に viewController.view を全面配置する。
        let host = NSView(frame: root.bounds)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true

        vc.view.frame = host.bounds
        vc.view.autoresizingMask = [.width, .height]
        host.addSubview(vc.view)

        if let overlay = wallpaperTransitionOverlayView {
            root.addSubview(host, positioned: .below, relativeTo: overlay)
        } else {
            root.addSubview(host, positioned: .above, relativeTo: nil)
        }

        applicationRuntime = runtime
        applicationHostView = host
        isApplicationWallpaperActive = true
        // Window level を desktopIcon の裏 (-1) に揃え、デスクトップアイコンが Application 壁紙の上に出るようにする。
        updateWindowPresentation()
        debugLog("[Instance:\(displayID)] Application 壁紙 mount: \(bundleURL.lastPathComponent)")
        return true
    }

    /// `.app` ドロップ時に表示する未対応説明ビューをホストする。
    /// Why: macOS では任意 .app をデスクトップウィンドウ層へ固定する API が無いため、
    ///      壁紙領域に明示的に "未対応" を表示し、誤魔化さずユーザーに案内する。
    func mountApplicationUnsupportedNotice(for appURL: URL) {
        unmountApplicationRuntime()

        guard let root = wallpaperRootView else { return }

        let host = NSView(frame: root.bounds)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor

        let hosting = NSHostingView(rootView: ApplicationUnsupportedView(droppedAppURL: appURL))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            hosting.centerYAnchor.constraint(equalTo: host.centerYAnchor)
        ])

        if let overlay = wallpaperTransitionOverlayView {
            root.addSubview(host, positioned: .below, relativeTo: overlay)
        } else {
            root.addSubview(host, positioned: .above, relativeTo: nil)
        }

        applicationHostView = host
        isApplicationWallpaperActive = true
        updateWindowPresentation()
        debugLog("[Instance:\(displayID)] Application 壁紙 (.app 未対応) を表示: \(appURL.lastPathComponent)")
    }

    /// Application 壁紙のホストビューとランタイムを解放する。
    /// - Note: BundlePluginRuntime.unload() は NSViewController.view を superview から外し、参照を nil 化する。
    func unmountApplicationRuntime() {
        applicationRuntime?.unload()
        applicationRuntime = nil
        applicationHostView?.removeFromSuperview()
        applicationHostView = nil
        applicationUnsupportedHostView?.removeFromSuperview()
        applicationUnsupportedHostView = nil
        if isApplicationWallpaperActive {
            isApplicationWallpaperActive = false
            updateWindowPresentation()
        }
    }
}
