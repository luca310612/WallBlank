import SwiftUI
import WidgetKit
import AppKit

// MARK: - Entry View (サイズ分岐)

struct WallpaperWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: WallpaperEntry

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(entry: entry)
        case .systemMedium:
            MediumWidgetView(entry: entry)
        case .systemLarge:
            LargeWidgetView(entry: entry)
        default:
            SmallWidgetView(entry: entry)
        }
    }
}

// MARK: - Small Widget

/// Small: 現在の壁紙サムネイル + 名前
struct SmallWidgetView: View {
    let entry: WallpaperEntry

    var body: some View {
        ZStack {
            // サムネイル背景
            if let path = entry.wallpaperThumbnailPath,
               let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(
                    colors: [.blue.opacity(0.6), .purple.opacity(0.6)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            // オーバーレイ情報
            VStack {
                Spacer()

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.wallpaperName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    if entry.isScheduleActive {
                        HStack(spacing: 3) {
                            Image(systemName: "clock.arrow.2.circlepath")
                                .font(.system(size: 8))
                            Text(entry.scheduleName ?? "ローテーション中")
                                .font(.system(size: 9))
                        }
                        .foregroundColor(.white.opacity(0.8))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
        .containerBackground(.clear, for: .widget)
    }
}

// MARK: - Medium Widget

/// Medium: 現在の壁紙 + お気に入り3つ（タップで切替）
struct MediumWidgetView: View {
    let entry: WallpaperEntry

    var body: some View {
        HStack(spacing: 0) {
            // 左: 現在の壁紙
            ZStack {
                if let path = entry.wallpaperThumbnailPath,
                   let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(
                        colors: [.blue.opacity(0.6), .purple.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }

                VStack {
                    HStack {
                        Text("現在")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.5))
                            .cornerRadius(4)
                        Spacer()
                    }
                    .padding(6)

                    Spacer()

                    Text(entry.wallpaperName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(Color.black.opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // 右: お気に入り3つ
            VStack(spacing: 4) {
                if entry.favorites.isEmpty {
                    VStack(spacing: 4) {
                        Image(systemName: "heart")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                        Text("お気に入り\nなし")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ForEach(entry.favorites.prefix(3)) { fav in
                        Button(intent: SetWallpaperIntent(wallpaperID: fav.id)) {
                            favoriteThumbnail(fav)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(width: 80)
            .padding(.leading, 4)
        }
        .padding(8)
        .containerBackground(.fill, for: .widget)
    }

    private func favoriteThumbnail(_ info: WidgetWallpaperInfo) -> some View {
        ZStack {
            if let thumb = info.thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.secondary.opacity(0.2)
                Image(systemName: "photo")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Large Widget

/// Large: お気に入りグリッド + スケジュールコントロール
struct LargeWidgetView: View {
    let entry: WallpaperEntry

    var body: some View {
        VStack(spacing: 8) {
            // ヘッダー: 現在の壁紙情報
            HStack {
                ZStack {
                    if let path = entry.wallpaperThumbnailPath,
                       let image = NSImage(contentsOfFile: path) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        LinearGradient(
                            colors: [.blue.opacity(0.4), .purple.opacity(0.4)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                }
                .frame(width: 80, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text("現在の壁紙")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text(entry.wallpaperName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(wallpaperTypeLabel)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                // 次の壁紙ボタン
                Button(intent: NextWallpaperIntent()) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }

            Divider()

            // スケジュール状態
            HStack {
                Image(systemName: entry.isScheduleActive ? "clock.arrow.2.circlepath" : "clock")
                    .font(.system(size: 11))
                    .foregroundColor(entry.isScheduleActive ? .green : .secondary)

                if entry.isScheduleActive {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.scheduleName ?? "ローテーション")
                            .font(.system(size: 11, weight: .medium))
                        if let next = entry.nextRotationDate {
                            Text("次: \(next, style: .relative)")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Text("スケジュール停止中")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(intent: ToggleScheduleIntent()) {
                    Image(systemName: entry.isScheduleActive ? "pause.circle" : "play.circle")
                        .font(.system(size: 16))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }

            Divider()

            // お気に入りグリッド
            if entry.favorites.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "heart.text.square")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("お気に入りに追加すると\nここに表示されます")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 6),
                    GridItem(.flexible(), spacing: 6),
                    GridItem(.flexible(), spacing: 6)
                ], spacing: 6) {
                    ForEach(entry.favorites.prefix(6)) { fav in
                        Button(intent: SetWallpaperIntent(wallpaperID: fav.id)) {
                            largeFavoriteThumbnail(fav)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .containerBackground(.fill, for: .widget)
    }

    private var wallpaperTypeLabel: String {
        switch entry.wallpaperType {
        case "video": return "動画"
        case "gif": return "GIF"
        case "shader": return "シェーダー"
        default: return "画像"
        }
    }

    private func largeFavoriteThumbnail(_ info: WidgetWallpaperInfo) -> some View {
        VStack(spacing: 2) {
            ZStack {
                if let thumb = info.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(16/10, contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.15)
                        .aspectRatio(16/10, contentMode: .fill)
                        .overlay(
                            Image(systemName: "photo")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary.opacity(0.5))
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))

            Text(info.name)
                .font(.system(size: 9))
                .lineLimit(1)
                .foregroundColor(.primary)
        }
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    ArtiaWidget()
} timeline: {
    WallpaperEntry(
        date: Date(),
        wallpaperName: "Mountain Sunset",
        wallpaperThumbnailPath: nil,
        wallpaperType: "image",
        favorites: [],
        isScheduleActive: true,
        nextRotationDate: Date().addingTimeInterval(3600),
        scheduleName: "毎時ローテーション"
    )
}

#Preview("Medium", as: .systemMedium) {
    ArtiaWidget()
} timeline: {
    WallpaperEntry(
        date: Date(),
        wallpaperName: "Ocean Waves",
        wallpaperThumbnailPath: nil,
        wallpaperType: "video",
        favorites: [
            WidgetWallpaperInfo(id: "1", name: "Forest", thumbnailPath: nil, type: "image"),
            WidgetWallpaperInfo(id: "2", name: "City Night", thumbnailPath: nil, type: "image"),
            WidgetWallpaperInfo(id: "3", name: "Aurora", thumbnailPath: nil, type: "image")
        ],
        isScheduleActive: false,
        nextRotationDate: nil,
        scheduleName: nil
    )
}

#Preview("Large", as: .systemLarge) {
    ArtiaWidget()
} timeline: {
    WallpaperEntry(
        date: Date(),
        wallpaperName: "Neon Cityscape",
        wallpaperThumbnailPath: nil,
        wallpaperType: "shader",
        favorites: [
            WidgetWallpaperInfo(id: "1", name: "Forest", thumbnailPath: nil, type: "image"),
            WidgetWallpaperInfo(id: "2", name: "City Night", thumbnailPath: nil, type: "image"),
            WidgetWallpaperInfo(id: "3", name: "Aurora", thumbnailPath: nil, type: "video"),
            WidgetWallpaperInfo(id: "4", name: "Mountain", thumbnailPath: nil, type: "image"),
            WidgetWallpaperInfo(id: "5", name: "Ocean", thumbnailPath: nil, type: "gif"),
            WidgetWallpaperInfo(id: "6", name: "Space", thumbnailPath: nil, type: "shader")
        ],
        isScheduleActive: true,
        nextRotationDate: Date().addingTimeInterval(1800),
        scheduleName: "お気に入りシャッフル"
    )
}
