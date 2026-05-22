import SwiftUI
import MetalKit
import AVFoundation
import ImageIO
import WebKit

// MARK: - WallpaperDetailPanel
// Why: 詳細パネル本体 + SetControl/Chooser/ChoiceCard をまとめて配置。

struct WallpaperDetailPanel: View {
    let item: WallpaperItem
    let library: WallpaperLibrary
    @ObservedObject var appDelegate: AppDelegate
    let onClose: () -> Void

    @State private var thumbnail: NSImage?
    @State private var webWallpaperScale: Double = 1.0
    @State private var webWallpaperDisplaySyncEnabled: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ヘッダー
            HStack {
                Text("詳細")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    // プレビュー画像
                    if let thumbnail = thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(16/10, contentMode: .fill)
                            .clipped()
                            .cornerRadius(10)
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .aspectRatio(16/10, contentMode: .fill)
                            .overlay(
                                Image(systemName: typeIcon)
                                    .font(.system(size: 50))
                                    .foregroundColor(.gray)
                            )
                            .cornerRadius(10)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        // 壁紙名
                        VStack(alignment: .leading, spacing: 6) {
                            Text("名前")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                            Text(item.name)
                                .font(.system(size: 14))
                                .foregroundColor(.primary)
                        }

                        Divider()

                        // カテゴリ
                        VStack(alignment: .leading, spacing: 6) {
                            Text("カテゴリ")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                            HStack {
                                Image(systemName: categoryIcon)
                                    .font(.system(size: 12))
                                Text(item.category)
                                    .font(.system(size: 14))
                            }
                            .foregroundColor(.primary)
                        }

                        Divider()

                        // タイプ
                        VStack(alignment: .leading, spacing: 6) {
                            Text("タイプ")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                            HStack {
                                let (icon, color) = typeIconAndColor
                                Image(systemName: icon)
                                    .font(.system(size: 12))
                                    .foregroundColor(color)
                                Text(typeDisplayName)
                                    .font(.system(size: 14))
                                    .foregroundColor(.primary)
                            }
                        }

                        // タグ表示
                        if !item.tags.isEmpty {
                            Divider()

                            VStack(alignment: .leading, spacing: 6) {
                                Text("タグ")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.secondary)
                                FlowLayout(spacing: 4) {
                                    ForEach(item.tags, id: \.self) { tag in
                                        Text(tag)
                                            .font(.system(size: 11))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Color.accentColor.opacity(0.12))
                                            .foregroundColor(.accentColor)
                                            .cornerRadius(8)
                                    }
                                }
                            }
                        }

                        if isWebWallpaper {
                            Divider()

                            VStack(alignment: .leading, spacing: 10) {
                                Text("Web壁紙")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.secondary)

                                HStack {
                                    Text("表示倍率")
                                        .font(.system(size: 13, weight: .medium))
                                    Spacer()
                                    Text(webWallpaperScaleLabel)
                                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                                        .foregroundColor(.secondary)
                                }

                                Slider(
                                    value: Binding(
                                        get: { webWallpaperScale },
                                        set: { newValue in
                                            let stepped = (newValue * 20).rounded() / 20
                                            webWallpaperScale = stepped
                                            appDelegate.settings.webWallpaperScale = Float(stepped)
                                        }
                                    ),
                                    in: 0.5...2.0,
                                    step: 0.05
                                )
                                .controlSize(.small)

                                Text("100% で等倍。背景画像と背景動画に反映されます")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)

                                Divider()
                                    .padding(.vertical, 2)

                                Toggle(isOn: Binding(
                                    get: { webWallpaperDisplaySyncEnabled },
                                    set: { enabled in
                                        webWallpaperDisplaySyncEnabled = enabled
                                        if let rootURL = wallpaperRootURL {
                                            appDelegate.settings.setWebWallpaperDisplaySyncEnabled(enabled, for: rootURL)
                                        }
                                    }
                                )) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("displayを同期")
                                            .font(.system(size: 13, weight: .medium))
                                        Text(webWallpaperDisplaySyncEnabled
                                             ? "同じ Web 壁紙を複数 display で使う時に設定・再生状態を共有します"
                                             : "display ごとに設定・再生状態を分離します。マウス視差系はこちら")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .toggleStyle(.switch)
                            }
                        }

                        // 動画の場合は音量スライダーを表示
                        if item.type == .video {
                            Divider()

                            VStack(alignment: .leading, spacing: 8) {
                                Text("音量")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.secondary)

                                HStack(spacing: 10) {
                                    Button(action: {
                                        if appDelegate.videoVolume > 0 {
                                            appDelegate.setVideoVolume(0)
                                        } else {
                                            appDelegate.setVideoVolume(1.0)
                                        }
                                    }) {
                                        Image(systemName: volumeIcon)
                                            .font(.system(size: 14))
                                            .foregroundColor(.secondary)
                                            .frame(width: 20)
                                    }
                                    .buttonStyle(.plain)

                                    Slider(
                                        value: Binding(
                                            get: { appDelegate.videoVolume },
                                            set: { appDelegate.setVideoVolume($0) }
                                        ),
                                        in: 0...1
                                    )
                                    .controlSize(.small)

                                    Text("\(Int(appDelegate.videoVolume * 100))%")
                                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                                        .foregroundColor(.secondary)
                                        .frame(width: 36, alignment: .trailing)
                                }
                            }
                        }

                        Divider()

                        // 削除ボタン（小さめ）
                        if item.isDownloaded {
                            Button(action: {
                                library.deleteWallpaper(item)
                                onClose()
                            }) {
                                Label("削除", systemImage: "trash")
                                    .font(.system(size: 12))
                                    .foregroundColor(.red.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
                        }
                    }
                }
                .padding(20)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear {
            Task(priority: .utility) {
                let loadedThumbnail = library.getThumbnailImage(for: item)
                await MainActor.run {
                    thumbnail = loadedThumbnail
                }
            }
            webWallpaperScale = Double(appDelegate.settings.webWallpaperScale)
            if let rootURL = wallpaperRootURL {
                webWallpaperDisplaySyncEnabled = appDelegate.settings.isWebWallpaperDisplaySyncEnabled(for: rootURL)
            } else {
                webWallpaperDisplaySyncEnabled = true
            }
        }
    }

    private var webWallpaperScaleLabel: String {
        "\(Int(webWallpaperScale * 100))%"
    }

    private var volumeIcon: String {
        let vol = appDelegate.videoVolume
        if vol <= 0 {
            return "speaker.slash.fill"
        } else if vol < 0.33 {
            return "speaker.wave.1.fill"
        } else if vol < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    private var typeIcon: String { item.type.icon }
    private var typeDisplayName: String { item.type.displayName }
    private var categoryIcon: String { WallpaperCategoryIcon.icon(for: item.category) }
    private var typeIconAndColor: (String, Color) {
        let badge = item.type.iconAndColor
        return (badge.icon, badge.color)
    }

    private var isWebWallpaper: Bool {
        guard let rootURL = wallpaperRootURL else { return false }
        return WallpaperEngineWebResolver.isWebWallpaperRoot(rootURL)
    }

    private var wallpaperRootURL: URL? {
        if let ext = item.externalRootPath, !ext.isEmpty {
            let raw = URL(fileURLWithPath: ext)
            return WallpaperEngineWebResolver.canonicalFilesystemURL(matching: raw) ?? raw.standardizedFileURL
        }
        if let folderName = item.folderName {
            let raw = library.subfolderURL(inLibrary: folderName)
            return WallpaperEngineWebResolver.canonicalFilesystemURL(matching: raw) ?? raw.standardizedFileURL
        }
        if let wallpaperURL = library.getWallpaperURL(for: item), isDirectory(wallpaperURL) {
            return WallpaperEngineWebResolver.canonicalFilesystemURL(matching: wallpaperURL) ?? wallpaperURL.standardizedFileURL
        }
        return nil
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

}

struct WallpaperSetControl: View {
    let displays: [DisplayInfo]
    @Binding var selectedDisplayID: String?
    @Binding var showDisplayChooser: Bool
    @Binding var showDetails: Bool
    let isFavorite: Bool
    let onToggleFavorite: () -> Void
    let onApply: () -> Void

    private var selectedDisplay: DisplayInfo? {
        guard let selectedDisplayID else { return nil }
        return displays.first { $0.id == selectedDisplayID }
    }

    var body: some View {
        HStack(spacing: 12) {
            // コントロールボタン: 詳細パネルの表示トグル（旧右上の info ボタンの役割）
            Button(action: {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                    showDetails.toggle()
                }
            }) {
                Image(systemName: showDetails ? "info.circle.fill" : "info.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(actionButtonBackground)
            }
            .buttonStyle(.plain)
            .help("詳細を表示")

            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isFavorite ? Color.red : Color.white)
                    .frame(width: 42, height: 42)
                    .background(actionButtonBackground)
            }
            .buttonStyle(.plain)

            // Set ボタン: 押下するとディスプレイ選択ポップオーバーを表示し、選択後に適用する
            Button(action: { showDisplayChooser = true }) {
                Text(applyButtonTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white)
                            .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 5)
                    )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDisplayChooser, arrowEdge: .bottom) {
                DisplayChooserPopover(
                    displays: displays,
                    selectedDisplayID: $selectedDisplayID,
                    onConfirm: {
                        showDisplayChooser = false
                        onApply()
                    },
                    onClose: { showDisplayChooser = false }
                )
            }
        }
        .padding(10)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.70))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        )
    }

    private var applyButtonTitle: String {
        if let selectedDisplay {
            return "Set \(selectedDisplay.localizedName)"
        }
        return "Set Wallpaper"
    }

    private var actionButtonBackground: some View {
        Circle()
            .fill(Color.white.opacity(0.08))
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
    }
}

