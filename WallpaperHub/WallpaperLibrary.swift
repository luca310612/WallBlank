import Foundation
import SwiftUI
import AVFoundation

/// 壁紙アイテムの種類
enum WallpaperType: String, Codable {
    case image      // 静止画 (.jpg, .png)
    case video      // 動画 (.mp4, .mov)
    case gif        // GIFアニメーション (.gif)
    case shader     // シェーダーエフェクト
    case scene      // Wallpaper Engineシーン (.pkg)
    /// ライブラリ内のフォルダを1作品として扱う（中身はプレイリスト／Web 等で解釈）
    case mediaFolder = "mediaFolder"

    /// SF Symbolアイコン名
    var icon: String {
        switch self {
        case .image: return "photo"
        case .video: return "play.rectangle"
        case .gif: return "photo.stack"
        case .shader: return "wand.and.stars"
        case .scene: return "cube"
        case .mediaFolder: return "folder.fill"
        }
    }

    /// バッジ用アイコンとカラーのタプル
    var iconAndColor: (icon: String, color: Color) {
        switch self {
        case .image: return ("photo", .blue)
        case .video: return ("play.fill", .red)
        case .gif: return ("photo.stack", .green)
        case .shader: return ("sparkles", .purple)
        case .scene: return ("cube.fill", .orange)
        case .mediaFolder: return ("folder.fill", .cyan)
        }
    }

    /// 日本語表示名
    var displayName: String {
        switch self {
        case .image: return "画像"
        case .video: return "動画"
        case .gif: return "GIF"
        case .shader: return "シェーダー"
        case .scene: return "シーン"
        case .mediaFolder: return "フォルダ"
        }
    }
}

/// カテゴリのアイコン取得ヘルパー
enum WallpaperCategoryIcon {
    static func icon(for category: String) -> String {
        switch category {
        case "Shaders": return "wand.and.stars"
        case "ライブラリ": return "folder"
        case "Nature": return "leaf"
        case "Abstract": return "circle.hexagongrid"
        case "Dark": return "moon.stars"
        case "Minimal": return "square"
        case "Anime": return "sparkles"
        default: return "photo"
        }
    }
}

/// 壁紙コレクション（お気に入り・ユーザー定義）
struct WallpaperCollection: Identifiable, Codable {
    let id: String
    var name: String
    var icon: String              // SF Symbol名
    var wallpaperIDs: [String]    // 順序付きリスト
    var createdAt: Date
    var modifiedAt: Date
    let isSystem: Bool            // true = "お気に入り"など削除不可

    init(
        id: String = UUID().uuidString,
        name: String,
        icon: String = "folder",
        wallpaperIDs: [String] = [],
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        isSystem: Bool = false
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.wallpaperIDs = wallpaperIDs
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isSystem = isSystem
    }
}

/// 壁紙アイテムのデータモデル
struct WallpaperItem: Identifiable, Codable {
    let id: String
    let name: String
    let type: WallpaperType
    let thumbnailName: String    // サムネイル画像名
    let fileName: String?        // 実際のファイル名 (image/video用)
    let shaderType: Int?         // シェーダー種類 (shader用)
    let folderName: String?      // フォルダ名 (scene用 - Wallpaper Engineフォルダ)
    /// ライブラリフォルダ外の Web 壁紙など（絶対パス）。設定時はここを優先して適用する。
    let externalRootPath: String?
    let category: String
    var isDownloaded: Bool
    var tags: [String]           // タグ（特徴やキャラクター名など）

    init(
        id: String = UUID().uuidString,
        name: String,
        type: WallpaperType,
        thumbnailName: String,
        fileName: String? = nil,
        shaderType: Int? = nil,
        folderName: String? = nil,
        externalRootPath: String? = nil,
        category: String = "General",
        isDownloaded: Bool = false,
        tags: [String] = []
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.thumbnailName = thumbnailName
        self.fileName = fileName
        self.shaderType = shaderType
        self.folderName = folderName
        self.externalRootPath = externalRootPath
        self.category = category
        self.isDownloaded = isDownloaded
        self.tags = tags
    }
}

extension WallpaperItem {
    /// Wallpaper Engine 互換動画形式の拡張子集合。
    /// Why: VideoWallpaperRuntime と同じ判定基準にし、ライブラリ読み取り側でも
    ///      動画判定をシンプルに行えるようにする。
    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "webm", "avi", "wmv"
    ]

    /// 拡張子から動画ファイルかを判定する。
    /// - Parameter url: 動画候補となる URL。nil 安全なヘルパー版。
    static func isVideoExtension(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// この壁紙アイテムが動画として扱われるか。
    /// - Note: type が `.video` のとき、または fileName の拡張子が動画判定のとき true。
    var isVideo: Bool {
        if type == .video { return true }
        if let fileName, Self.videoExtensions.contains((fileName as NSString).pathExtension.lowercased()) {
            return true
        }
        return false
    }
}

// MARK: - Application 壁紙判定 (Phase 3C)

extension WallpaperItem {
    /// Application 壁紙の形式。
    /// Why: macOS では SIP / App Sandbox の制約から、内製 .bundle のみが現実的にホスト可能で、
    ///      任意 .app は不可となる。UI 側はこの値で「対応／未対応」を分岐する。
    enum ApplicationFormat: String, Codable, Equatable {
        /// 内製 NSViewController プラグイン (.bundle)。BundlePluginRuntime でホスト可能。
        case bundle
        /// .app は macOS 仕様上ホスト不可。UI は ApplicationUnsupportedView を表示する。
        case appBlocked
    }

