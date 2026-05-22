import Foundation

/// オンラインギャラリーの壁紙アイテム
struct GalleryItem: Identifiable, Codable {
    let id: String
    let name: String
    let type: WallpaperType
    let category: String
    let tags: [String]
    let authorName: String
    let authorID: String
    let thumbnailURLString: String
    let fileURLString: String
    let fileSize: Int64
    let width: Int
    let height: Int
    var downloadCount: Int
    var likeCount: Int
    let createdAt: Date
    let isApproved: Bool
    var isDownloaded: Bool
    /// 元ファイルの拡張子（Firestoreから取得、nilの場合はtypeから推定）
    var fileExtension: String?

    var resolution: CGSize {
        CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    /// ダウンロード後にローカルのWallpaperItemに変換
    func toWallpaperItem(localFileName: String) -> WallpaperItem {
        WallpaperItem(
            id: "gallery_\(id)",
            name: name,
            type: type,
            thumbnailName: localFileName,
            fileName: localFileName,
            category: "ストア",
            isDownloaded: true,
            tags: tags + ["ストア"]
        )
    }
}
