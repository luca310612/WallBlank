import Cocoa
import WebKit

// MARK: - Web 壁紙用 WKWebView（前面でもフォルダ／メディアをドロップ可能）
// Why: 標準の `WKWebView` はファイルドロップを自前で扱い、壁紙差し替えができないため、
// 壁紙向けドロップだけ受け取れるサブクラスを用意する。

/// 標準の `WKWebView` はファイルドロップを自前で扱い、壁紙差し替えができないため、壁紙向けドロップだけ受け取る。
final class DroppableWKWebView: WKWebView {

    var onFilesDropped: (([URL]) -> Void)?

    private var webActivationClickSequence: Int = 0
    private var webActivationResetWorkItem: DispatchWorkItem?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()

        let deliverOnClick = max(1, AppConstants.WebWallpaper.mouseClicksBeforeWebDelivery)
        if deliverOnClick <= 1 {
            super.mouseDown(with: event)
            return
        }

        webActivationClickSequence += 1
        webActivationResetWorkItem?.cancel()
        let reset = DispatchWorkItem { [weak self] in
            self?.webActivationClickSequence = 0
        }
        webActivationResetWorkItem = reset
        DispatchQueue.main.asyncAfter(
            deadline: .now() + AppConstants.WebWallpaper.mouseActivationSequenceResetSeconds,
            execute: reset
        )

        if webActivationClickSequence < deliverOnClick {
            return
        }
        webActivationClickSequence = 0
        webActivationResetWorkItem?.cancel()
        super.mouseDown(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = WallpaperDragPasteboard.fileURLs(from: sender)
        return WallpaperDragPasteboard.looksLikeWallpaperDrop(urls: urls) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = WallpaperDragPasteboard.fileURLs(from: sender)
        guard WallpaperDragPasteboard.looksLikeWallpaperDrop(urls: urls), !urls.isEmpty else { return false }
        onFilesDropped?(urls)
        return true
    }
}
