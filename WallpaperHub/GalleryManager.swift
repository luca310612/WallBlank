import Foundation
import AppKit
import AVFoundation
#if canImport(FirebaseCore) && canImport(FirebaseFirestore) && canImport(FirebaseStorage) && canImport(FirebaseAuth)
import FirebaseCore
import FirebaseFirestore
import FirebaseStorage
import FirebaseAuth
#endif

/// オンラインギャラリー管理クラス（Firebase版）
#if canImport(FirebaseCore) && canImport(FirebaseFirestore) && canImport(FirebaseStorage) && canImport(FirebaseAuth)
class GalleryManager: ObservableObject {
    static let shared = GalleryManager()

    @Published var featuredWallpapers: [GalleryItem] = []
    @Published var communityWallpapers: [GalleryItem] = []
    @Published var categories: [String] = []
    @Published var isLoading: Bool = false
    @Published var downloadProgress: [String: Double] = [:]
    @Published var errorMessage: String?

    /// Firebaseが利用可能かどうか
    @Published var isFirebaseAvailable: Bool = false

    /// Firebase初期化済みかどうか
    private var isFirebaseConfigured: Bool {
        return FirebaseApp.app() != nil
    }

    private var db: Firestore { Firestore.firestore() }
    private var storage: Storage { Storage.storage() }

    private let fileManager = FileManager.default

    /// サムネイルキャッシュ（メモリ上・NSCacheで自動メモリ管理）
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private let cacheQueue = DispatchQueue(label: "com.artia.gallery.thumbnailCache")

