import Cocoa
import MetalKit

// MARK: - ドラッグ＆ドロップ対応のMTKView
// Why: 壁紙キャンバスへ直接ファイルをドロップできるよう、`NSDraggingDestination` を実装した
// MTKView サブクラスを提供する。

/// ファイルドロップを受け付けるMTKView
class DroppableMTKView: MTKView {

    /// ドロップされたファイルを処理するコールバック
    var onFilesDropped: (([URL]) -> Void)?

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        setupDragAndDrop()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        setupDragAndDrop()
    }

    private func setupDragAndDrop() {
        registerForDraggedTypes([.fileURL])
    }

    // MARK: - NSDraggingDestination

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
