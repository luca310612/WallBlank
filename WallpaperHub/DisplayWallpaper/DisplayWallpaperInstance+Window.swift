import Cocoa
import MetalKit
import SwiftUI
import WebKit

// MARK: - DisplayWallpaperInstance + Window
// Why: ウィンドウ・フレーム・トランジションオーバーレイなど見た目周りを集約。

extension DisplayWallpaperInstance {

    func setupWindow() {
        debugLog("[Instance:\(displayID)] Setting up window: \(Int(screen.frame.width))x\(Int(screen.frame.height))")

        guard let device = MTLCreateSystemDefaultDevice() else {
            debugLog("[Instance:\(displayID)] Metal is not supported")
            return
        }

        // 初期状態は非 Web 壁紙として扱う
        let padding = currentWindowPadding()
        let fullScreenRect = expandedFrame(for: screen, padding: padding)

        let newWindow = WallpaperHostWindow(
            contentRect: fullScreenRect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        newWindow.setFrame(fullScreenRect, display: false)
        newWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        newWindow.isOpaque = false
        newWindow.hasShadow = false
        newWindow.backgroundColor = .clear
        // ON のときは Finder 側へイベントを素通しし、デスクトップ項目をクリック可能にする。
        newWindow.ignoresMouseEvents = settings.desktopItemsClickable
        newWindow.acceptsMouseMovedEvents = true

        let container = NSView(frame: NSRect(origin: .zero, size: fullScreenRect.size))
        container.autoresizingMask = [.width, .height]

        let root = NSView(frame: wallpaperContentFrame(for: screen, padding: padding))
        root.autoresizingMask = []

        let view = DroppableMTKView(frame: root.bounds, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = displayRefreshRate()
        view.autoresizingMask = [.width, .height]
        // 壁紙は常時更新（アニメ/GIF/動画やエフェクトが止まらないようにする）
        view.enableSetNeedsDisplay = false
        view.isPaused = false

        // 透過描画を有効にする（壁紙未設定時にmacOSデスクトップを表示するため）
        view.layer?.isOpaque = false

        guard let newRenderer = Renderer(metalView: view) else {
            debugLog("[Instance:\(displayID)] Failed to create renderer")
            return
        }

        view.delegate = newRenderer

        // ドラッグ＆ドロップのコールバックを設定
        view.onFilesDropped = { [weak self] urls in
            self?.handleDroppedFiles(urls)
        }

        root.addSubview(view)
        container.addSubview(root)
        newWindow.contentView = container

        self.window = newWindow
        self.wallpaperRootView = root
        self.metalView = view
        self.renderer = newRenderer
        refreshDisplayArrangement()
        newRenderer.onVideoFirstFrameReady = { [weak self] in
            self?.completePendingWallpaperTransition()
        }
        newRenderer.onVideoLoadFailed = { [weak self] reason in
            self?.cancelPendingWallpaperTransition(reason: reason)
        }
        newRenderer.onBackgroundReady = { [weak self] in
            self?.completePendingWallpaperTransition()
        }
        newRenderer.onBackgroundLoadFailed = { [weak self] reason in
            self?.cancelPendingWallpaperTransition(reason: reason)
        }
        updateWindowPresentation()
        syncDrawableSizeToWindow()

        debugLog("[Instance:\(displayID)] Wallpaper window displayed (drag & drop enabled)")
    }

    func syncDrawableSizeToWindow() {
        guard let view = metalView else { return }

        let backingBounds = view.convertToBacking(view.bounds)
        let baseWidth = max(backingBounds.width, 1)
        let baseHeight = max(backingBounds.height, 1)
        let scaledWidth = max(baseWidth * CGFloat(currentResolutionScale), 1)
        let scaledHeight = max(baseHeight * CGFloat(currentResolutionScale), 1)
        view.drawableSize = CGSize(width: scaledWidth, height: scaledHeight)
    }

    func currentWindowPadding() -> CGFloat {
        shouldPresentWebWallpaper ? overlayPadding : 0
    }

    func updateWindowPresentation() {
        guard let window else { return }
        guard !isDetachedFromDisplay else {
            window.orderOut(nil)
            return
        }

        let padding = currentWindowPadding()
        let frame = expandedFrame(for: screen, padding: padding)
        window.setFrame(frame, display: true)
        window.contentView?.frame = NSRect(origin: .zero, size: frame.size)
        wallpaperRootView?.frame = wallpaperContentFrame(for: screen, padding: padding)

        if shouldPresentWebWallpaper {
            if menuBarBlendView == nil, let root = wallpaperRootView {
                installMenuBarBlendOverlay(in: root)
            }
            menuBarBlendView?.isHidden = false
            // Web/音楽プレイヤー型壁紙のクリック取得を優先するため、
            // デスクトップアイコン層のさらに上 (+3) に押し上げて他レイヤより確実に前面へ置く。
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 3)
            // Web/音楽プレイヤー型壁紙はクリック・操作を受け付ける必要があるため、
            // desktopItemsClickable 設定に関わらず常にマウスイベントを受け取る。
            window.ignoresMouseEvents = false
            window.orderFrontRegardless()
        } else {
            menuBarBlendView?.isHidden = true
            // Keep image/video wallpapers above the system desktop picture while staying below
            // Finder's desktop icons. Ordering at the raw desktop level can place the window
            // behind macOS' own wallpaper surface, making a successfully loaded wallpaper invisible.
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            // 画像/動画/GIF などの通常壁紙は、ユーザー設定どおり Finder のデスクトップ項目クリック透過を尊重する。
            window.ignoresMouseEvents = settings.desktopItemsClickable
            window.orderFrontRegardless()
        }
    }

    func installMenuBarBlendOverlay(in root: NSView) {
        // 既にあれば何もしない
        if menuBarBlendView != nil { return }
        // メニューバーはメイン画面のみ。サブディスプレイ上部に帯を出さない
        guard screen == NSScreen.main else { return }

        let v = ClickThroughVisualEffectView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.blendingMode = .withinWindow
        v.state = .active
        // メニューバーの雰囲気に近い素材（OSが変わってもそれなりに馴染む）
        v.material = .menu
        v.wantsLayer = true

        // 下方向にフェードアウトさせて境界を自然にする
        let mask = CAGradientLayer()
        mask.colors = [NSColor.black.cgColor, NSColor.black.withAlphaComponent(0).cgColor]
        mask.locations = [0.0, 1.0]
        mask.startPoint = CGPoint(x: 0.5, y: 1.0)
        mask.endPoint = CGPoint(x: 0.5, y: 0.0)
        v.layer?.mask = mask

        root.addSubview(v, positioned: .above, relativeTo: nil)

        let height: CGFloat = NSStatusBar.system.thickness + 40
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            v.topAnchor.constraint(equalTo: root.topAnchor),
            v.heightAnchor.constraint(equalToConstant: height)
        ])

