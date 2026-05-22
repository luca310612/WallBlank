import Foundation
import AppKit
import AVFoundation
import Combine
import MetalKit
import UniformTypeIdentifiers

// MARK: - ImageEditorManager + IO
// Why: プロジェクト保存/読み込み、書き出し、Workshop連携、ファイルダイアログを集約。

extension ImageEditorManager {

    func relativePath(for path: String, projectDir: URL) -> String {
        let full = URL(fileURLWithPath: path).standardized
        let base = projectDir.standardized
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        let fullPath = full.path
        guard fullPath.hasPrefix(basePath) else { return path }
        let suffix = fullPath.dropFirst(basePath.count)
        return String(suffix)
    }

    func resolvePath(_ path: String, projectDir: URL) -> String {
        // 絶対パス（/ で始まる）はそのまま
        if path.hasPrefix("/") { return path }
        return projectDir.appendingPathComponent(path).standardized.path
    }

    static func isArtiaPackageURL(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "artia"
    }

    func saveProject(to url: URL) throws {
        let fileManager = FileManager.default
        let isPackage = Self.isArtiaPackageURL(url)

        if isPackage {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            let assetsURL = url.appendingPathComponent("assets", isDirectory: true)
            try fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)

            var savedPaths: [(EditorLayer, String?, String?)] = []

            for (index, layer) in project.layers.enumerated() {
                let origImage = layer.imagePath
                let origVideo = layer.videoPath

                if let src = layer.imagePath, fileManager.fileExists(atPath: src) {
                    let ext = URL(fileURLWithPath: src).pathExtension.isEmpty ? "png" : URL(fileURLWithPath: src).pathExtension
                    let destName = "layer_\(index)_image.\(ext)"
                    let destURL = assetsURL.appendingPathComponent(destName)
                    if fileManager.fileExists(atPath: destURL.path) { try fileManager.removeItem(at: destURL) }
                    try fileManager.copyItem(at: URL(fileURLWithPath: src), to: destURL)
                    layer.imagePath = "assets/\(destName)"
                }
                if let src = layer.videoPath, fileManager.fileExists(atPath: src) {
                    let ext = URL(fileURLWithPath: src).pathExtension.isEmpty ? "mp4" : URL(fileURLWithPath: src).pathExtension
                    let destName = "layer_\(index)_video.\(ext)"
                    let destURL = assetsURL.appendingPathComponent(destName)
                    if fileManager.fileExists(atPath: destURL.path) { try fileManager.removeItem(at: destURL) }
                    try fileManager.copyItem(at: URL(fileURLWithPath: src), to: destURL)
                    layer.videoPath = "assets/\(destName)"
                }
                savedPaths.append((layer, origImage, origVideo))
            }
            defer {
                for (layer, origImage, origVideo) in savedPaths {
                    layer.imagePath = origImage
                    layer.videoPath = origVideo
                }
            }

            let jsonURL = url.appendingPathComponent("project.json", isDirectory: false)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(project)
            try data.write(to: jsonURL)

            if let previewImage = exportAsImage(),
               let tiffData = previewImage.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) {
                let previewURL = url.appendingPathComponent("preview.jpg", isDirectory: false)
                try jpegData.write(to: previewURL)
            }
        } else {
            let projectDir = url.deletingLastPathComponent()
            var savedPaths: [(EditorLayer, String?, String?)] = []

            for layer in project.layers {
                let origImage = layer.imagePath
                let origVideo = layer.videoPath
                if let p = layer.imagePath {
                    layer.imagePath = relativePath(for: p, projectDir: projectDir)
                }
                if let p = layer.videoPath {
                    layer.videoPath = relativePath(for: p, projectDir: projectDir)
                }
                savedPaths.append((layer, origImage, origVideo))
            }
            defer {
                for (layer, origImage, origVideo) in savedPaths {
                    layer.imagePath = origImage
                    layer.videoPath = origVideo
                }
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(project)
            try data.write(to: url)
        }

        project.modifiedAt = Date()
        isModified = false
        currentProjectURL = url
        clearAutosaveCache()

        debugLog("[ImageEditorManager] プロジェクト保存: \(url.path)")
    }

    func discardUnsavedSessionAndResetEditor() {
        clearAutosaveCache()
        removeTransientEditorCacheFiles()
        newProject()
    }

    func removeTransientEditorCacheFiles() {
        let dir = autosaveCacheURL.deletingLastPathComponent()
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for u in urls {
            let name = u.lastPathComponent
            if name.hasPrefix("artia_editor_export_") || name.hasPrefix("editor_") && name.hasSuffix(".png") {
                try? fm.removeItem(at: u)
            }
        }
    }

    func save() {
        if let url = currentProjectURL {
            try? saveProject(to: url)
        } else {
            showSaveDialog()
        }
    }

    func confirmSaveBeforeClose() -> Bool {
        guard isModified else { return true }

        let alert = NSAlert()
        alert.messageText = "変更内容を保存しますか？"
        alert.informativeText = "保存しない場合、編集内容は失われます。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "保存しない")
        alert.addButton(withTitle: "キャンセル")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            // 保存してから閉じる
            save()
            return true
        case .alertSecondButtonReturn:
            // 保存せずに閉じる — 未保存セッション・オートセーブ・一時ファイルを捨てて空のエディターに戻す
            discardUnsavedSessionAndResetEditor()
            return true
        default:
            // キャンセル — 閉じない
            return false
        }
    }

    func loadProject(from url: URL) throws {
        let jsonURL: URL
        let projectDir: URL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue,
           Self.isArtiaPackageURL(url) {
            let j = url.appendingPathComponent("project.json", isDirectory: false)
            guard FileManager.default.fileExists(atPath: j.path) else {
                throw NSError(
                    domain: "ArtiaEditor",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "無効な .artia パッケージです（project.json がありません）"]
                )
            }
            jsonURL = j
            projectDir = url
        } else {
            jsonURL = url
            projectDir = url.deletingLastPathComponent()
        }

        let data = try Data(contentsOf: jsonURL)
        let loaded = try JSONDecoder().decode(EditorProject.self, from: data)

        for layer in loaded.layers {
            if let p = layer.imagePath, !p.hasPrefix("/") {
                layer.imagePath = resolvePath(p, projectDir: projectDir)
            }
            if let p = layer.videoPath, !p.hasPrefix("/") {
                layer.videoPath = resolvePath(p, projectDir: projectDir)
            }
        }

        project = loaded
        selectedLayerID = loaded.selectedLayerID

        // テクスチャを再ロード
        reloadAllTextures()

        undoStack.removeAll()
        redoStack.removeAll()
        isModified = false
        currentProjectURL = url
        clearAutosaveCache()
        freeformBrushCompletedOutlines = []

        requestRender()
        debugLog("[ImageEditorManager] プロジェクト読み込み: \(url.path)")
    }

    func newProject(width: Int? = nil, height: Int? = nil) {
        let resolvedWidth: Int
        let resolvedHeight: Int
        if let w = width, let h = height {
            resolvedWidth = w
            resolvedHeight = h
        } else {
            // メインディスプレイのピクセル解像度を自動検出
            let screen = NSScreen.main ?? NSScreen.screens.first
            let scale = screen?.backingScaleFactor ?? 2.0
            let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
            resolvedWidth = Int(frame.width * scale)
            resolvedHeight = Int(frame.height * scale)
        }
        project = EditorProject(canvasWidth: resolvedWidth, canvasHeight: resolvedHeight)
        selectedLayerID = nil
        undoStack.removeAll()
        redoStack.removeAll()
        isModified = false
        currentProjectURL = nil
        clearAutosaveCache()
        selection = .init()
        freeformBrushCompletedOutlines = []

        // WGPUエンジンを新しいキャンバスサイズで再作成
        rebuildWgpuEngine()

        requestRender()

        debugLog("[ImageEditorManager] 新規プロジェクト作成: \(resolvedWidth)x\(resolvedHeight)")
    }

    func exportForWorkshop(to folderURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let assetsURL = folderURL.appendingPathComponent("assets", isDirectory: true)
        try fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)

        var savedPaths: [(EditorLayer, String?, String?)] = []

        for (index, layer) in project.layers.enumerated() {
            let origImage = layer.imagePath
            let origVideo = layer.videoPath

            if let src = layer.imagePath, fileManager.fileExists(atPath: src) {
                let ext = URL(fileURLWithPath: src).pathExtension.isEmpty ? "png" : URL(fileURLWithPath: src).pathExtension
                let destName = "layer_\(index)_image.\(ext)"
                let destURL = assetsURL.appendingPathComponent(destName)
                if fileManager.fileExists(atPath: destURL.path) { try fileManager.removeItem(at: destURL) }
                try fileManager.copyItem(at: URL(fileURLWithPath: src), to: destURL)
                layer.imagePath = "assets/\(destName)"
            }
            if let src = layer.videoPath, fileManager.fileExists(atPath: src) {
                let ext = URL(fileURLWithPath: src).pathExtension.isEmpty ? "mp4" : URL(fileURLWithPath: src).pathExtension
                let destName = "layer_\(index)_video.\(ext)"
                let destURL = assetsURL.appendingPathComponent(destName)
                if fileManager.fileExists(atPath: destURL.path) { try fileManager.removeItem(at: destURL) }
                try fileManager.copyItem(at: URL(fileURLWithPath: src), to: destURL)
                layer.videoPath = "assets/\(destName)"
            }
            savedPaths.append((layer, origImage, origVideo))
        }
        defer {
            for (layer, origImage, origVideo) in savedPaths {
                layer.imagePath = origImage
                layer.videoPath = origVideo
            }
        }

        let projectFileURL = folderURL.appendingPathComponent("project.json", isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        try data.write(to: projectFileURL)

        if let previewImage = exportAsImage(),
           let tiffData = previewImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) {
            let previewURL = folderURL.appendingPathComponent("preview.jpg", isDirectory: false)
            try jpegData.write(to: previewURL)
        }

        debugLog("[ImageEditorManager] Workshop用エクスポート完了: \(folderURL.path)")
    }

    func showExportForWorkshopDialog() {
        let panel = NSOpenPanel()
        panel.title = "Workshop 用にエクスポート"
        panel.prompt = "選択"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try self?.exportForWorkshop(to: url)
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "エクスポート完了"
                    alert.informativeText = "フォルダに project.json、assets、preview.jpg を保存しました。"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "エクスポートに失敗しました"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    func showUploadToWorkshopDialog() {
        let steam = SteamManager.shared
        guard steam.isAvailable else {
            let alert = NSAlert()
            alert.messageText = "Steam に接続してください"
            alert.informativeText = steam.statusMessage + "\n\nSteam クライアントを起動し、ログインした状態で再度お試しください。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let legalText = "投稿すると Steam Workshop 利用規約（https://steamcommunity.com/sharedfiles/workshoplegalagreement）に同意したことになります。"
        let alert = NSAlert()
        alert.messageText = "Workshop に投稿"
        alert.informativeText = "タイトルと説明を設定してからアップロードします。\n\n" + legalText
        alert.alertStyle = .informational
        alert.addButton(withTitle: "投稿する")
        alert.addButton(withTitle: "キャンセル")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        // 一時フォルダにエクスポートしてから Steam UGC でアップロード（steamworks-swift 実装時に SetItemContent 等を呼ぶ）
        let tempDir = FileManager.default.temporaryDirectory
        let workshopDir = tempDir.appendingPathComponent("artia_workshop_\(UUID().uuidString)", isDirectory: true)
        do {
            try exportForWorkshop(to: workshopDir)
            // TODO: SteamManager.api で CreateItem → SetItemContent / SetItemPreview → SubmitItemUpdate を呼ぶ。
            // 失敗時は SubmitItemUpdate のコールバックで EResult をチェックし NSAlert で表示。
            // アップロード中は GetItemUpdateProgress で進捗を取得しプログレス表示する。
            let alert2 = NSAlert()
            alert2.messageText = "準備完了"
            alert2.informativeText = "アップロード用フォルダを準備しました。steamworks-swift 実装後、ここで Steam UGC にアップロードされます。\n\nフォルダ: \(workshopDir.path)"
            alert2.alertStyle = .informational
            alert2.addButton(withTitle: "OK")
            alert2.runModal()
        } catch {
            let alert2 = NSAlert()
            alert2.messageText = "アップロード準備に失敗しました"
            alert2.informativeText = error.localizedDescription
            alert2.alertStyle = .warning
            alert2.addButton(withTitle: "OK")
            alert2.runModal()
        }
    }

    func exportAsImage() -> NSImage? {
        if let engine = wgpuEngine {
            // エクスポート時はビューポートモードを一時的に無効化（キャンバスサイズでレンダリング）
            RustCore.wgpuSetViewportMode(engine, enabled: false)
            let result: NSImage?
            if let (data, width, height) = RustCore.wgpuExportRGBA(engine) {
                result = rgbaToNSImage(data: data, width: Int(width), height: Int(height))
            } else {
                result = nil
            }
            // ビューポートモードを復帰
            RustCore.wgpuSetViewportMode(engine, enabled: true)
            return result
        }

        // フォールバック: 従来のMetalレンダラー
        render()
        return renderer?.exportAsImage()
    }

    func rgbaToNSImage(data: Data, width: Int, height: Int) -> NSImage? {
        let bitsPerComponent = 8
        let bitsPerPixel = 32
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerPixel,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    func applyToWallpaperEngine() {
        guard let image = exportAsImage() else {
            debugLog("[ImageEditorManager] エクスポート失敗：壁紙に適用できません")
            return
        }

        // 一時ファイルに保存
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("artia_editor_export_\(UUID().uuidString).png")

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return
        }

        do {
            try pngData.write(to: tempURL)

            // WallpaperEngineに通知
            let settings = SharedSettingsManager.shared
            settings.backgroundImagePath = tempURL.path

            debugLog("[ImageEditorManager] 壁紙に適用完了: \(tempURL.path)")
        } catch {
            debugLog("[ImageEditorManager] 一時ファイル保存失敗: \(error.localizedDescription)")
        }
    }

    func showAddLayerDialog() {
        if isAddLayerPanelOpen { return }
        let now = Date()
        if now.timeIntervalSince(lastAddLayerDialogOpenTime) < addLayerDialogCooldown { return }

        isAddLayerPanelOpen = true
        lastAddLayerDialogOpenTime = now

        let panel = NSOpenPanel()
        panel.title = "画像・動画を選択"
        panel.allowedContentTypes = [
            .png, .jpeg, .heic, .tiff, .bmp,
            .mpeg4Movie, .quickTimeMovie
        ]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        panel.begin { [weak self] response in
            DispatchQueue.main.async {
                self?.isAddLayerPanelOpen = false
            }
            guard response == .OK else { return }
            DispatchQueue.main.async {
                self?.addLayers(from: panel.urls)
            }
        }
    }

    func showSaveDialog() {
        let panel = NSSavePanel()
        panel.title = "プロジェクトを保存"
        panel.allowedContentTypes = [.artiaWallpaperProject, .json]
        panel.nameFieldStringValue = "\(project.name).artia"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try self?.saveProject(to: url)
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "保存に失敗しました"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    func showLoadDialog() {
        let panel = NSOpenPanel()
        panel.title = "プロジェクトを開く"
        panel.allowedContentTypes = [.artiaWallpaperProject, .json]
        panel.allowsMultipleSelection = false

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try self?.loadProject(from: url)
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "読み込みに失敗しました"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }
}
