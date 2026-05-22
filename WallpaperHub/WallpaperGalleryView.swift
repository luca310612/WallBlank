import SwiftUI
import MetalKit
import AVFoundation
import ImageIO
import WebKit

// MARK: - Shared Wallpaper Application Logic

/// 壁紙適用ロジックの共通ヘルパー
enum WallpaperApplicator {
    /// 壁紙を全ディスプレイに適用
    static func apply(
        item: WallpaperItem,
        library: WallpaperLibrary,
        appDelegate: AppDelegate,
        completion: (() -> Void)? = nil
    ) {
        let finish: () -> Void = {
            DispatchQueue.main.async {
                completion?()
            }
        }

        switch item.type {
        case .shader:
            debugLog("[Gallery] Shader wallpapers are disabled in the client")
            finish()
        case .scene:
            if let ext = item.externalRootPath, !ext.isEmpty {
                let raw = URL(fileURLWithPath: ext)
                let u = WallpaperEngineWebResolver.canonicalFilesystemURL(matching: raw) ?? raw.standardizedFileURL
                if WallpaperEngineWebResolver.isWebWallpaperRoot(u) {
                    appDelegate.setBackgroundImage(url: u)
                    appDelegate.setEffectIntensity(0.0)
                } else {
                    debugLog("[Gallery] 外部パスを Web 壁紙として解決できません（存在・project.json・type/file を確認）: \(ext)")
                }
                finish()
            } else if let folderName = item.folderName {
                let raw = library.subfolderURL(inLibrary: folderName)
                let folderURL = WallpaperEngineWebResolver.canonicalFilesystemURL(matching: raw) ?? raw.standardizedFileURL
                if WallpaperEngineWebResolver.isWebWallpaperRoot(folderURL) {
                    appDelegate.setBackgroundImage(url: folderURL)
                    appDelegate.setEffectIntensity(0.0)
                    finish()
                } else {
                    let epoch = appDelegate.bumpWallpaperSelectionEpoch()
                    library.applyWallpaperEngineScene(folderName: folderName) { result in
                        guard appDelegate.isWallpaperSelectionEpochCurrent(epoch) else {
                            finish()
                            return
                        }
                        switch result {
                        case .success(let imageURL):
                            appDelegate.setBackgroundImage(url: imageURL)
                            appDelegate.setEffectIntensity(0.0)
                        case .failure(let error):
                            debugLog("[Gallery] Failed to apply scene: \(error)")
                        }
                        finish()
                    }
                }
            } else {
                finish()
            }
        case .image, .video, .gif, .mediaFolder:
            if let url = library.getWallpaperURL(for: item) {
                appDelegate.setBackgroundImage(url: url)
                appDelegate.setEffectIntensity(0.0)
            }
            finish()
        }
    }

    /// 壁紙を特定のディスプレイに適用
    static func apply(
        item: WallpaperItem,
        library: WallpaperLibrary,
        appDelegate: AppDelegate,
        to displayID: String,
        completion: (() -> Void)? = nil
    ) {
        let finish: () -> Void = {
            DispatchQueue.main.async {
                completion?()
            }
        }

        switch item.type {
        case .shader:
            apply(item: item, library: library, appDelegate: appDelegate, completion: completion)
        case .scene:
            if let ext = item.externalRootPath, !ext.isEmpty {
                let raw = URL(fileURLWithPath: ext)
                let u = WallpaperEngineWebResolver.canonicalFilesystemURL(matching: raw) ?? raw.standardizedFileURL
                if WallpaperEngineWebResolver.isWebWallpaperRoot(u) {
                    appDelegate.setBackgroundImage(url: u, for: displayID)
                    appDelegate.setEffectIntensity(0.0)
                } else {
                    debugLog("[Gallery] 外部パスを Web 壁紙として解決できません（存在・project.json・type/file を確認）: \(ext)")
                }
                finish()
            } else if let folderName = item.folderName {
                let raw = library.subfolderURL(inLibrary: folderName)
                let folderURL = WallpaperEngineWebResolver.canonicalFilesystemURL(matching: raw) ?? raw.standardizedFileURL
                if WallpaperEngineWebResolver.isWebWallpaperRoot(folderURL) {
                    appDelegate.setBackgroundImage(url: folderURL, for: displayID)
                    appDelegate.setEffectIntensity(0.0)
                    finish()
                } else {
                    let epoch = appDelegate.bumpWallpaperSelectionEpoch()
                    library.applyWallpaperEngineScene(folderName: folderName) { result in
                        guard appDelegate.isWallpaperSelectionEpochCurrent(epoch) else {
                            finish()
                            return
                        }
                        switch result {
                        case .success(let imageURL):
                            appDelegate.setBackgroundImage(url: imageURL, for: displayID)
                            appDelegate.setEffectIntensity(0.0)
                        case .failure(let error):
                            debugLog("[Gallery] Failed to apply scene: \(error)")
                        }
                        finish()
                    }
                }
            } else {
                finish()
            }
        case .image, .video, .gif, .mediaFolder:
            if let url = library.getWallpaperURL(for: item) {
                appDelegate.setBackgroundImage(url: url, for: displayID)
                appDelegate.setEffectIntensity(0.0)
            }
            finish()
        }
    }
}

/// 壁紙ギャラリービュー
struct WallpaperGalleryView: View {
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject var appDelegate: AppDelegate
    @Binding var selectedCategory: String
    @Binding var isPreviewPresented: Bool
    var searchText: String = ""

    @State private var previewWallpaper: WallpaperItem?
    @State private var previewStartsInDetails = false

    private let columns: [GridItem] = [GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 12)]

    var filteredWallpapers: [WallpaperItem] {
        var items = library.wallpapers.filter { $0.type != .shader }

        // カテゴリフィルター
        if selectedCategory != "All" {
            items = items.filter { $0.category == selectedCategory }
        }

        // 検索テキストフィルター（名前とタグの両方で検索）
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            items = items.filter { item in
                item.name.lowercased().contains(query) ||
                item.tags.contains { $0.lowercased().contains(query) }
            }
        }

        return items
    }

    var body: some View {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespaces)
        let isSearchEmptyResult = filteredWallpapers.isEmpty && !trimmedQuery.isEmpty
        return ZStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    if !isSearchEmptyResult {
                        NoWallpaperCard(appDelegate: appDelegate)
                    }

                    ForEach(filteredWallpapers) { item in
                        WallpaperThumbnailView(
                            item: item,
                            library: library,
                            appDelegate: appDelegate,
                            isSelected: previewWallpaper?.id == item.id,
                            onSelect: {
                                previewStartsInDetails = false
                                isPreviewPresented = true
                                previewWallpaper = item
                            },
                            onOpenDetails: {
                                previewStartsInDetails = true
                                isPreviewPresented = true
                                previewWallpaper = item
                            }
                        )
                    }
                }
                .padding(20)

                // 検索文字列が入っているのに 0 ヒットのときだけグリッドの下に空状態を表示する。
                // Why: LazyVGrid の中で全幅占有させる方法が安定しないため、グリッド外で別レイヤーとして表示する。
                if isSearchEmptyResult {
                    EmptyStateView(
                        systemImage: "magnifyingglass",
                        title: "検索結果がありません",
                        message: "別のキーワードで検索してください"
                    )
                }
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
                        isPreviewPresented = false
                    }
                )
                .id("\(wallpaper.id)-\(previewStartsInDetails)")
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.18), value: previewWallpaper != nil)
        .onChange(of: previewWallpaper == nil) { isClosed in
            isPreviewPresented = !isClosed
        }
        .onDisappear {
            isPreviewPresented = false
        }
    }
}