        // maskのフレームは layout 後に追従させる
        DispatchQueue.main.async {
            mask.frame = v.bounds
        }

        menuBarBlendView = v
    }

    func menuBarFrameExtension(for screen: NSScreen) -> CGFloat {
        guard screen == NSScreen.main else { return 0 }
        return NSStatusBar.system.thickness + 36
    }

    func expandedFrame(for screen: NSScreen, padding: CGFloat) -> NSRect {
        let extraTop = menuBarFrameExtension(for: screen)
        return NSRect(
            x: screen.frame.origin.x - padding,
            y: screen.frame.origin.y - padding,
            width: screen.frame.width + padding * 2,
            height: screen.frame.height + padding * 2 + extraTop
        )
    }

    func wallpaperContentFrame(for screen: NSScreen, padding: CGFloat) -> NSRect {
        NSRect(
            x: padding,
            y: padding,
            width: screen.frame.width,
            height: screen.frame.height
        )
    }

    func installWallpaperTransitionOverlayIfNeeded() {
        guard wallpaperTransitionOverlayView == nil,
              let root = wallpaperRootView,
              let snapshot = snapshotImage(of: root) else {
            return
        }

        let overlay = ClickThroughImageView(frame: root.bounds)
        overlay.image = snapshot
        overlay.imageScaling = .scaleAxesIndependently
        overlay.autoresizingMask = [.width, .height]
        root.addSubview(overlay, positioned: .above, relativeTo: nil)
        wallpaperTransitionOverlayView = overlay
    }

    func clearWallpaperTransitionOverlay() {
        wallpaperTransitionOverlayView?.removeFromSuperview()
        wallpaperTransitionOverlayView = nil
    }

    func snapshotImage(of view: NSView) -> NSImage? {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    func completePendingWallpaperTransition() {
        clearWallpaperTransitionOverlay()
    }

    func cancelPendingWallpaperTransition(reason: String) {
        debugLog("[Instance:\(displayID)] 壁紙のロードに失敗: \(reason)")
        clearWallpaperTransitionOverlay()
    }

    func updateFrame(for newScreen: NSScreen) {
        self.screen = newScreen

        let padding = currentWindowPadding()
        let newFrame = expandedFrame(for: newScreen, padding: padding)
        window?.setFrame(newFrame, display: true)
        window?.contentView?.frame = NSRect(origin: .zero, size: newFrame.size)
        wallpaperRootView?.frame = wallpaperContentFrame(for: newScreen, padding: padding)
        syncDrawableSizeToWindow()
        refreshDisplayArrangement()
        if let webView = webWallpaperView {
            scheduleWebAspectFitBridge(for: webView)
        }
        // メニューバー用マスクを追従
        if let mask = menuBarBlendView?.layer?.mask as? CAGradientLayer,
           let v = menuBarBlendView {
            mask.frame = v.bounds
        }

        debugLog("[Instance:\(displayID)] Frame updated: \(Int(newScreen.frame.width))x\(Int(newScreen.frame.height))")
    }

    func refreshDisplayArrangement() {
        guard let renderer else { return }

        let spanEnabled = settings.spanWallpaperAcrossDisplays
        let savedArrangement = settings.displayArrangement
        let enabledIDs = Set(settings.enabledDisplayIDs)
        let activeIDs = enabledIDs.isEmpty ? Set([displayID]) : enabledIDs

        var displayRects: [CGRect] = []
        for id in activeIDs {
            if let layout = savedArrangement[id] {
                displayRects.append(layout.rect)
            } else if let screen = displays.screen(for: id) {
                displayRects.append(DisplayLayoutConfiguration(displayID: id, screen: screen).rect)
            }
        }

        let currentRect = savedArrangement[displayID]?.rect
            ?? DisplayLayoutConfiguration(displayID: displayID, screen: screen).rect
        displayRects.append(currentRect)

        let canvasRect = displayRects.reduce(currentRect) { partial, rect in
            partial.union(rect)
        }

        renderer.setDisplaySpanConfiguration(
            enabled: spanEnabled,
            displayRect: currentRect,
            canvasRect: canvasRect
        )
    }
}