    /// Bundle プラグインの拡張子。
    static let bundleExtension = "bundle"
    /// macOS では未対応となる .app の拡張子。明示的にブロックするため独立に保持する。
    static let appBlockedExtension = "app"

    /// Application 壁紙として扱える拡張子集合 (.bundle と .app)。
    /// Why: ライブラリ取り込み時の判定と、ドラッグ＆ドロップでの早期検出に共通利用する。
    static let applicationExtensions: Set<String> = [
        bundleExtension, appBlockedExtension
    ]

    /// 拡張子から Application 壁紙候補かを判定する。
    static func isApplicationExtension(_ url: URL) -> Bool {
        applicationExtensions.contains(url.pathExtension.lowercased())
    }

    /// 拡張子から Application 壁紙の format を判定する。
    /// - Returns: `.bundle` / `.appBlocked` / nil (どちらでもないとき)
    static func detectApplicationFormat(for url: URL) -> ApplicationFormat? {
        switch url.pathExtension.lowercased() {
        case bundleExtension: return .bundle
        case appBlockedExtension: return .appBlocked
        default: return nil
        }
    }

    /// この壁紙アイテムが Application 壁紙 (.bundle / .app) として扱われるか。
    var isApplication: Bool {
        applicationFormat != nil
    }

    /// この壁紙アイテムの Application Format。fileName から拡張子を抽出して判定する。
    var applicationFormat: ApplicationFormat? {
        guard let fileName, !fileName.isEmpty else { return nil }
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case Self.bundleExtension: return .bundle
        case Self.appBlockedExtension: return .appBlocked
        default: return nil
        }
    }
}

/// 壁紙ライブラリ管理クラス
class WallpaperLibrary: ObservableObject {
    static let shared = WallpaperLibrary()

    @Published var wallpapers: [WallpaperItem] = []
    @Published var categories: [String] = []
    @Published var isLoading = false
    @Published var downloadProgress: [String: Double] = [:]
    @Published var collections: [WallpaperCollection] = []

    private let fileManager = FileManager.default
    private let wallpaperDirectory: URL

    /// サムネイルキャッシュ（メモリ圧迫時に自動解放）
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private let cacheQueue = DispatchQueue(label: "com.artia.thumbnailcache")
    private let loadStateQueue = DispatchQueue(label: "com.artia.library.loadstate")
    private var activeLoadToken: UInt64 = 0

    /// タグメタデータの保存先
    private var tagMetadataURL: URL {
        wallpaperDirectory.appendingPathComponent("tag_metadata.json")
    }

    /// コレクションデータの保存先
    private var collectionsURL: URL {
        wallpaperDirectory.appendingPathComponent("collections.json")
    }

    /// コピーせず参照している Web 壁紙ルート（Workshop 等）のパス一覧
    private var externalWebRootsURL: URL {
        wallpaperDirectory.appendingPathComponent("external_web_roots.json")
    }

    /// ファイル名 → タグのマッピング
    private var tagMetadata: [String: [String]] = [:]

    private init() {
        // 壁紙保存ディレクトリを設定
        // Application Supportが取得できない場合はテンポラリディレクトリをフォールバックとして使用
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        wallpaperDirectory = appSupport.appendingPathComponent("Artia/Wallpapers")

        if appSupport == fileManager.temporaryDirectory {
            debugLog("[Library] アプリケーションサポートディレクトリが取得できません。テンポラリディレクトリを使用します")
        }

        // ディレクトリ作成
        do {
            try fileManager.createDirectory(at: wallpaperDirectory, withIntermediateDirectories: true)
        } catch {
            debugLog("[Library] 壁紙ディレクトリの作成に失敗: \(error.localizedDescription)")
        }

        // サムネイルキャッシュの上限を設定（メモリ圧迫防止）
        thumbnailCache.countLimit = 100

        // タグメタデータを読み込み
        loadTagMetadata()

        // コレクションを読み込み
        loadCollections()

        // 初期データ読み込み
        loadWallpapers()
    }

    /// ライブラリ保存ディレクトリ直下のサブフォルダ URL（`folderName` はシーン／バンドル用ディレクトリ名）
    func subfolderURL(inLibrary folderName: String) -> URL {
        wallpaperDirectory.appendingPathComponent(folderName)
    }

    /// 壁紙データを読み込み（非同期でファイルスキャン）
    func loadWallpapers() {
        let baseItems = defaultWallpaperItems()
        let token = loadStateQueue.sync {
            activeLoadToken &+= 1
            return activeLoadToken
        }

        DispatchQueue.main.async {
            self.wallpapers = baseItems
            self.categories = Array(Set(baseItems.map(\.category))).sorted()
            self.isLoading = true
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            var items = baseItems
            var pendingBatch = 0
            let batchSize = 12

            let publishSnapshot: (_ isFinal: Bool) -> Void = { isFinal in
                let snapshot = items
                let categories = Array(Set(snapshot.map(\.category))).sorted()

                DispatchQueue.main.async {
                    guard self.isActiveLoad(token) else { return }
                    self.wallpapers = snapshot
                    self.categories = categories
                    self.isLoading = !isFinal
                }
            }

            let appendItem: (WallpaperItem) -> Void = { item in
                items.append(item)
                pendingBatch += 1
                if pendingBatch >= batchSize {
                    pendingBatch = 0
                    publishSnapshot(false)
                }
            }

            self.scanLocalWallpapers(append: appendItem)
            self.appendExternalWebWallpaperItems(append: appendItem)
            self.loadCatalog(append: appendItem)

            publishSnapshot(true)

            debugLog("[Library] Loaded \(items.count) wallpapers")
            for item in items {
                debugLog("[Library] - \(item.name) (\(item.type), \(item.category))")
            }
        }
    }