    private var wallpaperDirectory: URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return fileManager.temporaryDirectory.appendingPathComponent("WallBlank/Wallpapers")
        }
        return appSupport.appendingPathComponent("WallBlank/Wallpapers")
    }

    /// Firestoreコレクション名
    private enum Collection {
        static let gallery = "gallery"
        static let community = "community"
        static let reports = "reports"
    }

    private init() {
        thumbnailCache.countLimit = 100
        thumbnailCache.totalCostLimit = 50 * 1024 * 1024 // 50MB
    }

    /// ファイル名に使用できない文字をサニタイズ
    private func sanitizeFileName(_ name: String) -> String {
        return name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "..", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\0", with: "")
    }

    /// データをクリア（サインアウト時）
    func clearData() {
        featuredWallpapers = []
        communityWallpapers = []
        categories = []
        downloadProgress = [:]
        errorMessage = nil
        isFirebaseAvailable = false
        thumbnailCache.removeAllObjects()
    }

    /// Firestoreのローカルキャッシュをクリア（ペンディング書き込みエラー解消用）
    func clearFirestoreCache() {
        let firestore = Firestore.firestore()
        firestore.clearPersistence { error in
            if let error = error {
                debugLog("[Gallery] キャッシュクリアエラー: \(error)")
            } else {
                debugLog("[Gallery] Firestoreキャッシュクリア完了")
            }
        }
    }

    /// Firebase接続を確認（実アカウントでのログイン必須）
    func checkFirebaseAvailability() async {
        // Firebase未設定の場合
        guard isFirebaseConfigured else {
            await MainActor.run {
                isFirebaseAvailable = false
                errorMessage = "ストア機能は現在利用できません（Firebase未設定）"
            }
            debugLog("[Gallery] Firebase未設定")
            return
        }

        // 実アカウントでサインイン済みか確認
        let isSignedIn = AuthManager.shared.isAuthenticated
        debugLog("[Gallery] Firebase設定済み, ログイン状態: \(isSignedIn), UID: \(AuthManager.shared.currentUID ?? "なし")")

        await MainActor.run {
            isFirebaseAvailable = isSignedIn
            if !isSignedIn {
                errorMessage = nil
            }
        }
    }

    // MARK: - フェッチ

    /// 注目の壁紙を取得
    func fetchFeatured() async {
        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }

        // Firebase利用可否を確認
        await checkFirebaseAvailability()
        guard isFirebaseAvailable else {
            debugLog("[Gallery] 注目取得スキップ: Firebase利用不可")
            await MainActor.run { isLoading = false }
            return
        }

        // Phase 2D: まず Rust 経路 (artia-firebase REST) を試行する。
        // Why: Firebase SDK 依存を段階的に Rust 実装へ寄せていくため。
        //      失敗 (未認証・ネットワーク失敗・未初期化等) はそのまま既存 SDK パスへ落ちる。
        if let rustItems = await tryFetchViaRust(collection: Collection.gallery, limit: 50),
           !rustItems.isEmpty {
            debugLog("[Gallery] Rust 経路で注目壁紙取得成功: \(rustItems.count)件")
            await MainActor.run {
                featuredWallpapers = rustItems.sorted { $0.downloadCount > $1.downloadCount }
                categories = Array(Set(rustItems.map { $0.category })).sorted()
                isLoading = false
            }
            return
        }

        // シンプルなクエリで確実に取得（インデックス不要）
        do {
            let snapshot = try await db.collection(Collection.gallery)
                .limit(to: 50)
                .getDocuments()

            debugLog("[Gallery] 注目の壁紙取得成功: \(snapshot.documents.count)件")

            let items = snapshot.documents.compactMap { doc -> GalleryItem? in
                return galleryItem(from: doc)
            }
            // クライアント側でダウンロード数降順ソート
            .sorted { $0.downloadCount > $1.downloadCount }

            await MainActor.run {
                featuredWallpapers = items
                categories = Array(Set(items.map { $0.category })).sorted()
                isLoading = false
            }
        } catch {
            debugLog("[Gallery] 注目の壁紙取得エラー: \(error)")
            await MainActor.run {
                isLoading = false
                errorMessage = "読み込みに失敗: \(error.localizedDescription)"
            }
        }
    }

    /// コミュニティ壁紙を取得
    func fetchCommunity(category: String? = nil) async {
        guard isFirebaseAvailable else {
            debugLog("[Gallery] コミュニティ取得スキップ: Firebase利用不可")
            return
        }
        await MainActor.run { isLoading = true }

        // Phase 2D: Rust 経路を試行 (失敗時は SDK へフォールバック)
        if let rustItems = await tryFetchViaRust(collection: Collection.community, limit: 100),
           !rustItems.isEmpty {
            debugLog("[Gallery] Rust 経路でコミュニティ取得成功: \(rustItems.count)件")
            await MainActor.run {
                communityWallpapers = rustItems.sorted { $0.createdAt > $1.createdAt }
                isLoading = false
            }
            return
        }

        // まずシンプルなクエリ（orderなし）で確実に取得を試みる
        // Firestoreインデックス未作成でもエラーにならない
        do {
            var query: Query = db.collection(Collection.community)

            if let category = category {
                query = query.whereField("category", isEqualTo: category)
            }

            let snapshot = try await query
                .limit(to: 100)
                .getDocuments()

            debugLog("[Gallery] コミュニティ取得成功: \(snapshot.documents.count)件")

            let items = snapshot.documents.compactMap { doc -> GalleryItem? in
                return galleryItem(from: doc)
            }
            // クライアント側で日付降順ソート
            .sorted { ($0.createdAt) > ($1.createdAt) }

            await MainActor.run {
                communityWallpapers = items
                isLoading = false
            }
        } catch {
            debugLog("[Gallery] コミュニティ取得エラー: \(error)")
            await MainActor.run {
                isLoading = false
                errorMessage = "コミュニティの読み込みに失敗: \(error.localizedDescription)"
            }
        }
    }

    /// ギャラリーを検索
    func search(query searchText: String) async -> [GalleryItem] {
        guard isFirebaseAvailable else { return [] }
        do {
            // Firestoreはフルテキスト検索をサポートしないため、プレフィックス検索を使用
            let end = searchText + "\u{f8ff}"
            let snapshot = try await db.collection(Collection.gallery)
                .whereField("isApproved", isEqualTo: true)
                .whereField("name", isGreaterThanOrEqualTo: searchText)
                .whereField("name", isLessThanOrEqualTo: end)
                .limit(to: 50)
                .getDocuments()

            return snapshot.documents.compactMap { doc -> GalleryItem? in
                return galleryItem(from: doc)
            }
        } catch {
            await MainActor.run {
                errorMessage = "検索に失敗: \(error.localizedDescription)"
            }
            return []
        }
    }

    // MARK: - ダウンロード

    /// 壁紙をダウンロード
    func downloadWallpaper(_ item: GalleryItem) async throws {
        await MainActor.run {
            downloadProgress[item.id] = 0.0
        }

        // Firebase StorageのURLまたは直接URLからダウンロード
        let downloadURL: URL
        if item.fileURLString.hasPrefix("gs://") {
            // Firebase Storage参照の場合
            let ref = storage.reference(forURL: item.fileURLString)
            downloadURL = try await ref.downloadURL()
        } else if let url = URL(string: item.fileURLString) {
            downloadURL = url
        } else {
            throw GalleryError.invalidURL
        }

        // ダウンロード
        let (tempURL, _) = try await URLSession.shared.download(from: downloadURL)

        // 壁紙ディレクトリにコピー
        // Firebase StorageのURLにはクエリパラメータが含まれるため、
        // pathExtensionではなくGalleryItemのtypeから拡張子を決定する
        let ext: String
        if let storedExt = item.fileExtension, !storedExt.isEmpty {
            ext = storedExt
        } else {
            switch item.type {
            case .video: ext = "mp4"
            case .gif: ext = "gif"
            case .image: ext = "png"
            case .shader, .scene, .mediaFolder: ext = "png"
            }
        }
        let safeName = sanitizeFileName(item.name)
        let fileName = "\(safeName)_\(item.id.prefix(8)).\(ext)"
        let destDir = wallpaperDirectory
        try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
        let destinationURL = destDir.appendingPathComponent(fileName)

        // パストラバーサル防止: 最終パスがディレクトリ内に収まることを確認
        guard destinationURL.standardizedFileURL.path.hasPrefix(destDir.standardizedFileURL.path) else {
            throw GalleryError.invalidURL
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: tempURL, to: destinationURL)

        // ダウンロード数を更新
        await incrementDownloadCount(itemID: item.id)

        // ライブラリに追加
        await MainActor.run {
            downloadProgress.removeValue(forKey: item.id)
            let library = WallpaperLibrary.shared
            library.saveTagsForFile(fileName: fileName, tags: item.tags + ["ストア"])
            library.loadWallpapers()
        }
    }

    // MARK: - コミュニティ投稿

    /// 壁紙を投稿（ログイン必須）
    func submitWallpaper(name: String, category: String, tags: [String], fileURL: URL) async throws {
        guard isFirebaseAvailable else { throw GalleryError.firebaseUnavailable }
        guard AuthManager.shared.isAuthenticated else { throw GalleryError.loginRequired }

        // ファイルの存在確認
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw GalleryError.fileNotFound
        }

        // ファイルサイズを事前チェック
        let attrs = try fileManager.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0
        let maxSize: Int64 = 500 * 1024 * 1024  // 500MB（Firebase Storageルール準拠）
        guard fileSize > 0 else { throw GalleryError.fileNotFound }
        guard fileSize <= maxSize else { throw GalleryError.fileTooLarge }

        // 投稿者情報をAuthManagerから取得（アップロード前にUID必要）
        guard let profile = AuthManager.shared.currentProfile else {
            throw GalleryError.loginRequired
        }
        let authorName = profile.displayName
        let authorID = profile.uid

        // ファイルタイプを判定
        let ext = fileURL.pathExtension.lowercased()
        let wallpaperType: String
        switch ext {
        case "mp4", "mov", "m4v":
            wallpaperType = "video"
        case "gif":
            wallpaperType = "gif"
        default:
            wallpaperType = "image"
        }

        // Firebase Storageにファイルをアップロード（パス: community/{uid}/{filename}）
        let fileName = "\(UUID().uuidString)_\(fileURL.lastPathComponent)"
        let storageRef = storage.reference().child("community/\(authorID)/\(fileName)")

        // メタデータを設定
        let metadata = StorageMetadata()
        switch ext {
        case "mp4": metadata.contentType = "video/mp4"
        case "mov": metadata.contentType = "video/quicktime"
        case "m4v": metadata.contentType = "video/x-m4v"
        case "gif": metadata.contentType = "image/gif"
        case "png": metadata.contentType = "image/png"
        case "jpg", "jpeg": metadata.contentType = "image/jpeg"
        case "heic": metadata.contentType = "image/heic"
        default: metadata.contentType = "application/octet-stream"
        }

        // アップロード実行（リトライあり）
        var uploadSuccess = false
        var lastError: Error?
        let maxRetries = 3

        for attempt in 1...maxRetries {
            do {
                let resultMetadata = try await storageRef.putFileAsync(from: fileURL, metadata: metadata)
                // アップロード完了を確認
                if resultMetadata.size > 0 {
                    uploadSuccess = true
                    debugLog("[Gallery] アップロード完了（試行 \(attempt)回目）: \(resultMetadata.size) バイト")
                    break
                }
            } catch {
                lastError = error
                debugLog("[Gallery] アップロード失敗（試行 \(attempt)/\(maxRetries)）: \(error.localizedDescription)")
                if attempt < maxRetries {
                    // リトライ前に少し待機
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                }
            }
        }

        guard uploadSuccess else {
            throw GalleryError.uploadFailed(lastError)
        }

        // ダウンロードURLを取得（gs://パスをフォールバックとして使用）
        var fileURLString: String
        do {
            // まず通常のダウンロードURL取得を試みる
            try await Task.sleep(nanoseconds: 1_000_000_000)  // 1秒待機
            let downloadURL = try await storageRef.downloadURL()
            fileURLString = downloadURL.absoluteString
            debugLog("[Gallery] ダウンロードURL取得成功: \(fileURLString)")
        } catch {
            // downloadURL()が失敗した場合、gs://パスで保存（ダウンロード時に解決される）
            let bucket = storage.reference().bucket
            fileURLString = "gs://\(bucket)/community/\(authorID)/\(fileName)"
            debugLog("[Gallery] gs://パスで保存: \(fileURLString)（downloadURL取得失敗: \(error.localizedDescription)）")
        }

        // 動画/GIFの場合、最初のフレームをサムネイルとしてアップロード
        var thumbnailURLString = fileURLString
        if wallpaperType == "video" || wallpaperType == "gif" {
            let thumbData: Data?
            if wallpaperType == "video" {
                thumbData = generateThumbnailData(from: fileURL)
            } else {
                thumbData = generateGIFThumbnailData(from: fileURL)
            }

            if let thumbData = thumbData {
                let thumbFileName = "thumb_\(UUID().uuidString).jpg"
                let thumbRef = storage.reference().child("community/\(authorID)/thumbnails/\(thumbFileName)")
                let thumbMetadata = StorageMetadata()
                thumbMetadata.contentType = "image/jpeg"

                do {
                    _ = try await thumbRef.putDataAsync(thumbData, metadata: thumbMetadata)
                    try await Task.sleep(nanoseconds: 500_000_000)
                    let thumbDownloadURL = try await thumbRef.downloadURL()
                    thumbnailURLString = thumbDownloadURL.absoluteString
                    debugLog("[Gallery] サムネイルアップロード完了: \(thumbnailURLString)")
                } catch {
                    // サムネイルアップロード失敗時はファイルURLをそのまま使用
                    let bucket = storage.reference().bucket
                    thumbnailURLString = "gs://\(bucket)/community/\(authorID)/thumbnails/\(thumbFileName)"
                    debugLog("[Gallery] サムネイルgs://パスで保存: \(thumbnailURLString)（エラー: \(error.localizedDescription)）")
                }
            }
        }

        // Firestoreにドキュメントを追加
        // ownerId: セキュリティルールで所有者確認に使用（必須）
        let data: [String: Any] = [
            "name": name,
            "category": category,
            "tags": tags,
            "isApproved": false,
            "downloadCount": 0,
            "likeCount": 0,
            "fileSize": fileSize,
            "fileURLString": fileURLString,
            "thumbnailURLString": thumbnailURLString,
            "type": wallpaperType,
            "fileExtension": ext,
            "authorName": authorName,
            "authorID": authorID,
            "ownerId": authorID,
            "width": 1920,
            "height": 1080,
            "createdAt": FieldValue.serverTimestamp()
        ]

        debugLog("[Gallery] 投稿データ: ownerId=\(authorID), uid=\(AuthManager.shared.currentUID ?? "nil")")
        do {
            try await db.collection(Collection.community).addDocument(data: data)
            debugLog("[Gallery] 壁紙を投稿しました: \(name)")
        } catch {
            debugLog("[Gallery] Firestore書き込みエラー: \(error)")
            throw error
        }
    }

    /// 壁紙を報告（ログイン必須）
    func reportWallpaper(id: String, reason: String) async throws {
        guard isFirebaseAvailable else { throw GalleryError.firebaseUnavailable }
        guard AuthManager.shared.isAuthenticated,
              let uid = AuthManager.shared.currentUID else {
            throw GalleryError.loginRequired
        }

        let data: [String: Any] = [
            "wallpaperID": id,
            "reason": reason,
            "reportedAt": FieldValue.serverTimestamp(),
            "reporterID": uid,
            "reporterId": uid
        ]

        try await db.collection(Collection.reports).addDocument(data: data)
    }

    /// 壁紙にいいね（ログイン必須・ユーザーごとに1回のみ）
    func likeWallpaper(id: String) async throws {
        guard isFirebaseAvailable else { throw GalleryError.firebaseUnavailable }
        guard AuthManager.shared.isAuthenticated,
              let uid = AuthManager.shared.currentUID else {
            throw GalleryError.loginRequired
        }

        // galleryとcommunity両方で検索し、該当するドキュメントを更新
        let galleryRef = db.collection(Collection.gallery).document(id)
        let communityRef = db.collection(Collection.community).document(id)

        // いいね済みチェック（ユーザーごとのサブコレクション）
        let galleryDoc = try await galleryRef.getDocument()
        let targetRef: DocumentReference
        if galleryDoc.exists {
            targetRef = galleryRef
        } else {
            targetRef = communityRef
        }

        // ユーザーが既にいいね済みかチェック
        let likeDoc = try await targetRef.collection("likes").document(uid).getDocument()
        guard !likeDoc.exists else { return } // 既にいいね済み

        // いいねを記録
        try await targetRef.collection("likes").document(uid).setData([
            "likedAt": FieldValue.serverTimestamp()
        ])
        try await targetRef.updateData([
            "likeCount": FieldValue.increment(Int64(1))
        ])
    }

    // MARK: - サムネイル

    /// サムネイルをキャッシュから取得（同期）
    func getCachedThumbnail(for itemID: String) -> NSImage? {
        return thumbnailCache.object(forKey: itemID as NSString)
    }

    /// サムネイルを非同期で読み込み（URL→画像、動画の場合は最初のフレーム抽出）
    /// SwiftUIの.taskキャンセルに影響されないよう、内部で独立したTaskを使用
    func loadThumbnail(for item: GalleryItem) async -> NSImage? {
        // キャッシュにあればそのまま返す
        if let cached = thumbnailCache.object(forKey: item.id as NSString) {
            return cached
        }

        let urlString = item.thumbnailURLString
        guard !urlString.isEmpty else { return nil }

        // キャンセル耐性のある独立Taskで実行（.taskのキャンセルに巻き込まれない）
        let image: NSImage? = await Task.detached { [weak self] in
            guard let self = self else { return nil as NSImage? }

            // gs://パスの場合はダウンロードURLに変換
            let resolvedURL: URL?
            if urlString.hasPrefix("gs://") {
                do {
                    let ref = self.storage.reference(forURL: urlString)
                    resolvedURL = try await ref.downloadURL()
                } catch {
                    debugLog("[Gallery] サムネイルURL変換エラー: \(error.localizedDescription)")
                    return nil
                }
            } else {
                resolvedURL = URL(string: urlString)
            }

            guard let downloadURL = resolvedURL else { return nil }

            // URLのコンテンツタイプで分岐
            if item.type == .video && item.thumbnailURLString == item.fileURLString {
                return await self.extractFirstFrame(from: downloadURL)
            } else {
                return await self.downloadImage(from: downloadURL)
            }
        }.value

        // キャッシュに保存
        if let image = image {
            thumbnailCache.setObject(image, forKey: item.id as NSString)
        }

        return image
    }

    /// URLから画像をダウンロード（Taskキャンセルの影響を受けないよう detached で実行）
    private func downloadImage(from url: URL) async -> NSImage? {
        // SwiftUIの.taskキャンセルに巻き込まれないよう、独立したTaskで実行
        let result: NSImage? = await withCheckedContinuation { continuation in
            let task = URLSession.shared.dataTask(with: url) { data, _, error in
                if let data = data, let image = NSImage(data: data) {
                    continuation.resume(returning: image)
                } else {
                    if let error = error {
                        debugLog("[Gallery] サムネイル画像ダウンロードエラー: \(error.localizedDescription)")
                    }
                    continuation.resume(returning: nil)
                }
            }
            task.resume()
        }
        return result
    }

    /// 動画URLから最初のフレームを抽出
    private func extractFirstFrame(from url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 400, height: 300)

        do {
            let (cgImage, _) = try await imageGenerator.image(at: .zero)
            let size = NSSize(width: cgImage.width, height: cgImage.height)
            return NSImage(cgImage: cgImage, size: size)
        } catch {
            debugLog("[Gallery] 動画フレーム抽出エラー: \(error.localizedDescription)")
            return nil
        }
    }

    /// ローカル動画ファイルからサムネイル（JPEG）を生成
    private func generateThumbnailData(from fileURL: URL) -> Data? {
        let asset = AVURLAsset(url: fileURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 800, height: 600)

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?

        imageGenerator.generateCGImageAsynchronously(for: .zero) { cgImage, _, error in
            if let cgImage = cgImage {
                let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
                resultData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
            } else if let error = error {
                debugLog("[Gallery] サムネイル生成エラー: \(error.localizedDescription)")
            }
            semaphore.signal()
        }
        semaphore.wait()
        return resultData
    }

    /// ローカルGIFファイルから最初のフレームをJPEGとして抽出
    private func generateGIFThumbnailData(from fileURL: URL) -> Data? {
        guard let image = NSImage(contentsOf: fileURL) else { return nil }
        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    // MARK: - 内部ヘルパー

    /// FirestoreドキュメントからGalleryItemに変換
    private func galleryItem(from doc: DocumentSnapshot) -> GalleryItem? {
        guard let data = doc.data(),
              let name = data["name"] as? String else { return nil }

        let typeString = data["type"] as? String ?? "image"
        let wallpaperType = WallpaperType(rawValue: typeString) ?? .image

        let thumbnailURL = data["thumbnailURLString"] as? String ?? ""
        let fileURL = data["fileURLString"] as? String ?? ""

        // ダウンロード済みかチェック（サニタイズ済みファイル名で検索）
        let safeName = sanitizeFileName(name)
        let downloadedFileBase = "\(safeName)_\(doc.documentID.prefix(8))"
        let supportedExtensions = ["png", "jpg", "jpeg", "mp4", "mov", "gif", "heic", "webp", "m4v"]
        let isDownloaded = supportedExtensions.contains { ext in
            fileManager.fileExists(
                atPath: wallpaperDirectory.appendingPathComponent("\(downloadedFileBase).\(ext)").path
            )
        }

        // createdAtの取得（Firestore Timestamp → Date）
        let createdAt: Date
        if let timestamp = data["createdAt"] as? Timestamp {
            createdAt = timestamp.dateValue()
        } else {
            createdAt = Date()
        }

        return GalleryItem(
            id: doc.documentID,
            name: name,
            type: wallpaperType,
            category: data["category"] as? String ?? "General",
            tags: data["tags"] as? [String] ?? [],
            authorName: data["authorName"] as? String ?? "不明",
            authorID: data["authorID"] as? String ?? "",
            thumbnailURLString: thumbnailURL,
            fileURLString: fileURL,
            fileSize: data["fileSize"] as? Int64 ?? 0,
            width: data["width"] as? Int ?? 1920,
            height: data["height"] as? Int ?? 1080,
            downloadCount: data["downloadCount"] as? Int ?? 0,
            likeCount: data["likeCount"] as? Int ?? 0,
            createdAt: createdAt,
            isApproved: data["isApproved"] as? Bool ?? false,
            isDownloaded: isDownloaded,
            fileExtension: data["fileExtension"] as? String
        )
    }

    /// ダウンロード数をインクリメント
    private func incrementDownloadCount(itemID: String) async {
        do {
            // galleryコレクションで試す
            let galleryRef = db.collection(Collection.gallery).document(itemID)
            let doc = try await galleryRef.getDocument()
            if doc.exists {
                try await galleryRef.updateData([
                    "downloadCount": FieldValue.increment(Int64(1))
                ])
            } else {
                // communityコレクションで試す
                try await db.collection(Collection.community).document(itemID).updateData([
                    "downloadCount": FieldValue.increment(Int64(1))
                ])
            }
        } catch {
            debugLog("[Gallery] Failed to increment download count: \(error)")
        }
    }

    // MARK: - 管理者機能

    /// 未承認の壁紙を取得（管理者用）
    func fetchPendingWallpapers() async -> [GalleryItem] {
        guard isFirebaseAvailable, AuthManager.shared.isAdminMode else { return [] }

        do {
            let snapshot = try await db.collection(Collection.community)
                .whereField("isApproved", isEqualTo: false)
                .order(by: "createdAt", descending: true)
                .getDocuments()

            return snapshot.documents.compactMap { galleryItem(from: $0) }
        } catch {
            // インデックスエラー時のフォールバック
            do {
                let snapshot = try await db.collection(Collection.community)
                    .getDocuments()

                return snapshot.documents.compactMap { doc -> GalleryItem? in
                    guard let item = galleryItem(from: doc), !item.isApproved else { return nil }
                    return item
                }
            } catch {
                debugLog("[Gallery] 未承認壁紙取得エラー: \(error)")
                return []
            }
        }
    }

    /// 壁紙を承認（管理者用）
    func approveWallpaper(id: String) async throws {
        guard AuthManager.shared.isAdminMode else { throw GalleryError.loginRequired }

        try await db.collection(Collection.community).document(id).updateData([
            "isApproved": true
        ])
        debugLog("[Gallery] 壁紙を承認: \(id)")
    }

    /// 壁紙を注目に昇格（管理者用：communityからgalleryへコピー）
    func promoteToFeatured(id: String) async throws {
        guard AuthManager.shared.isAdminMode else { throw GalleryError.loginRequired }

        let doc = try await db.collection(Collection.community).document(id).getDocument()
        guard var data = doc.data() else { return }

        // 承認済みにして注目コレクションにコピー
        data["isApproved"] = true
        try await db.collection(Collection.gallery).document(id).setData(data)

        // 元のコミュニティドキュメントも承認済みに更新
        try await db.collection(Collection.community).document(id).updateData([
            "isApproved": true
        ])

        debugLog("[Gallery] 壁紙を注目に昇格: \(id)")
    }

    /// 壁紙を注目から解除（管理者用）
    func demoteFromFeatured(id: String) async throws {
        guard AuthManager.shared.isAdminMode else { throw GalleryError.loginRequired }

        try await db.collection(Collection.gallery).document(id).delete()
        debugLog("[Gallery] 壁紙を注目から解除: \(id)")
    }

    /// 壁紙を削除（管理者用：ストレージとFirestoreの両方から削除）
    func deleteWallpaper(id: String) async throws {
        guard AuthManager.shared.isAdminMode else { throw GalleryError.loginRequired }

        // communityコレクションから削除
        let communityDoc = try await db.collection(Collection.community).document(id).getDocument()
        if let data = communityDoc.data(),
           let fileURL = data["fileURLString"] as? String, fileURL.hasPrefix("gs://") {
            // Firebase Storageからファイルを削除
            do {
                let ref = storage.reference(forURL: fileURL)
                try await ref.delete()
            } catch {
                debugLog("[Gallery] ストレージファイル削除エラー: \(error)")
            }

            // サムネイルも削除
            if let thumbURL = data["thumbnailURLString"] as? String,
               thumbURL.hasPrefix("gs://"), thumbURL != fileURL {
                do {
                    let thumbRef = storage.reference(forURL: thumbURL)
                    try await thumbRef.delete()
                } catch {
                    debugLog("[Gallery] サムネイル削除エラー: \(error)")
                }
            }
        }

        try await db.collection(Collection.community).document(id).delete()

        // galleryコレクションにもある場合は削除
        let galleryDoc = try await db.collection(Collection.gallery).document(id).getDocument()
        if galleryDoc.exists {
            try await db.collection(Collection.gallery).document(id).delete()
        }

        debugLog("[Gallery] 壁紙を削除: \(id)")
    }

    /// 報告一覧を取得（管理者用）
    func fetchReports() async -> [(id: String, wallpaperID: String, reason: String, reporterID: String, reportedAt: Date)] {
        guard isFirebaseAvailable, AuthManager.shared.isAdminMode else { return [] }

        do {
            let snapshot = try await db.collection(Collection.reports)
                .order(by: "reportedAt", descending: true)
                .limit(to: 100)
                .getDocuments()

            return snapshot.documents.compactMap { doc -> (id: String, wallpaperID: String, reason: String, reporterID: String, reportedAt: Date)? in
                let data = doc.data()
                guard let wallpaperID = data["wallpaperID"] as? String else { return nil }
                let reason = data["reason"] as? String ?? "不明"
                let reporterID = data["reporterID"] as? String ?? ""
                let reportedAt = (data["reportedAt"] as? Timestamp)?.dateValue() ?? Date()
                return (id: doc.documentID, wallpaperID: wallpaperID, reason: reason, reporterID: reporterID, reportedAt: reportedAt)
            }
        } catch {
            // インデックスエラー時のフォールバック
            do {
                let snapshot = try await db.collection(Collection.reports)
                    .limit(to: 100)
                    .getDocuments()

                return snapshot.documents.compactMap { doc -> (id: String, wallpaperID: String, reason: String, reporterID: String, reportedAt: Date)? in
                    let data = doc.data()
                    guard let wallpaperID = data["wallpaperID"] as? String else { return nil }
                    let reason = data["reason"] as? String ?? "不明"
                    let reporterID = data["reporterID"] as? String ?? ""
                    let reportedAt = (data["reportedAt"] as? Timestamp)?.dateValue() ?? Date()
                    return (id: doc.documentID, wallpaperID: wallpaperID, reason: reason, reporterID: reporterID, reportedAt: reportedAt)
                }
            } catch {
                debugLog("[Gallery] 報告一覧取得エラー: \(error)")
                return []
            }
        }
    }

    /// 報告を処理済みにする（管理者用）
    func dismissReport(id: String) async throws {
        guard AuthManager.shared.isAdminMode else { throw GalleryError.loginRequired }

        try await db.collection(Collection.reports).document(id).delete()
        debugLog("[Gallery] 報告を処理済み: \(id)")
    }

    /// すべてのユーザーを取得（管理者用）
    func fetchAllUsers() async -> [UserProfile] {
        guard isFirebaseAvailable, AuthManager.shared.isAdminMode else { return [] }

        do {
            let snapshot = try await db.collection("users")
                .limit(to: 200)
                .getDocuments()

            return snapshot.documents.compactMap { doc -> UserProfile? in
                let data = doc.data()
                return UserProfile(
                    uid: doc.documentID,
                    displayName: data["displayName"] as? String ?? "ユーザー",
                    email: data["email"] as? String,
                    photoURL: data["photoURL"] as? String,
                    authProvider: UserProfile.AuthProvider(rawValue: data["authProvider"] as? String ?? "email") ?? .email,
                    createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
                    lastSyncAt: (data["lastSyncAt"] as? Timestamp)?.dateValue(),
                    isAdmin: data["isAdmin"] as? Bool ?? false
                )
            }
        } catch {
            debugLog("[Gallery] ユーザー一覧取得エラー: \(error)")
            return []
        }
    }

    // MARK: - エラー

    // MARK: - プレビュー用ファクトリ

    #if DEBUG
    /// Xcodeプレビュー用インスタンス生成（Firebase依存なし）
    static func previewInstance(
        featured: [GalleryItem] = [],
        community: [GalleryItem] = [],
        isLoading: Bool = false,
        errorMessage: String? = nil,
        isFirebaseAvailable: Bool = true
    ) -> GalleryManager {
        let instance = GalleryManager()
        instance.featuredWallpapers = featured
        instance.communityWallpapers = community
        instance.isLoading = isLoading
        instance.errorMessage = errorMessage
        instance.isFirebaseAvailable = isFirebaseAvailable
        return instance
    }
    #endif

    // MARK: - エラー

    enum GalleryError: LocalizedError {
        case invalidURL
        case downloadFailed
        case firebaseUnavailable
        case loginRequired
        case fileNotFound
        case fileTooLarge
        case uploadFailed(Error?)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "無効なURLです"
            case .downloadFailed:
                return "ダウンロードに失敗しました"
            case .firebaseUnavailable:
                return "サーバーに接続できません。インターネット接続を確認してください。"
            case .loginRequired:
                return "この機能を使うにはログインが必要です"
            case .fileNotFound:
                return "選択されたファイルが見つかりません。壁紙が移動または削除されていないか確認してください。"
            case .fileTooLarge:
                return "ファイルサイズが大きすぎます（上限: 20MB）。ファイルを圧縮してから再度お試しください。"
            case .uploadFailed(let underlying):
                if let err = underlying {
                    return "アップロードに失敗しました。ネットワーク接続を確認して再度お試しください。\n（詳細: \(err.localizedDescription)）"
                }
                return "アップロードに失敗しました。ネットワーク接続を確認して再度お試しください。"
            }
        }
    }
}

