import SwiftUI
import MetalKit
import AVFoundation
import ImageIO
import WebKit

// MARK: - WallpaperThumbnailView
// Why: 個別の壁紙サムネイル + ホバー演出 + コンテキストメニュー。

/// 個別の壁紙サムネイルビュー
struct WallpaperThumbnailView: View {
    let item: WallpaperItem
    let library: WallpaperLibrary
    let appDelegate: AppDelegate
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpenDetails: () -> Void

    @State private var isHovering = false
    @State private var thumbnail: NSImage?
    /// ホバー時の光アニメーション用角度
    @State private var glowAngle: Double = 0

    @ObservedObject private var displayManager = DisplayManager.shared

    /// アニメーション壁紙かどうか
    private var isAnimated: Bool {
        item.type == .video || item.type == .gif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // サムネイル画像
            ZStack {
                if let thumbnail = thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(16/10, contentMode: .fill)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .aspectRatio(16/10, contentMode: .fill)
                        .overlay(
                            Image(systemName: typeIcon)
                                .font(.system(size: 40))
                                .foregroundColor(.gray)
                        )
                }

                // ホバー時：アニメーション壁紙ならビデオプレビューをオーバーレイ
                if isHovering && isAnimated {
                    ThumbnailVideoPreview(item: item, library: library)
                        .aspectRatio(16/10, contentMode: .fill)
                        .clipped()
                        .transition(.opacity)
                }

                // タイプバッジ + お気に入りボタン
                VStack {
                    HStack {
                        // お気に入りボタン（左上）
                        Button(action: { library.toggleFavorite(wallpaperID: item.id) }) {
                            Image(systemName: library.isFavorite(item.id) ? "heart.fill" : "heart")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(library.isFavorite(item.id) ? .red : .white)
                                .padding(5)
                                .background(Color.black.opacity(0.5))
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(library.isFavorite(item.id) ? "お気に入りから削除" : "お気に入りに追加")
                        .accessibilityHint("\(item.name)")
                        .padding(4)

                        Spacer()

                        VStack(spacing: 6) {
                            Button(action: onOpenDetails) {
                                Image(systemName: "info.circle.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(5)
                                    .background(Color.black.opacity(0.52))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("詳細を表示")
                            .accessibilityHint("\(item.name) の詳細パネルを開きます")

                            typeBadge
                        }
                        .padding(4)
                    }
                    Spacer()
                }
            }
            .aspectRatio(16/10, contentMode: .fit)
            .cornerRadius(8)
            .overlay(
                // スポットライト光エフェクト（ホバー時）
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                Color.white.opacity(0.0),
                                Color.white.opacity(0.6),
                                Color.accentColor.opacity(0.8),
                                Color.white.opacity(0.6),
                                Color.white.opacity(0.0),
                                Color.white.opacity(0.0),
                                Color.white.opacity(0.0),
                            ]),
                            center: .center,
                            angle: .degrees(glowAngle)
                        ),
                        lineWidth: isHovering ? 2.5 : 0
                    )
                    .opacity(isHovering ? 1 : 0)
            )
            .overlay(
                // 外側のソフトグロー
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor.opacity(isHovering ? 0.4 : 0), lineWidth: 4)
                    .blur(radius: 4)
            )
            .overlay(
                // 選択時のボーダー
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            )
            .shadow(
                color: isHovering ? Color.accentColor.opacity(0.5) : Color.clear,
                radius: isHovering ? 10 : 0,
                x: 0,
                y: 0
            )
            .brightness(isHovering ? 0.03 : 0)
            .animation(.easeInOut(duration: 0.15), value: isHovering)
            .allowsHitTesting(false)

            // 壁紙名
            Text(item.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .foregroundColor(isSelected ? .accentColor : .primary)

            // カテゴリ + タグ表示
            HStack(spacing: 4) {
                Text(item.category)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                if !item.tags.isEmpty {
                    ForEach(item.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 9))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.1))
                            .foregroundColor(.accentColor)
                            .cornerRadius(4)
                    }
                    if item.tags.count > 3 {
                        Text("+\(item.tags.count - 3)")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                prewarmWebPreviewIfNeeded()
                // 光の回転アニメーション開始
                withAnimation(.linear(duration: 0).repeatForever(autoreverses: false)) {
                    glowAngle = 180
                }
            } else {
                glowAngle = 0
            }
        }
        .onTapGesture {
            prewarmWebPreviewIfNeeded()
            onSelect()
        }
        .contextMenu {
            // お気に入りトグル
            Button(action: { library.toggleFavorite(wallpaperID: item.id) }) {
                Label(
                    library.isFavorite(item.id) ? "お気に入りから削除" : "お気に入りに追加",
                    systemImage: library.isFavorite(item.id) ? "heart.slash" : "heart"
                )
            }

            // コレクションに追加サブメニュー
            let userCollections = library.collections.filter { !$0.isSystem }
            if !userCollections.isEmpty {
                Menu("コレクションに追加") {
                    ForEach(userCollections) { collection in
                        Button(action: {
                            library.addToCollection(wallpaperID: item.id, collectionID: collection.id)
                        }) {
                            Label(
                                collection.name,
                                systemImage: library.isInCollection(wallpaperID: item.id, collectionID: collection.id)
                                    ? "checkmark.circle.fill" : collection.icon
                            )
                        }
                    }
                }
            }

            Divider()

            // 壁紙適用（ディスプレイ選択）
            if enabledDisplays.count > 1 {
                Menu("設定する") {
                    Button(action: applyWallpaper) {
                        Label("すべてのディスプレイ", systemImage: "rectangle.on.rectangle")
                    }
                    Divider()
                    ForEach(enabledDisplays) { display in
                        Button(action: { applyWallpaper(to: display.id) }) {
                            Label(display.localizedName, systemImage: display.isMain ? "display" : "rectangle")
                        }
                    }
                }
            } else {
                Button(action: applyWallpaper) {
                    Label("設定する", systemImage: "checkmark.circle")
                }
            }

            if item.isDownloaded && item.type != .shader {
                Divider()
                Button(role: .destructive, action: { library.deleteWallpaper(item) }) {
                    Label("削除", systemImage: "trash")
                }
            }
        }
        .onAppear {
            guard thumbnail == nil else { return }
            Task(priority: .utility) {
                let loadedThumbnail = library.getThumbnailImage(for: item)
                await MainActor.run {
                    if thumbnail == nil {
                        thumbnail = loadedThumbnail
                    }
                }
            }
        }
    }

    private var typeIcon: String { item.type.icon }

    @ViewBuilder
    private var typeBadge: some View {
        let badge = item.type.iconAndColor
        Image(systemName: badge.icon)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white)
            .padding(4)
            .background(badge.color)
            .cornerRadius(4)
    }

    /// 有効なディスプレイのリストを取得
    private var enabledDisplays: [DisplayInfo] {
        displayManager.connectedDisplays.filter { displayManager.isDisplayEnabled($0.id) }
    }

    private func applyWallpaper() {
        WallpaperApplicator.apply(item: item, library: library, appDelegate: appDelegate)
    }

    private func applyWallpaper(to displayID: String) {
        WallpaperApplicator.apply(item: item, library: library, appDelegate: appDelegate, to: displayID)
    }

    private func prewarmWebPreviewIfNeeded() {
        guard let rootURL = webWallpaperRootURL else { return }
        WebWallpaperPreviewPreloader.shared.prewarm(rootURL: rootURL)
    }

    private var webWallpaperRootURL: URL? {
        for candidate in wallpaperRootCandidates {
            let rootURL = WallpaperEngineWebResolver.canonicalFilesystemURL(matching: candidate) ?? candidate.standardizedFileURL
            if WallpaperEngineWebResolver.isWebWallpaperRoot(rootURL) {
                return rootURL
            }
        }
        return nil
    }

    private var wallpaperRootCandidates: [URL] {
        var candidates: [URL] = []
        if let ext = item.externalRootPath, !ext.isEmpty {
            candidates.append(URL(fileURLWithPath: ext))
        }
        if let folderName = item.folderName {
            candidates.append(library.subfolderURL(inLibrary: folderName))
        }
        if let wallpaperURL = library.getWallpaperURL(for: item), isDirectory(wallpaperURL) {
            candidates.append(wallpaperURL)
        }
        return candidates
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
