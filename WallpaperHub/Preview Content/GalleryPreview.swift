#if DEBUG
import SwiftUI

// MARK: - ギャラリープレビュー用サンプルデータ

enum LocalGalleryPreviewData {
    static let sampleWallpapers: [WallpaperItem] = [
        WallpaperItem(
            id: "preview-local-1",
            name: "夕焼けの山並み",
            type: .image,
            thumbnailName: "sunset_mountains",
            fileName: "sunset_mountains.jpg",
            category: "Nature",
            isDownloaded: true,
            tags: ["風景", "夕焼け", "山"]
        ),
        WallpaperItem(
            id: "preview-local-2",
            name: "サイバーパンクシティ",
            type: .image,
            thumbnailName: "cyberpunk_city",
            fileName: "cyberpunk_city.png",
            category: "Abstract",
            isDownloaded: true,
            tags: ["サイバーパンク", "都市", "ネオン"]
        ),
        WallpaperItem(
            id: "preview-local-3",
            name: "波のアニメーション",
            type: .video,
            thumbnailName: "ocean_waves",
            fileName: "ocean_waves.mp4",
            category: "Nature",
            isDownloaded: true,
            tags: ["海", "波", "動画"]
        ),
        WallpaperItem(
            id: "preview-local-4",
            name: "ミニマル幾何学",
            type: .image,
            thumbnailName: "minimal_geo",
            fileName: "minimal_geo.png",
            category: "Minimal",
            isDownloaded: true,
            tags: ["ミニマル", "幾何学"]
        ),
        WallpaperItem(
            id: "preview-local-5",
            name: "ネオンGIF",
            type: .gif,
            thumbnailName: "neon_loop",
            fileName: "neon_loop.gif",
            category: "Abstract",
            isDownloaded: true,
            tags: ["ネオン", "GIF"]
        ),
        WallpaperItem(
            id: "preview-local-6",
            name: "Gradient Wave",
            type: .shader,
            thumbnailName: "shader_gradient_thumb",
            shaderType: 0,
            category: "Shaders",
            isDownloaded: true,
            tags: ["シェーダー"]
        ),
    ]
}

// MARK: - ギャラリー: 壁紙一覧

#Preview("ギャラリー: 一覧") {
    let library = WallpaperLibrary.previewInstance(
        wallpapers: LocalGalleryPreviewData.sampleWallpapers
    )

    WallpaperGalleryView(
        library: library,
        appDelegate: AppDelegate(),
        selectedCategory: .constant("All"),
        isPreviewPresented: .constant(false)
    )
    .frame(width: 900, height: 600)
}

// MARK: - ギャラリー: カテゴリフィルター

#Preview("ギャラリー: Natureカテゴリ") {
    let library = WallpaperLibrary.previewInstance(
        wallpapers: LocalGalleryPreviewData.sampleWallpapers
    )

    WallpaperGalleryView(
        library: library,
        appDelegate: AppDelegate(),
        selectedCategory: .constant("Nature"),
        isPreviewPresented: .constant(false)
    )
    .frame(width: 900, height: 600)
}

// MARK: - ギャラリー: 検索

#Preview("ギャラリー: 検索") {
    let library = WallpaperLibrary.previewInstance(
        wallpapers: LocalGalleryPreviewData.sampleWallpapers
    )

    WallpaperGalleryView(
        library: library,
        appDelegate: AppDelegate(),
        selectedCategory: .constant("All"),
        isPreviewPresented: .constant(false),
        searchText: "サイバー"
    )
    .frame(width: 900, height: 600)
}

// MARK: - ギャラリー: 空状態

#Preview("ギャラリー: 空") {
    let library = WallpaperLibrary.previewInstance(wallpapers: [])

    WallpaperGalleryView(
        library: library,
        appDelegate: AppDelegate(),
        selectedCategory: .constant("All"),
        isPreviewPresented: .constant(false)
    )
    .frame(width: 900, height: 600)
}
#endif