// MARK: - Phase 2D: Rust 経路 (artia-firebase) 統合
// Why: Firebase SDK 直接利用箇所を段階的に Rust 実装へ寄せていくため、
//      Firestore 一覧取得を Rust 経路で先に試し、失敗時は既存 SDK パスへ落とす。

extension GalleryManager {

    /// Rust 経路 (artia-firebase) でコレクションを取得して GalleryItem 配列に変換する。
    /// 認証未確立・ネットワーク失敗・未初期化など何かしらでこけたら nil を返し、呼び出し元は SDK パスへ落ちる。
    fileprivate func tryFetchViaRust(collection: String, limit: Int) async -> [GalleryItem]? {
        guard RustFirebase.isInitialized else { return nil }
        // RustFirebase は AuthClient の id_token を Bearer に流用するため、
        // Rust 側で認証セッションが立っていない限り使えない。
        // 現在は AuthManager (SDK 側) と Rust の認証が分離しているので
        // 実運用では失敗してフォールバックする想定。整備は後続フェーズで実施。
        do {
            let query: [String: Any] = [
                "from": [["collectionId": collection]],
                "limit": limit
            ]
            let docs = try await RustFirebase.Firestore.query(parent: "", query: query)
            let items = docs.compactMap { rustDocToGalleryItem($0) }
            return items
        } catch {
            debugLog("[Gallery] Rust 経路 (\(collection)) 失敗: \(error.localizedDescription)")
            return nil
        }
    }

