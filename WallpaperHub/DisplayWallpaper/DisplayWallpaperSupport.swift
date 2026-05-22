import Cocoa

// MARK: - 壁紙ホスト用 NSWindow
// Why: ボーダーレス・デスクトップレベルでもキーになりうるようにし、
// クリックで `makeKeyAndOrderFront` が効くようにする。

/// ボーダーレス・デスクトップレベルでもキーになりうるようにし、クリックで `makeKeyAndOrderFront` が効くようにする。
final class WallpaperHostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - 壁紙ドラッグ用ペーストボード（フォルダ・日本語パス対応）
// Why: Finder からのフォルダ／日本語パスは `readObjects(forClasses:)` が確実
// （`string(forType: .fileURL)` だけだと失敗することがある）

enum WallpaperDragPasteboard {

    /// Finder からのフォルダ／日本語パスは `readObjects(forClasses:)` が確実（`string(forType: .fileURL)` だけだと失敗することがある）
    static func fileURLs(from draggingInfo: NSDraggingInfo) -> [URL] {
        let pb = draggingInfo.draggingPasteboard
        if let objs = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [NSURL] {
            return objs.map { ($0 as URL).standardizedFileURL }
        }
        guard let items = pb.pasteboardItems else { return [] }
        var urls: [URL] = []
        for item in items {
            if let s = item.string(forType: .fileURL) {
                if let u = URL(string: s) {
                    urls.append(u.standardizedFileURL)
                }
            }
        }
        return urls
    }

    static func looksLikeWallpaperDrop(urls: [URL]) -> Bool {
        urls.contains { url in
            if isValidMediaFile(url) { return true }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
            return isDir.boolValue
        }
    }

    private static func isValidMediaFile(_ url: URL) -> Bool {
        let supportedExtensions = ["mp4", "mov", "m4v", "png", "jpg", "jpeg", "heic", "gif", "tiff", "bmp"]
        return supportedExtensions.contains(url.pathExtension.lowercased())
    }
}

// MARK: - クリック透過オーバーレイ
// Why: 見た目だけのオーバーレイ。Web/音楽壁紙の上に貼られても下層のクリックを邪魔しないよう
// hitTest を素通しする。

/// 見た目だけのオーバーレイ。Web/音楽壁紙の上に貼られても下層のクリックを邪魔しないよう hitTest を素通しする。
final class ClickThroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// メニューバー馴染ませ用の `NSVisualEffectView`。視覚効果のみで、クリックは下層へ通す。
final class ClickThroughVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
