import SwiftUI
import AVFoundation

// MARK: - コレクションサイドバー

/// サイドバーのコレクション一覧
struct CollectionSidebarView: View {
    @ObservedObject var library: WallpaperLibrary
    @Binding var selectedCollectionID: String?
    @Binding var showingCreateCollection: Bool
    @Binding var newCollectionName: String

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(library.collections) { collection in
                        CollectionSidebarRow(
                            collection: collection,
                            isSelected: selectedCollectionID == collection.id,
                            wallpaperCount: collection.wallpaperIDs.count,
                            onSelect: { selectedCollectionID = collection.id },
                            onDelete: collection.isSystem ? nil : {
                                library.deleteCollection(id: collection.id)
                                if selectedCollectionID == collection.id {
                                    selectedCollectionID = "favorites"
                                }
                            },
                            onRename: { newName in
                                library.renameCollection(id: collection.id, name: newName)
                            }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }

            Divider()

            // 新規コレクション作成
            if showingCreateCollection {
                HStack(spacing: 6) {
                    TextField("名前を入力...", text: $newCollectionName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onSubmit {
                            createCollection()
                        }

                    Button(action: createCollection) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(newCollectionName.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button(action: {
                        showingCreateCollection = false
                        newCollectionName = ""
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else {
                Button(action: { showingCreateCollection = true }) {
                    Label("新規コレクション", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
        }
    }

    private func createCollection() {
        let name = newCollectionName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let collection = library.createCollection(name: name)
        selectedCollectionID = collection.id
        newCollectionName = ""
        showingCreateCollection = false
    }
}

// MARK: - コレクションサイドバー行

struct CollectionSidebarRow: View {
    let collection: WallpaperCollection
    let isSelected: Bool
    let wallpaperCount: Int
    let onSelect: () -> Void
    let onDelete: (() -> Void)?
    let onRename: ((String) -> Void)?

    @State private var isEditing = false
    @State private var editName: String = ""

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: collection.icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundColor(isSelected ? .accentColor : .secondary)

                if isEditing {
                    TextField("名前", text: $editName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .onSubmit {
                            onRename?(editName)
                            isEditing = false
                        }
                } else {
                    Text(collection.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                }

                Spacer()

                Text("\(wallpaperCount)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .foregroundColor(isSelected ? .accentColor : .primary)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !collection.isSystem {
                Button("名前を変更") {
                    editName = collection.name
                    isEditing = true
                }
                Divider()
                Button("削除", role: .destructive) {
                    onDelete?()
                }
            }
        }
    }
}

// MARK: - コレクションコンテンツビュー

/// メインエリアにコレクション内の壁紙を表示
struct CollectionContentView: View {
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var appDelegate: AppDelegate
    @Binding var selectedCollectionID: String?

    @State private var previewWallpaper: WallpaperItem?
    @State private var previewStartsInDetails = false

    private let columns: [GridItem] = [GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 12)]

    private var currentCollection: WallpaperCollection? {
        guard let id = selectedCollectionID else { return nil }
        return library.collections.first(where: { $0.id == id })
    }

    private var collectionWallpapers: [WallpaperItem] {
        guard let id = selectedCollectionID else { return [] }
        return library.wallpapers(in: id)
    }

    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー
            if let collection = currentCollection {
                HStack(spacing: 12) {
                    Image(systemName: collection.icon)
                        .font(.system(size: 18))
                        .foregroundColor(.accentColor)
                    Text(collection.name)
                        .font(.system(size: 18, weight: .semibold))
                    Text("\(collectionWallpapers.count)件")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                Divider()
            }

            // コンテンツ
            ZStack {
                if collectionWallpapers.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(collectionWallpapers) { item in
                                CollectionThumbnailView(
                                    item: item,
                                    library: library,
                                    appDelegate: appDelegate,
                                    collectionID: selectedCollectionID ?? "",
                                    isSelected: previewWallpaper?.id == item.id,
                                    onSelect: {
                                        previewStartsInDetails = false
                                        previewWallpaper = item
                                    },
                                    onOpenDetails: {
                                        previewStartsInDetails = true
                                        previewWallpaper = item
                                    }
                                )
                            }
                        }
                        .padding(20)
                    }
                    .frame(maxWidth: .infinity)

                    if let wallpaper = previewWallpaper {
                        WallpaperPreviewOverlay(
                            item: wallpaper,
                            library: library,
                            appDelegate: appDelegate,
                            startsInDetails: previewStartsInDetails,
                            onClose: {
                                previewWallpaper = nil
                                previewStartsInDetails = false
                            }
                        )
                        .id("\(wallpaper.id)-collection-\(previewStartsInDetails)")
                        .transition(.opacity)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .animation(.easeOut(duration: 0.18), value: previewWallpaper != nil)
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: currentCollection?.icon ?? "heart",
            title: "コレクションは空です",
            message: "ギャラリーから壁紙をお気に入りに追加してください"
        )
    }
}

// MARK: - コレクション用サムネイルビュー

/// コレクション内の壁紙サムネイル
struct CollectionThumbnailView: View {
    let item: WallpaperItem
    let library: WallpaperLibrary
    let appDelegate: AppDelegate
    let collectionID: String
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
                            Image(systemName: "photo")
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

                VStack {
                    HStack {
                        Spacer()

                        Button(action: onOpenDetails) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(5)
                                .background(Color.black.opacity(0.52))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(6)
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
            .brightness(isHovering ? 0.05 : 0)
            .animation(.easeInOut(duration: 0.15), value: isHovering)
            .allowsHitTesting(false)

            Text(item.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .foregroundColor(isSelected ? .accentColor : .primary)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                withAnimation(.linear(duration: 0).repeatForever(autoreverses: false)) {
                    glowAngle = 180
                }
            } else {
                glowAngle = 0
            }
        }
        .onTapGesture { onSelect() }
        .contextMenu {
            // 壁紙適用
            Button(action: applyWallpaper) {
                Label("設定する", systemImage: "checkmark.circle")
            }

            // コレクションから削除
            Button(role: .destructive, action: {
                library.removeFromCollection(wallpaperID: item.id, collectionID: collectionID)
            }) {
                Label("コレクションから削除", systemImage: "minus.circle")
            }
        }
        .onAppear {
            if thumbnail == nil {
                thumbnail = library.getThumbnailImage(for: item)
            }
        }
    }

    private var enabledDisplays: [DisplayInfo] {
        displayManager.connectedDisplays.filter { displayManager.isDisplayEnabled($0.id) }
    }

    private func applyWallpaper() {
        WallpaperApplicator.apply(item: item, library: library, appDelegate: appDelegate)
    }

    private func applyWallpaper(to displayID: String) {
        WallpaperApplicator.apply(item: item, library: library, appDelegate: appDelegate, to: displayID)
    }
}