    /// `RustFirebase.FirestoreDocument` の Tagged JSON 表現を `GalleryItem` に変換する。
    fileprivate func rustDocToGalleryItem(_ doc: RustFirebase.FirestoreDocument) -> GalleryItem? {
        // ドキュメント名から最後のセグメントを ID として取り出す
        guard let docID = doc.name.split(separator: "/").map(String.init).last else { return nil }
        let f = doc.fields
        guard let name = unwrapString(f["name"]) else { return nil }
        let typeString = unwrapString(f["type"]) ?? "image"
        let wallpaperType = WallpaperType(rawValue: typeString) ?? .image

        // タグは arrayValue 配下に values: [stringValue: ...] が並ぶ
        let tags: [String]
        if let arrDict = f["tags"] as? [String: Any],
           let arrayValue = arrDict["arrayValue"] as? [String: Any],
           let values = arrayValue["values"] as? [[String: Any]] {
            tags = values.compactMap { $0["stringValue"] as? String }
        } else {
            tags = []
        }

        return GalleryItem(
            id: docID,
            name: name,
            type: wallpaperType,
            category: unwrapString(f["category"]) ?? "General",
            tags: tags,
            authorName: unwrapString(f["authorName"]) ?? "不明",
            authorID: unwrapString(f["authorID"]) ?? "",
            thumbnailURLString: unwrapString(f["thumbnailURLString"]) ?? "",
            fileURLString: unwrapString(f["fileURLString"]) ?? "",
            fileSize: Int64(unwrapInt(f["fileSize"]) ?? 0),
            width: unwrapInt(f["width"]) ?? 1920,
            height: unwrapInt(f["height"]) ?? 1080,
            downloadCount: unwrapInt(f["downloadCount"]) ?? 0,
            likeCount: unwrapInt(f["likeCount"]) ?? 0,
            createdAt: Date(),
            isApproved: unwrapBool(f["isApproved"]) ?? false,
            isDownloaded: false,
            fileExtension: unwrapString(f["fileExtension"])
        )
    }

