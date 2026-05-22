import Cocoa
import MetalKit
import SwiftUI
import WebKit

// MARK: - DisplayWallpaperInstance + DragDrop
// Why: ドラッグ＆ドロップ受け入れとプレイリスト管理を集約。

extension DisplayWallpaperInstance {

    func handleDroppedFiles(_ urls: [URL]) {
        debugLog("[Instance:\(displayID)] Files dropped: \(urls.map { $0.lastPathComponent })")

        for url in urls {
            if isWebWallpaperDirectory(url) {
                stopPlaylist()
                loadWebWallpaper(from: url)
                return
            }
        }

        stopPlaylist()
        hideWebWallpaperIfNeeded()

        var allMediaFiles: [URL] = []

        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    // フォルダの場合：中のメディアファイルを収集
                    let folderFiles = collectMediaFiles(from: url)
                    allMediaFiles.append(contentsOf: folderFiles)
                } else if isValidMediaFile(url) {
                    // 単一ファイルの場合
                    allMediaFiles.append(url)
                }
            }
        }

        guard !allMediaFiles.isEmpty else {
            debugLog("[Instance:\(displayID)] No valid media files found")
            return
        }

        // ファイルをソート（名前順）
        allMediaFiles.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        if allMediaFiles.count == 1 {
            // 単一ファイル：直接再生
            setBackgroundImage(from: allMediaFiles[0])
        } else {
            // 複数ファイル：プレイリストとして設定
            startPlaylist(with: allMediaFiles)
        }
    }

    func collectMediaFiles(from folderURL: URL) -> [URL] {
        var mediaFiles: [URL] = []

        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return mediaFiles
        }

        for case let fileURL as URL in enumerator {
            if isValidMediaFile(fileURL) {
                mediaFiles.append(fileURL)
            }
        }

        debugLog("[Instance:\(displayID)] Found \(mediaFiles.count) media files in folder")
        return mediaFiles
    }

    func isValidMediaFile(_ url: URL) -> Bool {
        let supportedExtensions = ["mp4", "mov", "m4v", "png", "jpg", "jpeg", "heic", "gif", "tiff", "bmp"]
        return supportedExtensions.contains(url.pathExtension.lowercased())
    }

    func isVideoMediaFile(_ url: URL) -> Bool {
        ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
    }

    func startPlaylist(with files: [URL]) {
        mediaPlaylist = files
        currentPlaylistIndex = 0

        debugLog("[Instance:\(displayID)] Starting playlist with \(files.count) files")

        // 最初のファイルを再生
        playCurrentPlaylistItem()

        // 10秒ごとに次のファイルへ（画像の場合）
        playlistTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.advancePlaylist()
        }
    }

    func stopPlaylist() {
        playlistTimer?.invalidate()
        playlistTimer = nil
        mediaPlaylist = []
        currentPlaylistIndex = 0
    }

    func playCurrentPlaylistItem() {
        guard currentPlaylistIndex < mediaPlaylist.count else { return }
        let url = mediaPlaylist[currentPlaylistIndex]
        debugLog("[Instance:\(displayID)] Playing playlist item \(currentPlaylistIndex + 1)/\(mediaPlaylist.count): \(url.lastPathComponent)")
        loadPreparedNonWebWallpaper(from: url)
    }

    func advancePlaylist() {
        guard !mediaPlaylist.isEmpty else { return }

        currentPlaylistIndex = (currentPlaylistIndex + 1) % mediaPlaylist.count
        playCurrentPlaylistItem()
    }

    func nextPlaylistItem() {
        advancePlaylist()
    }

    func previousPlaylistItem() {
        guard !mediaPlaylist.isEmpty else { return }
        currentPlaylistIndex = (currentPlaylistIndex - 1 + mediaPlaylist.count) % mediaPlaylist.count
        playCurrentPlaylistItem()
    }
}