private struct DisplayChooserPopover: View {
    let displays: [DisplayInfo]
    @Binding var selectedDisplayID: String?
    let onConfirm: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("ディスプレイを選択")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()

                // 「すべてのディスプレイ」を選んで即適用
                Button(action: {
                    selectedDisplayID = nil
                    onConfirm()
                }) {
                    Text("すべて")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
            }

            if displays.isEmpty {
                Text("利用可能なディスプレイがありません")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.64))
                    .frame(maxWidth: .infinity, minHeight: 96)
            } else {
                ForEach(displays) { display in
                    // ディスプレイをタップするとそのディスプレイに即適用
                    Button(action: {
                        selectedDisplayID = display.id
                        onConfirm()
                    }) {
                        DisplayChoiceCard(
                            display: display,
                            isSelected: selectedDisplayID == display.id || (selectedDisplayID == nil && displays.count == 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(18)
        .frame(width: 330)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(red: 0.10, green: 0.13, blue: 0.15).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
        )
    }
}

private struct DisplayChoiceCard: View {
    let display: DisplayInfo
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: display.isBuiltIn ? "macbook" : "display")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.white.opacity(0.86))

            Text(display.localizedName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(display.isMain ? "Main" : "\(Int(display.resolution.width)) x \(Int(display.resolution.height))")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.48))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 136)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.white.opacity(0.12), lineWidth: isSelected ? 5 : 1)
        )
    }
}