    private func unwrapString(_ value: Any?) -> String? {
        (value as? [String: Any])?["stringValue"] as? String
    }

    private func unwrapInt(_ value: Any?) -> Int? {
        guard let s = (value as? [String: Any])?["integerValue"] as? String else { return nil }
        return Int(s)
    }

    private func unwrapBool(_ value: Any?) -> Bool? {
        (value as? [String: Any])?["booleanValue"] as? Bool
    }
}
#else
class GalleryManager: ObservableObject {
    static let shared = GalleryManager()

    @Published var featuredWallpapers: [GalleryItem] = []
    @Published var communityWallpapers: [GalleryItem] = []
    @Published var categories: [String] = []
    @Published var isLoading: Bool = false
    @Published var downloadProgress: [String: Double] = [:]
    @Published var errorMessage: String?
    @Published var isFirebaseAvailable: Bool = false

    private init() {}

    func clearData() {
        featuredWallpapers = []
        communityWallpapers = []
        categories = []
        downloadProgress = [:]
        errorMessage = nil
        isFirebaseAvailable = false
    }

    func clearFirestoreCache() {}

    func checkFirebaseAvailability() async {
        await MainActor.run {
            isFirebaseAvailable = false
            errorMessage = "Firebase SDK が未解決のため、ストア機能は利用できません。"
        }
    }

