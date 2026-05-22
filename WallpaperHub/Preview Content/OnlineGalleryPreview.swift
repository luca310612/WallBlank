#if DEBUG
import SwiftUI

// MARK: - プレビュー用サンプルデータ

enum GalleryPreviewData {
    static let sampleItems: [GalleryItem] = [
        GalleryItem(
            id: "preview-1",
            name: "夕焼けの山並み",
            type: .image,
            category: "Nature",
            tags: ["風景", "夕焼け", "山"],
            authorName: "田中太郎",
            authorID: "author-1",
            thumbnailURLString: "",
            fileURLString: "",
            fileSize: 2_500_000,
            width: 3840,
            height: 2160,
            downloadCount: 128,
            likeCount: 45,
            createdAt: Date(),
            isApproved: true,
            isDownloaded: false
        ),
        GalleryItem(
            id: "preview-2",
            name: "サイバーパンクシティ",
            type: .image,
            category: "Abstract",
            tags: ["サイバーパンク", "都市", "ネオン"],
            authorName: "鈴木花子",
            authorID: "author-2",
            thumbnailURLString: "",
            fileURLString: "",
            fileSize: 4_200_000,
            width: 2560,
            height: 1440,
            downloadCount: 256,
            likeCount: 89,
            createdAt: Date().addingTimeInterval(-86400),
            isApproved: true,
            isDownloaded: true
        ),
        GalleryItem(
            id: "preview-3",
            name: "波のアニメーション",
            type: .video,
            category: "Nature",
            tags: ["海", "波", "動画"],
            authorName: "佐藤次郎",
            authorID: "author-3",
            thumbnailURLString: "",
            fileURLString: "",
            fileSize: 15_000_000,
            width: 1920,
            height: 1080,
            downloadCount: 64,
            likeCount: 23,
            createdAt: Date().addingTimeInterval(-172800),
            isApproved: true,
            isDownloaded: false
        ),
        GalleryItem(
            id: "preview-4",
            name: "ミニマル幾何学模様",
            type: .image,
            category: "Minimal",
            tags: ["ミニマル", "幾何学"],
            authorName: "高橋美咲",
            authorID: "author-4",
            thumbnailURLString: "",
            fileURLString: "",
            fileSize: 800_000,
            width: 2560,
            height: 1600,
            downloadCount: 312,
            likeCount: 156,
            createdAt: Date().addingTimeInterval(-259200),
            isApproved: true,
            isDownloaded: false
        ),
    ]
}

// MARK: - ストア: データあり

#Preview("ストア: データあり") {
    let gallery = GalleryManager.previewInstance(
        featured: Array(GalleryPreviewData.sampleItems.prefix(2)),
        community: GalleryPreviewData.sampleItems
    )
    let auth = AuthManager.previewInstance(isAuthenticated: true)

    OnlineGalleryView(
        galleryManager: gallery,
        authManager: auth,
        isPreview: true
    )
    .frame(width: 800, height: 600)
}

// MARK: - ストア: 読み込み中

#Preview("ストア: 読み込み中") {
    let gallery = GalleryManager.previewInstance(isLoading: true)
    let auth = AuthManager.previewInstance(isAuthenticated: true)

    OnlineGalleryView(
        galleryManager: gallery,
        authManager: auth,
        isPreview: true
    )
    .frame(width: 800, height: 600)
}

// MARK: - ストア: エラー

#Preview("ストア: エラー") {
    let gallery = GalleryManager.previewInstance(
        errorMessage: "ネットワーク接続を確認してください。サーバーに接続できません。"
    )
    let auth = AuthManager.previewInstance(isAuthenticated: true)

    OnlineGalleryView(
        galleryManager: gallery,
        authManager: auth,
        isPreview: true
    )
    .frame(width: 800, height: 600)
}

// MARK: - ストア: 空

#Preview("ストア: 空") {
    let gallery = GalleryManager.previewInstance()
    let auth = AuthManager.previewInstance(isAuthenticated: true)

    OnlineGalleryView(
        galleryManager: gallery,
        authManager: auth,
        isPreview: true
    )
    .frame(width: 800, height: 600)
}

// MARK: - ストア: 未ログイン

#Preview("ストア: 未ログイン") {
    let gallery = GalleryManager.previewInstance()
    let auth = AuthManager.previewInstance(isAuthenticated: false)

    OnlineGalleryView(
        galleryManager: gallery,
        authManager: auth,
        isPreview: true
    )
    .frame(width: 800, height: 600)
}

// MARK: - サムネイル単体

#Preview("サムネイル") {
    let gallery = GalleryManager.previewInstance()

    OnlineGalleryThumbnail(
        item: GalleryPreviewData.sampleItems[0],
        onDownload: {},
        onLike: {},
        galleryManager: gallery,
        isPreview: true
    )
    .frame(width: 220)
    .padding()
}
#endif