    private func isActiveLoad(_ token: UInt64) -> Bool {
        loadStateQueue.sync { activeLoadToken == token }
    }

    private func defaultWallpaperItems() -> [WallpaperItem] {
        []
    }

    /// ローカルの壁紙ファイルをスキャン
    private func scanLocalWallpapers(append: (WallpaperItem) -> Void) {
        let supportedImageExtensions = ["jpg", "jpeg", "png", "heic"]
        let supportedVideoExtensions = ["mp4", "mov"]
        let supportedGifExtensions = ["gif"]

        debugLog("[Library] Scanning directory: \(wallpaperDirectory.path)")

        guard let contents = try? fileManager.contentsOfDirectory(
            at: wallpaperDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            debugLog("[Library] Failed to read directory contents")
            return
        }

        debugLog("[Library] Found \(contents.count) items in directory")

        for url in contents {
            // ディレクトリの場合、Wallpaper Engineフォルダかチェック
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                if let sceneItem = scanWallpaperEngineFolder(url) {
                    append(sceneItem)
                    continue
                }
                // project.json がないフォルダは「1作品」として登録（中身は展開しない）
                if let bundleItem = scanMediaFolderBundle(url) {
                    append(bundleItem)
                }
                continue
            }

            // ファイルの場合
            let ext = url.pathExtension.lowercased()
            let fileName = url.lastPathComponent
            let rawName = url.deletingPathExtension().lastPathComponent
            // ファイル名末尾の一意性サフィックス（_英数字8文字）を表示名から除去
            let name: String
            if let range = rawName.range(of: "_[0-9A-Fa-f]{8}$", options: .regularExpression) {
                name = String(rawName[rawName.startIndex..<range.lowerBound])
            } else if let range = rawName.range(of: "_\\d{10}$", options: .regularExpression) {
                // タイムスタンプ形式（AI生成壁紙用）
                name = String(rawName[rawName.startIndex..<range.lowerBound])
            } else {
                name = rawName
            }

            let storedTags = tagMetadata[fileName] ?? []

            if supportedImageExtensions.contains(ext) {
                append(WallpaperItem(
                    id: "local_\(fileName)",
                    name: name,
                    type: .image,
                    thumbnailName: fileName,
                    fileName: fileName,
                    externalRootPath: nil,
                    category: "ライブラリ",
                    isDownloaded: true,
                    tags: storedTags
                ))
            } else if supportedVideoExtensions.contains(ext) {
                debugLog("[Library] Adding video: \(fileName)")
                append(WallpaperItem(
                    id: "local_\(fileName)",
                    name: name,
                    type: .video,
                    thumbnailName: fileName,
                    fileName: fileName,
                    externalRootPath: nil,
                    category: "ライブラリ",
                    isDownloaded: true,
                    tags: storedTags
                ))
            } else if supportedGifExtensions.contains(ext) {
                debugLog("[Library] Adding GIF: \(fileName)")
                append(WallpaperItem(
                    id: "local_\(fileName)",
                    name: name,
                    type: .gif,
                    thumbnailName: fileName,
                    fileName: fileName,
                    externalRootPath: nil,
                    category: "ライブラリ",
                    isDownloaded: true,
                    tags: storedTags
                ))
            }
        }
    }

    /// Wallpaper Engineフォルダをスキャン（project.json + scene.pkg + preview.jpg）
    private func scanWallpaperEngineFolder(_ folderURL: URL) -> WallpaperItem? {
        let projectJsonURL = folderURL.appendingPathComponent("project.json")
        let previewURL = folderURL.appendingPathComponent("preview.jpg")

        // project.jsonが存在するか確認
        guard fileManager.fileExists(atPath: projectJsonURL.path) else {
            return nil
        }

        debugLog("[Library] Found Wallpaper Engine folder: \(folderURL.lastPathComponent)")

        // project.jsonを読み込み（カテゴリはギャラリーを「ライブラリ」に統一し、WE の tags はタグのみに載せる）
        var title = folderURL.lastPathComponent
        let category = "ライブラリ"
        var sceneTags: [String] = []

        if let jsonData = try? Data(contentsOf: projectJsonURL),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            if let jsonTitle = json["title"] as? String {
                title = jsonTitle
            }
            if let jsonTags = json["tags"] as? [String] {
                sceneTags = jsonTags
            }
        }

        let folderName = folderURL.lastPathComponent

        // 保存済みタグがあればマージ
        let storedTags = tagMetadata[folderName] ?? []
        let mergedTags = Array(Set(sceneTags + storedTags))

        let thumbURL = wallpaperEngineFolderThumbnailURL(in: folderURL) ?? previewURL

        return WallpaperItem(
            id: "scene_\(folderName)",
            name: title,
            type: .scene,
            thumbnailName: thumbURL.path,
            folderName: folderName,
            externalRootPath: nil,
            category: category,
            isDownloaded: true,
            tags: mergedTags
        )
    }

    /// WE フォルダのサムネ: `project.json` の `preview` → `preview.jpg` → `cover/` 内画像
    private func wallpaperEngineFolderThumbnailURL(in folderURL: URL) -> URL? {
        let fm = fileManager
        let projectURL = folderURL.appendingPathComponent("project.json")
        if fm.fileExists(atPath: projectURL.path),
           let data = try? Data(contentsOf: projectURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let previewRel = json["preview"] as? String {
            let trimmed = previewRel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let norm = trimmed.replacingOccurrences(of: "\\", with: "/")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                var resolved = folderURL
                for part in norm.split(separator: "/") where !part.isEmpty {
                    resolved = resolved.appendingPathComponent(String(part))
                }
                if fm.fileExists(atPath: resolved.path) {
                    return resolved.standardizedFileURL
                }
            }
        }
        let jpg = folderURL.appendingPathComponent("preview.jpg")
        if fm.fileExists(atPath: jpg.path) {
            return jpg.standardizedFileURL
        }
        let coverURL = folderURL.appendingPathComponent("cover")
        guard let contents = try? fm.contentsOfDirectory(at: coverURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return nil
        }
        let exts = ["png", "jpg", "jpeg", "webp", "gif"]
        let images = contents.filter { exts.contains($0.pathExtension.lowercased()) }
        guard !images.isEmpty else { return nil }
        return images.min { $0.path.localizedStandardCompare($1.path) == .orderedAscending }?.standardizedFileURL
    }

    /// 壁紙フォルダ内で扱うメディア拡張子（`DisplayWallpaperInstance` と揃える）
    private static let bundleMediaExtensions: Set<String> = [
        "mp4", "mov", "m4v", "png", "jpg", "jpeg", "heic", "gif", "tiff", "bmp"
    ]

    /// `project.json` のないフォルダを 1 作品として登録
    private func scanMediaFolderBundle(_ folderURL: URL) -> WallpaperItem? {
        let basePath = wallpaperDirectory.standardizedFileURL.path
        let folderPath = folderURL.standardizedFileURL.path
        guard folderPath.hasPrefix(basePath + "/") || folderPath == basePath else {
            return nil
        }

        let hasWeb = WallpaperEngineWebResolver.isWebWallpaperRoot(folderURL)
        guard folderContainsSupportedMedia(folderURL) || hasWeb else {
            debugLog("[Library] メディア/Web が無いフォルダはスキップ: \(folderURL.lastPathComponent)")
            return nil
        }

        let folderName = folderURL.lastPathComponent
        let displayName: String
        if let range = folderName.range(of: "^[0-9]+_", options: .regularExpression) {
            displayName = String(folderName[range.upperBound...])
        } else {
            displayName = folderName
        }

        let storedTags = tagMetadata[folderName] ?? []
        return WallpaperItem(
            id: "bundle_\(folderName)",
            name: displayName.isEmpty ? folderName : displayName,
            type: .mediaFolder,
            thumbnailName: "",
            fileName: nil,
            folderName: folderName,
            externalRootPath: nil,
            category: "ライブラリ",
            isDownloaded: true,
            tags: storedTags
        )
    }

    private func folderContainsSupportedMedia(_ root: URL) -> Bool {
        firstMediaFileInFolder(root) != nil
    }

    /// サムネイル用にフォルダ内の代表メディア（名前順の先頭）を返す
    private func firstMediaFileInFolder(_ root: URL) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var candidates: [URL] = []
        for case let fileURL as URL in enumerator {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue else {
                continue
            }
            let depth = fileURL.pathComponents.count - root.pathComponents.count
            if depth > 12 { continue }
            let ext = fileURL.pathExtension.lowercased()
            guard Self.bundleMediaExtensions.contains(ext) else { continue }
            candidates.append(fileURL)
        }
        candidates.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return candidates.first
    }

    /// ライブラリ外パスの Web 壁紙を一覧用に登録（コピーしない Workshop 等）
    func registerExternalWebWallpaperRoot(_ url: URL) {
        guard WallpaperEngineWebResolver.isWebWallpaperRoot(url) else { return }
        let path = url.standardizedFileURL.path
        var paths: [String] = []
        if let data = try? Data(contentsOf: externalWebRootsURL),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            paths = decoded
        }
        guard !paths.contains(path) else { return }
        paths.append(path)
        guard let out = try? JSONEncoder().encode(paths) else { return }
        try? out.write(to: externalWebRootsURL, options: [.atomic])
        debugLog("[Library] 外部 Web 壁紙ルートを登録: \(path)")
    }

    private func removeExternalWebWallpaperRoot(_ path: String) {
        guard let data = try? Data(contentsOf: externalWebRootsURL),
              var paths = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        let norm = URL(fileURLWithPath: path).standardizedFileURL.path
        paths.removeAll { URL(fileURLWithPath: $0).standardizedFileURL.path == norm }
        guard let out = try? JSONEncoder().encode(paths) else { return }
        try? out.write(to: externalWebRootsURL, options: [.atomic])
    }

    private func appendExternalWebWallpaperItems(append: (WallpaperItem) -> Void) {
        guard let data = try? Data(contentsOf: externalWebRootsURL),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }

        for path in paths {
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                  WallpaperEngineWebResolver.isWebWallpaperRoot(url) else {
                continue
            }

            let thumbPath = wallpaperEngineFolderThumbnailURL(in: url)?.path ?? ""
            let stableId = Self.stableWebRefId(for: path)
            var title = url.lastPathComponent
            let projectURL = url.appendingPathComponent("project.json")
            if let jsonData = try? Data(contentsOf: projectURL),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let jsonTitle = json["title"] as? String, !jsonTitle.isEmpty {
                title = jsonTitle
            }

            append(WallpaperItem(
                id: stableId,
                name: title,
                type: .scene,
                thumbnailName: thumbPath,
                fileName: nil,
                folderName: nil,
                externalRootPath: path,
                category: "ライブラリ",
                isDownloaded: true,
                tags: []
            ))
        }
    }

    private static func stableWebRefId(for path: String) -> String {
        var h: UInt64 = 5381
        for b in path.utf8 {
            h = ((h &<< 5) &+ h) &+ UInt64(b)
        }
        return "webref_\(String(h, radix: 16))"
    }

    /// カタログJSONを読み込み
    private func loadCatalog(append: (WallpaperItem) -> Void) {
        let catalogURL = wallpaperDirectory.appendingPathComponent("catalog.json")

        guard fileManager.fileExists(atPath: catalogURL.path),
              let data = try? Data(contentsOf: catalogURL),
              let catalogItems = try? JSONDecoder().decode([WallpaperItem].self, from: data)
        else { return }

        // ダウンロード状態を更新
        for var item in catalogItems {
            if let fileName = item.fileName {
                let fileURL = wallpaperDirectory.appendingPathComponent(fileName)
                item.isDownloaded = fileManager.fileExists(atPath: fileURL.path)
            }
            append(item)
        }
    }

    /// 壁紙ファイルのURLを取得
    func getWallpaperURL(for item: WallpaperItem) -> URL? {
        if let ext = item.externalRootPath, !ext.isEmpty {
            let u = URL(fileURLWithPath: ext)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: ext, isDirectory: &isDir), isDir.boolValue else { return nil }
            return WallpaperEngineWebResolver.isWebWallpaperRoot(u) ? u : nil
        }
        if item.type == .mediaFolder, let folderName = item.folderName {
            let u = wallpaperDirectory.appendingPathComponent(folderName)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            return u
        }
        guard let fileName = item.fileName else { return nil }
        let url = wallpaperDirectory.appendingPathComponent(fileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// サムネイル画像を取得（キャッシュ付き）
    func getThumbnailImage(for item: WallpaperItem) -> NSImage? {
        // キャッシュをチェック
        if let cached = cacheQueue.sync(execute: { thumbnailCache.object(forKey: item.id as NSString) }) {
            return cached
        }

        var image: NSImage?

        // シェーダーの場合はプレースホルダー
        if item.type == .shader {
            image = generateShaderThumbnail(shaderType: item.shaderType ?? 0)
        }
        // ライブラリ内のフォルダ1件＝1作品（代表ファイルでサムネイル）
        else if item.type == .mediaFolder, let folderName = item.folderName {
            let folderURL = wallpaperDirectory.appendingPathComponent(folderName)
            let previewURL = folderURL.appendingPathComponent("preview.jpg")
            if fileManager.fileExists(atPath: previewURL.path) {
                image = NSImage(contentsOf: previewURL)
            } else if let mediaURL = firstMediaFileInFolder(folderURL) {
                let ext = mediaURL.pathExtension.lowercased()
                if ext == "mp4" || ext == "mov" || ext == "m4v" {
                    image = generateVideoThumbnail(from: mediaURL)
                } else {
                    image = NSImage(contentsOf: mediaURL)
                }
            }
        }
        // Wallpaper Engineシーンの場合（Web / scene.pkg 共通で project.json 由来サムネを解決）
        else if item.type == .scene {
            if let ext = item.externalRootPath, !ext.isEmpty {
                let root = URL(fileURLWithPath: ext)
                if let thumb = wallpaperEngineFolderThumbnailURL(in: root) {
                    image = NSImage(contentsOf: thumb)
                }
            } else if item.thumbnailName.hasPrefix("/"), fileManager.fileExists(atPath: item.thumbnailName) {
                image = NSImage(contentsOfFile: item.thumbnailName)
            } else if let folderName = item.folderName {
                let folderURL = wallpaperDirectory.appendingPathComponent(folderName)
                if let thumb = wallpaperEngineFolderThumbnailURL(in: folderURL) {
                    image = NSImage(contentsOf: thumb)
                }
            }
        }
        // ローカルファイルの場合
        else if let fileName = item.fileName {
            let url = wallpaperDirectory.appendingPathComponent(fileName)

            // 動画ファイルの場合は最初のフレームを抽出
            if item.type == .video {
                image = generateVideoThumbnail(from: url)
            } else {
                // 画像またはGIFの場合
                image = NSImage(contentsOf: url)
            }
        }

        // バンドル内のサムネイルを探す
        if image == nil {
            if let bundleURL = Bundle.main.url(forResource: item.thumbnailName, withExtension: nil) {
                image = NSImage(contentsOf: bundleURL)
            }
        }

        // キャッシュに保存
        if let image = image {
            cacheQueue.sync {
                thumbnailCache.setObject(image, forKey: item.id as NSString)
            }
        }

        return image
    }

    /// サムネイルのファイルパスを取得（ウィジェット用）
    func getThumbnailPath(for item: WallpaperItem) -> String? {
        if let ext = item.externalRootPath, !ext.isEmpty {
            let root = URL(fileURLWithPath: ext)
            if item.type == .scene, let thumb = wallpaperEngineFolderThumbnailURL(in: root) {
                return thumb.path
            }
            let previewURL = root.appendingPathComponent("preview.jpg")
            if fileManager.fileExists(atPath: previewURL.path) {
                return previewURL.path
            }
        }
        if item.type == .mediaFolder, let folderName = item.folderName {
            let folderURL = wallpaperDirectory.appendingPathComponent(folderName)
            let previewURL = folderURL.appendingPathComponent("preview.jpg")
            if fileManager.fileExists(atPath: previewURL.path) {
                return previewURL.path
            }
            if let media = firstMediaFileInFolder(folderURL) {
                return media.path
            }
        }
        if item.thumbnailName.hasPrefix("/") {
            return item.thumbnailName
        }
        if let fileName = item.fileName {
            let url = wallpaperDirectory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: url.path) {
                return url.path
            }
        }
        if item.type == .scene, let folderName = item.folderName {
            let folderURL = wallpaperDirectory.appendingPathComponent(folderName)
            if let thumb = wallpaperEngineFolderThumbnailURL(in: folderURL) {
                return thumb.path
            }
        }
        return nil
    }

    /// サムネイルキャッシュをクリア
    func clearThumbnailCache() {
        cacheQueue.sync {
            thumbnailCache.removeAllObjects()
        }
    }

    /// シェーダーサムネイルを生成（ブロックベースの描画APIを使用）
    private func generateShaderThumbnail(shaderType: Int) -> NSImage {
        let size = NSSize(width: 200, height: 120)

        let image = NSImage(size: size, flipped: false) { rect in
            let colors: [NSColor]
            switch shaderType {
            case ShaderType.transparent.rawValue: // 透過
                colors = [NSColor(white: 0.9, alpha: 0.3),
                         NSColor(white: 0.7, alpha: 0.3)]
            case ShaderType.gradient.rawValue: // Gradient
                colors = [NSColor(red: 0.4, green: 0.2, blue: 0.8, alpha: 1),
                         NSColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)]
            case ShaderType.plasma.rawValue: // Plasma
                colors = [NSColor(red: 0.9, green: 0.3, blue: 0.5, alpha: 1),
                         NSColor(red: 0.3, green: 0.2, blue: 0.8, alpha: 1)]
            case ShaderType.noise.rawValue: // Noise
                colors = [NSColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1),
                         NSColor(red: 0.1, green: 0.5, blue: 0.6, alpha: 1)]
            default:
                colors = [NSColor.darkGray, NSColor.lightGray]
            }

            let gradient = NSGradient(colors: colors)
            gradient?.draw(in: rect, angle: 45)
            return true
        }

        return image
    }

    /// 動画から最初のフレームを抽出してサムネイルを生成
    private func generateVideoThumbnail(from url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 400, height: 300)

        let semaphore = DispatchSemaphore(value: 0)
        var resultImage: NSImage?

        imageGenerator.generateCGImageAsynchronously(for: .zero) { cgImage, _, error in
            if let cgImage = cgImage {
                let size = NSSize(width: cgImage.width, height: cgImage.height)
                resultImage = NSImage(cgImage: cgImage, size: size)
            } else if let error = error {
                debugLog("[Library] 動画サムネイル生成に失敗: \(error)")
            }
            semaphore.signal()
        }
        semaphore.wait()
        return resultImage
    }

    /// ファイルまたはフォルダをインポート（タグ付き）
    func importFile(from url: URL, tags: [String] = []) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            debugLog("[Library] File does not exist: \(url.path)")
            return
        }

        // ディレクトリの場合
        if isDirectory.boolValue {
            importFolder(from: url, tags: tags)
            return
        }

        // ファイルの場合
        let fileName = url.lastPathComponent
        let destinationURL = wallpaperDirectory.appendingPathComponent(fileName)

        do {
            // 同名ファイルがあれば削除
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            // コピー
            try fileManager.copyItem(at: url, to: destinationURL)

            // タグを保存
            if !tags.isEmpty {
                saveTagsForFile(fileName: fileName, tags: tags)
            }

            // リロード
            loadWallpapers()
        } catch {
            debugLog("[Library] Failed to import file: \(error)")
        }
    }

    /// フォルダをインポート（Wallpaper Engineフォルダまたは通常の画像/動画フォルダに対応）
    private func importFolder(from url: URL, tags: [String] = []) {
        let folderName = url.lastPathComponent

        // Wallpaper Engineフォルダ（project.jsonが存在する）の場合はフォルダごとコピー
        let projectJsonURL = url.appendingPathComponent("project.json")
        if fileManager.fileExists(atPath: projectJsonURL.path) {
            let destinationURL = wallpaperDirectory.appendingPathComponent(folderName)
            debugLog("[Library] Importing Wallpaper Engine folder: \(folderName)")

            do {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.copyItem(at: url, to: destinationURL)

                // タグを保存（フォルダ名をキーとして使用）
                if !tags.isEmpty {
                    saveTagsForFile(fileName: folderName, tags: tags)
                }

                debugLog("[Library] Wallpaper Engine folder imported successfully: \(folderName)")
                loadWallpapers()
            } catch {
                debugLog("[Library] Failed to import folder: \(error)")
            }
            return
        }

        // 通常のフォルダの場合：中のメディアファイルを個別にコピー
        let supportedExtensions = ["jpg", "jpeg", "png", "heic", "mp4", "mov", "gif"]
        debugLog("[Library] Importing media files from folder: \(folderName)")

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            debugLog("[Library] Failed to enumerate folder contents")
            return
        }

        var importedCount = 0
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }

            let fileName = fileURL.lastPathComponent
            let destinationURL = wallpaperDirectory.appendingPathComponent(fileName)

            do {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.copyItem(at: fileURL, to: destinationURL)

                // 各ファイルにタグを保存
                if !tags.isEmpty {
                    saveTagsForFile(fileName: fileName, tags: tags)
                }

                importedCount += 1
            } catch {
                debugLog("[Library] Failed to import \(fileName): \(error)")
            }
        }

        debugLog("[Library] Imported \(importedCount) files from folder: \(folderName)")
        if importedCount > 0 {
            loadWallpapers()
        }
    }

    /// PKGファイルから壁紙を展開してインポート
    func importFromPkg(from url: URL, completion: @escaping (Result<[String], Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                // PKGファイルを読み込み
                let pkgReader = try PkgReader(path: url.path)

                // テクスチャファイルのリストを取得
                let textures = pkgReader.listTextures()
                debugLog("[Library] Found \(textures.count) textures in PKG")

                var importedFiles: [String] = []

                // 各テクスチャを展開
                for texInfo in textures {
                    guard let name = texInfo["name"] as? String else { continue }

                    do {
                        // テクスチャを画像として読み込み
                        let image = try pkgReader.readTextureAsImage(name: name)

                        // ファイル名を生成（.texを.pngに変更）
                        let baseName = (name as NSString).deletingPathExtension
                        let safeName = baseName
                            .replacingOccurrences(of: "/", with: "_")
                            .replacingOccurrences(of: "\\", with: "_")
                            .replacingOccurrences(of: "..", with: "_")
                        let fileName = "\(safeName).png"
                        let fileURL = self.wallpaperDirectory.appendingPathComponent(fileName)

                        // 画像を保存
                        try saveImage(image, to: fileURL, format: "png")
                        importedFiles.append(fileName)

                        let size = image.size
                        debugLog("[Library] Imported: \(fileName) (\(Int(size.width))x\(Int(size.height)))")
                    } catch {
                        debugLog("[Library] Failed to import \(name): \(error)")
                    }
                }

                // メインスレッドでリロード
                DispatchQueue.main.async {
                    self.loadWallpapers()
                    completion(.success(importedFiles))
                }

            } catch {
                debugLog("[Library] Failed to read PKG file: \(error)")
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    /// Wallpaper Engineシーンを適用（scene.pkgから最初のテクスチャを展開）
    func applyWallpaperEngineScene(folderName: String, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let folderURL = self.wallpaperDirectory.appendingPathComponent(folderName)
            let scenePkgURL = folderURL.appendingPathComponent("scene.pkg")

            // scene.pkgが存在するか確認
            guard self.fileManager.fileExists(atPath: scenePkgURL.path) else {
                let error = NSError(domain: "WallpaperLibrary", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "scene.pkg not found"])
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            do {
                // PKGファイルを読み込み
                let pkgReader = try PkgReader(path: scenePkgURL.path)
                let textures = pkgReader.listTextures()

                guard let firstTexture = textures.first,
                      let name = firstTexture["name"] as? String else {
                    throw NSError(domain: "WallpaperLibrary", code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "No textures found in scene.pkg"])
                }

                // 最初のテクスチャを画像として読み込み
                let image = try pkgReader.readTextureAsImage(name: name)

                // 一時ファイルとして保存（キャッシュディレクトリ）
                guard let cachesBase = self.fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
                    debugLog("[Library] キャッシュディレクトリが取得できません")
                    let error = NSError(domain: "WallpaperLibrary", code: 3,
                                      userInfo: [NSLocalizedDescriptionKey: "キャッシュディレクトリが取得できません"])
                    DispatchQueue.main.async { completion(.failure(error)) }
                    return
                }
                let cacheDir = cachesBase.appendingPathComponent("Artia")
                try self.fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)

                let baseName = (name as NSString).deletingPathExtension
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "\\", with: "_")
                    .replacingOccurrences(of: "..", with: "_")
                let imageURL = cacheDir.appendingPathComponent("\(folderName)_\(baseName).png")

                // 画像を保存
                try saveImage(image, to: imageURL, format: "png")

                debugLog("[Library] Applied scene texture: \(name)")

                DispatchQueue.main.async {
                    completion(.success(imageURL))
                }

            } catch {
                debugLog("[Library] Failed to apply scene: \(error)")
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    /// 壁紙を削除
    func deleteWallpaper(_ item: WallpaperItem) {
        do {
            // シェーダーの場合は削除対象から除外（組み込みシェーダーは削除できない）
            if item.type == .shader {
                // wallpapersリストから削除
                DispatchQueue.main.async {
                    self.wallpapers.removeAll { $0.id == item.id }
                    self.categories = Array(Set(self.wallpapers.map { $0.category })).sorted()
                }
                return
            }

            // 参照のみの Web ルート
            if item.type == .scene, let ext = item.externalRootPath, !ext.isEmpty {
                removeExternalWebWallpaperRoot(ext)
                loadWallpapers()
                return
            }

            // ライブラリ内のメディアフォルダ（1作品）
            if item.type == .mediaFolder, let folderName = item.folderName {
                let folderURL = wallpaperDirectory.appendingPathComponent(folderName)
                try fileManager.removeItem(at: folderURL)
                loadWallpapers()
                return
            }

            // Wallpaper Engineシーンの場合はフォルダごと削除
            if item.type == .scene, let folderName = item.folderName {
                let folderURL = wallpaperDirectory.appendingPathComponent(folderName)
                try fileManager.removeItem(at: folderURL)
                loadWallpapers()
                return
            }

            // 通常のファイルの場合
            if let fileName = item.fileName {
                let url = wallpaperDirectory.appendingPathComponent(fileName)
                try fileManager.removeItem(at: url)
                loadWallpapers()
            }
        } catch {
            debugLog("[Library] Failed to delete wallpaper: \(error)")
        }
    }

    /// 壁紙ディレクトリを開く
    func openWallpaperDirectory() {
        NSWorkspace.shared.open(wallpaperDirectory)
    }

    // MARK: - タグメタデータ管理

    /// タグメタデータをファイルから読み込み
    private func loadTagMetadata() {
        guard fileManager.fileExists(atPath: tagMetadataURL.path),
              let data = try? Data(contentsOf: tagMetadataURL),
              let metadata = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return }

        tagMetadata = metadata
        debugLog("[Library] Loaded tag metadata for \(metadata.count) files")
    }

    /// タグメタデータをファイルに保存
    private func saveTagMetadata() {
        do {
            let data = try JSONEncoder().encode(tagMetadata)
            try data.write(to: tagMetadataURL, options: .atomic)
            debugLog("[Library] Saved tag metadata for \(tagMetadata.count) files")
        } catch {
            debugLog("[Library] Failed to save tag metadata: \(error)")
        }
    }

    /// 特定のファイルにタグを保存
    func saveTagsForFile(fileName: String, tags: [String]) {
        tagMetadata[fileName] = tags
        saveTagMetadata()
    }

    /// 壁紙アイテムのタグを更新
    func updateTags(for item: WallpaperItem, tags: [String]) {
        let key = item.fileName ?? item.folderName ?? item.id
        tagMetadata[key] = tags
        saveTagMetadata()
        loadWallpapers()
    }

    /// 全壁紙から使用されている全タグを取得
    func getAllTags() -> [String] {
        return Array(Set(wallpapers.flatMap { $0.tags })).sorted()
    }

    // MARK: - コレクション管理

    /// コレクションをファイルから読み込み
    private func loadCollections() {
        guard fileManager.fileExists(atPath: collectionsURL.path),
              let data = try? Data(contentsOf: collectionsURL),
              let loaded = try? JSONDecoder().decode([WallpaperCollection].self, from: data)
        else {
            // 初回起動時: デフォルトの「お気に入り」コレクションを作成
            collections = [
                WallpaperCollection(
                    id: "favorites",
                    name: "お気に入り",
                    icon: "heart.fill",
                    isSystem: true
                )
            ]
            saveCollections()
            return
        }

        collections = loaded

        // 「お気に入り」コレクションが存在しない場合は追加
        if !collections.contains(where: { $0.id == "favorites" }) {
            collections.insert(
                WallpaperCollection(
                    id: "favorites",
                    name: "お気に入り",
                    icon: "heart.fill",
                    isSystem: true
                ),
                at: 0
            )
            saveCollections()
        }

        debugLog("[Library] Loaded \(collections.count) collections")
    }

    /// コレクションをファイルに保存
    private func saveCollections() {
        do {
            let data = try JSONEncoder().encode(collections)
            try data.write(to: collectionsURL, options: .atomic)
        } catch {
            debugLog("[Library] Failed to save collections: \(error)")
        }
    }

    /// お気に入りコレクション
    var favoritesCollection: WallpaperCollection {
        guard let favorites = collections.first(where: { $0.id == "favorites" }) else {
            debugLog("[Library] お気に入りコレクションが見つかりません。デフォルトを作成します")
            let defaultFavorites = WallpaperCollection(id: "favorites", name: "お気に入り", wallpaperIDs: [])
            collections.append(defaultFavorites)
            saveCollections()
            return defaultFavorites
        }
        return favorites
    }

    /// 壁紙がお気に入りかどうか
    func isFavorite(_ wallpaperID: String) -> Bool {
        collections.first(where: { $0.id == "favorites" })?.wallpaperIDs.contains(wallpaperID) ?? false
    }

    /// お気に入りをトグル
    func toggleFavorite(wallpaperID: String) {
        guard let index = collections.firstIndex(where: { $0.id == "favorites" }) else { return }
        if collections[index].wallpaperIDs.contains(wallpaperID) {
            collections[index].wallpaperIDs.removeAll { $0 == wallpaperID }
        } else {
            collections[index].wallpaperIDs.append(wallpaperID)
        }
        collections[index].modifiedAt = Date()
        saveCollections()
    }

    /// 新しいコレクションを作成
    @discardableResult
    func createCollection(name: String, icon: String = "folder") -> WallpaperCollection {
        let collection = WallpaperCollection(name: name, icon: icon)
        collections.append(collection)
        saveCollections()
        return collection
    }

    /// コレクションを削除（システムコレクションは削除不可）
    func deleteCollection(id: String) {
        guard let collection = collections.first(where: { $0.id == id }),
              !collection.isSystem else { return }
        collections.removeAll { $0.id == id }
        saveCollections()
    }

    /// コレクション名を変更
    func renameCollection(id: String, name: String) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[index].name = name
        collections[index].modifiedAt = Date()
        saveCollections()
    }

    /// コレクションのアイコンを変更
    func updateCollectionIcon(id: String, icon: String) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[index].icon = icon
        collections[index].modifiedAt = Date()
        saveCollections()
    }

    /// コレクションに壁紙を追加
    func addToCollection(wallpaperID: String, collectionID: String) {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        guard !collections[index].wallpaperIDs.contains(wallpaperID) else { return }
        collections[index].wallpaperIDs.append(wallpaperID)
        collections[index].modifiedAt = Date()
        saveCollections()
    }

    /// コレクションから壁紙を削除
    func removeFromCollection(wallpaperID: String, collectionID: String) {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        collections[index].wallpaperIDs.removeAll { $0 == wallpaperID }
        collections[index].modifiedAt = Date()
        saveCollections()
    }

    /// コレクションに壁紙が含まれているか
    func isInCollection(wallpaperID: String, collectionID: String) -> Bool {
        collections.first(where: { $0.id == collectionID })?.wallpaperIDs.contains(wallpaperID) ?? false
    }

    /// コレクション内の壁紙を取得
    func wallpapers(in collectionID: String) -> [WallpaperItem] {
        guard let collection = collections.first(where: { $0.id == collectionID }) else { return [] }
        return collection.wallpaperIDs.compactMap { id in
            wallpapers.first(where: { $0.id == id })
        }
    }

    // MARK: - プレビュー用ファクトリ

    #if DEBUG
    /// Xcodeプレビュー用インスタンス生成（サンプルデータ入り）
    static func previewInstance(wallpapers: [WallpaperItem]? = nil) -> WallpaperLibrary {
        let instance = WallpaperLibrary()
        if let wallpapers = wallpapers {
            instance.wallpapers = wallpapers
            instance.categories = Array(Set(wallpapers.map { $0.category })).sorted()
        }
        return instance
    }
    #endif
}