    func fetchFeatured() async {
        await checkFirebaseAvailability()
        await MainActor.run {
            featuredWallpapers = []
            isLoading = false
        }
    }

    func fetchCommunity(category: String? = nil) async {
        await checkFirebaseAvailability()
        await MainActor.run {
            communityWallpapers = []
            isLoading = false
        }
    }

    func search(query searchText: String) async -> [GalleryItem] { [] }
    func downloadWallpaper(_ item: GalleryItem) async throws { throw GalleryError.firebaseUnavailable }
    func submitWallpaper(name: String, category: String, tags: [String], fileURL: URL) async throws { throw GalleryError.firebaseUnavailable }
    func reportWallpaper(id: String, reason: String) async throws { throw GalleryError.firebaseUnavailable }
    func likeWallpaper(id: String) async throws { throw GalleryError.firebaseUnavailable }
    func getCachedThumbnail(for itemID: String) -> NSImage? { nil }
    func loadThumbnail(for item: GalleryItem) async -> NSImage? { nil }
    func fetchPendingWallpapers() async -> [GalleryItem] { [] }
    func approveWallpaper(id: String) async throws { throw GalleryError.firebaseUnavailable }
    func promoteToFeatured(id: String) async throws { throw GalleryError.firebaseUnavailable }
    func demoteFromFeatured(id: String) async throws { throw GalleryError.firebaseUnavailable }
    func deleteWallpaper(id: String) async throws { throw GalleryError.firebaseUnavailable }

    func fetchReports() async -> [(id: String, wallpaperID: String, reason: String, reporterID: String, reportedAt: Date)] { [] }
    func dismissReport(id: String) async throws { throw GalleryError.firebaseUnavailable }
    func fetchAllUsers() async -> [UserProfile] { [] }

    #if DEBUG
    static func previewInstance(
        featured: [GalleryItem] = [],
        community: [GalleryItem] = [],
        isLoading: Bool = false,
        errorMessage: String? = nil,
        isFirebaseAvailable: Bool = true
    ) -> GalleryManager {
        let instance = GalleryManager()
        instance.featuredWallpapers = featured
        instance.communityWallpapers = community
        instance.isLoading = isLoading
        instance.errorMessage = errorMessage
        instance.isFirebaseAvailable = isFirebaseAvailable
        return instance
    }
    #endif

    enum GalleryError: LocalizedError {
        case invalidURL
        case downloadFailed
        case firebaseUnavailable
        case loginRequired
        case fileNotFound
        case fileTooLarge
        case uploadFailed(Error?)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "無効なURLです"
            case .downloadFailed:
                return "ダウンロードに失敗しました"
            case .firebaseUnavailable:
                return "Firebase SDK が未解決のため、ストア機能は利用できません。"
            case .loginRequired:
                return "この機能を使うにはログインが必要です"
            case .fileNotFound:
                return "選択されたファイルが見つかりません。壁紙が移動または削除されていないか確認してください。"
            case .fileTooLarge:
                return "ファイルサイズが大きすぎます（上限: 20MB）。ファイルを圧縮してから再度お試しください。"
            case .uploadFailed(let underlying):
                if let err = underlying {
                    return "アップロードに失敗しました。\n（詳細: \(err.localizedDescription)）"
                }
                return "アップロードに失敗しました。"
            }
        }
    }
}
#endif
