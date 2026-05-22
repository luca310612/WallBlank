import SwiftUI
import MetalKit
import AVFoundation
import ImageIO
import WebKit

// MARK: - WallpaperPreviewOverlay
// Why: 詳細プレビューを覆うオーバーレイ。Facts/Backdrop は同ファイル内 private のまま。

private struct WallpaperPreviewFacts {
    var resolutionText: String?
    var fileSizeText: String?
    var durationText: String?

    var visibleItems: [String] {
        [resolutionText, fileSizeText, durationText].compactMap { $0 }
    }

    static func build(for item: WallpaperItem, library: WallpaperLibrary) -> WallpaperPreviewFacts {
        var facts = WallpaperPreviewFacts()

        let previewURL: URL? = {
            if let original = library.getWallpaperURL(for: item) {
                return original
            }
            if let path = library.getThumbnailPath(for: item), !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
            return nil
        }()

        guard let previewURL else { return facts }

        if let values = try? previewURL.resourceValues(forKeys: [.fileSizeKey]),
           let fileSize = values.fileSize, fileSize > 0 {
            facts.fileSizeText = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
        }

        switch item.type {
        case .video:
            let asset = AVAsset(url: previewURL)
            let duration = asset.duration.seconds
            if duration.isFinite, duration > 0 {
                facts.durationText = formatDuration(duration)
            }

            if let track = asset.tracks(withMediaType: .video).first {
                let size = track.naturalSize.applying(track.preferredTransform)
                let width = Int(abs(size.width.rounded()))
                let height = Int(abs(size.height.rounded()))
                if width > 0, height > 0 {
                    facts.resolutionText = "\(width)×\(height)"
                }
            }
        default:
            if let imageSource = CGImageSourceCreateWithURL(previewURL as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? Int,
               let height = properties[kCGImagePropertyPixelHeight] as? Int,
               width > 0, height > 0 {
                facts.resolutionText = "\(width)×\(height)"
            } else if let image = NSImage(contentsOf: previewURL),
                      let rep = image.representations.max(by: {
                          ($0.pixelsWide * $0.pixelsHigh) < ($1.pixelsWide * $1.pixelsHigh)
                      }),
                      rep.pixelsWide > 0, rep.pixelsHigh > 0 {
                facts.resolutionText = "\(rep.pixelsWide)×\(rep.pixelsHigh)"
            }
        }

        return facts
    }

    static func buildForWebWallpaper(rootURL: URL) -> WallpaperPreviewFacts {
        var facts = WallpaperPreviewFacts()

        if let previewURL = previewImageURL(in: rootURL),
           let imageSource = CGImageSourceCreateWithURL(previewURL as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int,
           width > 0, height > 0 {
            facts.resolutionText = "\(width)×\(height)"
        }

        if let entryFile = WallpaperEngineWebResolver.resolve(rootDirectory: rootURL)?.entryFile,
           let values = try? entryFile.resourceValues(forKeys: [.fileSizeKey]),
           let fileSize = values.fileSize,
           fileSize > 0 {
            facts.fileSizeText = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
        }

        return facts
    }

    private static func previewImageURL(in rootURL: URL) -> URL? {
        let candidates = ["preview.jpg", "preview.png", "cover/orig.jpg", "cover/orig.png"]
        for name in candidates {
            let candidate = rootURL.appendingPathComponent(name)
            let resolved = WallpaperEngineWebResolver.canonicalFilesystemURL(matching: candidate) ?? candidate
            if FileManager.default.fileExists(atPath: resolved.path) {
                return resolved
            }
        }
        return nil
    }

    private static func formatDuration(_ duration: Double) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes):" + String(format: "%02d", seconds)
    }
}

struct WallpaperPreviewOverlay: View {
    let item: WallpaperItem
    let library: WallpaperLibrary
    @ObservedObject var appDelegate: AppDelegate
    let startsInDetails: Bool
    let onClose: () -> Void

    @State private var previewImage: NSImage?
    @State private var previewFacts = WallpaperPreviewFacts()
    @State private var isLoadingPreview = true
    @State private var loadingProgress = 0.0
    @State private var isPreviewMetadataLoaded = false
    @State private var isWebPreviewLoaded = false
    @State private var isApplyingWallpaper = false
    @State private var applyingProgress = 0.0
    @State private var showDetails: Bool
    @State private var selectedDisplayID: String?
    @State private var showDisplayChooser = false
    @State private var previewLoadTask: Task<Void, Never>?
    @State private var previewProgressTask: Task<Void, Never>?
    @State private var applyingProgressTask: Task<Void, Never>?
    @State private var previewLoadToken = UUID()
    @State private var didStartPreviewLoad = false
    @ObservedObject private var displayManager = DisplayManager.shared

    init(
        item: WallpaperItem,
        library: WallpaperLibrary,
        appDelegate: AppDelegate,
        startsInDetails: Bool,
        onClose: @escaping () -> Void
    ) {
        self.item = item
        self.library = library
        self.appDelegate = appDelegate
        self.startsInDetails = startsInDetails
        self.onClose = onClose
        _showDetails = State(initialValue: startsInDetails)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                WallpaperPreviewBackdrop(
                    item: item,
                    library: library,
                    previewImage: previewImage,
                    webWallpaperRootURL: webWallpaperRootURL,
                    onWebPreviewLoadFinished: markWebPreviewLoaded
                )
                    .overlay(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.00),
                                Color.black.opacity(0.00),
                                Color.black.opacity(0.18)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .allowsHitTesting(false)
                    )
                    .ignoresSafeArea()

                VStack {
                    previewTopBar
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)

                VStack {
                    Spacer()

                    ZStack(alignment: .bottom) {
                        HStack {
                            Spacer()
                            previewDescription
                                .offset(x: -44)
                            Spacer()
                        }

                        HStack {
                            Spacer()

                            WallpaperSetControl(
                                displays: enabledDisplays,
                                selectedDisplayID: $selectedDisplayID,
                                showDisplayChooser: $showDisplayChooser,
                                showDetails: $showDetails,
                                isFavorite: library.isFavorite(item.id),
                                onToggleFavorite: { library.toggleFavorite(wallpaperID: item.id) },
                                onApply: applySelectedWallpaper
                            )
                            .frame(width: 318)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 22)

                if showDetails {
                    HStack {
                        Spacer()

                        WallpaperDetailPanel(
                            item: item,
                            library: library,
                            appDelegate: appDelegate,
                            onClose: {
                                showDetails = false
                                if !library.wallpapers.contains(where: { $0.id == item.id }) {
                                    onClose()
                                }
                            }
                        )
                        .frame(width: detailPanelWidth(for: proxy.size.width))
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.28), radius: 28, x: 0, y: 18)
                    }
                    .padding(.top, 70)
                    .padding(.trailing, 24)
                    .padding(.bottom, 108)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                if shouldShowPreviewLoadingRing {
                    PreviewLoadingRing(progress: loadingProgress, title: "Loading Preview")
                        .frame(width: 150, height: 250)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if isApplyingWallpaper {
                    PreviewLoadingRing(progress: applyingProgress, title: "Setting Wallpaper")
                        .frame(width: 150, height: 250)
                        .allowsHitTesting(true)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: startLoadingPreview)
        .onDisappear(perform: cancelPreviewTasks)
    }

    private func detailPanelWidth(for availableWidth: CGFloat) -> CGFloat {
        let paddedWidth = max(0, availableWidth - 48)
        guard availableWidth >= 780 else {
            return min(paddedWidth, 360)
        }
        return min(360, max(300, availableWidth * 0.34))
    }

    private var previewTopBar: some View {
        HStack {
            previewChromeButton(systemName: "chevron.left", isActive: false, label: "ギャラリーに戻る", hint: "プレビューを閉じてギャラリーへ戻ります", action: onClose)

            Spacer()
        }
    }

    private var previewDescription: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            if !previewFacts.visibleItems.isEmpty {
                HStack(spacing: 10) {
                    ForEach(previewFacts.visibleItems, id: \.self) { value in
                        Label(value, systemImage: previewFactIcon(for: value))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.72))
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.62))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.26), radius: 18, x: 0, y: 10)
        .frame(maxWidth: 420, alignment: .leading)
    }

    private func previewChromeButton(systemName: String, isActive: Bool, label: String, hint: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(
                    Circle()
                        .fill(Color.black.opacity(isActive ? 0.74 : 0.50))
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(hint ?? "")
    }

    private func previewFactIcon(for value: String) -> String {
        if value.contains("×") {
            return "rectangle.compress.vertical"
        }
        if value.contains(":") {
            return "clock"
        }
        return "internaldrive"
    }

    private var isWebWallpaper: Bool {
        webWallpaperRootURL != nil
    }

    private var previewUsesLiveRenderer: Bool {
        isWebWallpaper || item.type == .video || item.type == .gif
    }

    private var shouldShowPreviewLoadingRing: Bool {
        isLoadingPreview && !previewUsesLiveRenderer
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

    private var enabledDisplays: [DisplayInfo] {
        displayManager.connectedDisplays.filter { displayManager.isDisplayEnabled($0.id) }
    }

    private func applyWallpaper(completion: @escaping () -> Void) {
        WallpaperApplicator.apply(item: item, library: library, appDelegate: appDelegate, completion: completion)
    }

    private func applyWallpaper(to displayID: String, completion: @escaping () -> Void) {
        WallpaperApplicator.apply(item: item, library: library, appDelegate: appDelegate, to: displayID, completion: completion)
    }

    private func applySelectedWallpaper() {
        startApplyingWallpaper()
        let completion = {
            finishApplyingWallpaper()
        }
        if let selectedDisplayID {
            applyWallpaper(to: selectedDisplayID, completion: completion)
        } else {
            applyWallpaper(completion: completion)
        }
    }

    private func startLoadingPreview() {
        guard !didStartPreviewLoad else { return }
        didStartPreviewLoad = true
        cancelPreviewTasks()
        let loadToken = UUID()
        previewLoadToken = loadToken

        if let webRoot = webWallpaperRootURL {
            isLoadingPreview = false
            loadingProgress = 1
            previewImage = nil
            previewFacts = WallpaperPreviewFacts.buildForWebWallpaper(rootURL: webRoot)
            isPreviewMetadataLoaded = true
            isWebPreviewLoaded = true
            return
        }

        if item.type == .video || item.type == .gif {
            isLoadingPreview = false
            loadingProgress = 1
            previewImage = nil
            previewFacts = WallpaperPreviewFacts()
            isPreviewMetadataLoaded = false
            isWebPreviewLoaded = true

            previewLoadTask = Task {
                let snapshotItem = item
                let snapshotLibrary = library
                let loadedFacts = await Task.detached(priority: .utility) {
                    WallpaperPreviewFacts.build(for: snapshotItem, library: snapshotLibrary)
                }.value

                await MainActor.run {
                    guard previewLoadToken == loadToken else { return }
                    previewFacts = loadedFacts
                    isPreviewMetadataLoaded = true
                }
            }
            return
        }

        isLoadingPreview = true
        loadingProgress = 0
        previewImage = nil
        previewFacts = WallpaperPreviewFacts()
        isPreviewMetadataLoaded = false
        isWebPreviewLoaded = true

        previewProgressTask = Task {
            while !Task.isCancelled, loadingProgress < 0.92 {
                try? await Task.sleep(nanoseconds: 80_000_000)
                await MainActor.run {
                    guard isLoadingPreview else { return }
                    let remaining = max(0.02, 1 - loadingProgress)
                    loadingProgress = min(0.92, loadingProgress + remaining * 0.16)
                }
            }
        }

        previewLoadTask = Task {
            let snapshotItem = item
            let snapshotLibrary = library
            let loadedImage = await Task.detached(priority: .userInitiated) {
                    Self.loadPreviewImage(for: snapshotItem, library: snapshotLibrary)
            }.value

            let loadedFacts = await Task.detached(priority: .utility) {
                WallpaperPreviewFacts.build(for: snapshotItem, library: snapshotLibrary)
            }.value

            await MainActor.run {
                guard previewLoadToken == loadToken else { return }
                previewImage = loadedImage
                previewFacts = loadedFacts
                isPreviewMetadataLoaded = true
                loadingProgress = max(loadingProgress, 0.96)
                updatePreviewLoadingCompletion()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard previewLoadToken == loadToken, isLoadingPreview else { return }
            finishPreviewLoading()
        }
    }

    private func markWebPreviewLoaded() {
        guard webWallpaperRootURL != nil else { return }
        finishWebPreviewLoading()
    }

    private func finishWebPreviewLoading() {
        isWebPreviewLoaded = true
        isPreviewMetadataLoaded = true
        previewProgressTask?.cancel()
        withAnimation(.easeOut(duration: 0.16)) {
            loadingProgress = 1
            isLoadingPreview = false
        }
    }

    private func updatePreviewLoadingCompletion() {
        guard isLoadingPreview, isPreviewMetadataLoaded, isWebPreviewLoaded else { return }
        finishPreviewLoading()
    }

    private func finishPreviewLoading() {
        previewProgressTask?.cancel()
        withAnimation(.easeOut(duration: 0.18)) {
            loadingProgress = 1
            isLoadingPreview = false
        }
    }

    private func startApplyingWallpaper() {
        applyingProgressTask?.cancel()
        isApplyingWallpaper = true
        applyingProgress = 0

        applyingProgressTask = Task {
            while !Task.isCancelled, applyingProgress < 0.92 {
                try? await Task.sleep(nanoseconds: 30_000_000)
                await MainActor.run {
                    guard isApplyingWallpaper else { return }
                    let remaining = max(0.02, 1 - applyingProgress)
                    applyingProgress = min(0.92, applyingProgress + remaining * 0.30)
                }
            }
        }
    }

    private func finishApplyingWallpaper() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            applyingProgressTask?.cancel()
            withAnimation(.easeOut(duration: 0.12)) {
                applyingProgress = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                guard isApplyingWallpaper else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    isApplyingWallpaper = false
                }
                applyingProgress = 0
            }
        }
    }

    private func cancelPreviewTasks() {
        previewLoadTask?.cancel()
        previewProgressTask?.cancel()
        applyingProgressTask?.cancel()
        previewLoadTask = nil
        previewProgressTask = nil
        applyingProgressTask = nil
    }

    private nonisolated static func loadPreviewImage(for item: WallpaperItem, library: WallpaperLibrary) -> NSImage? {
        if let originalURL = library.getWallpaperURL(for: item), item.type != .video {
            if let image = NSImage(contentsOf: originalURL) {
                return image
            }
        }
        return library.getThumbnailImage(for: item)
    }
}

private struct WallpaperPreviewBackdrop: View {
    let item: WallpaperItem
    let library: WallpaperLibrary
    let previewImage: NSImage?
    let webWallpaperRootURL: URL?
    let onWebPreviewLoadFinished: () -> Void

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let webWallpaperRootURL,
                   let musicView = MusicWallpaperView(rootURL: webWallpaperRootURL) {
                    // 音楽プレイヤー型 Workshop 壁紙は、難読化 JS が WKWebView 上で動かないため
                    // WallBlank ネイティブの SwiftUI プレイヤーで描画する。
                    musicView
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .onAppear { onWebPreviewLoadFinished() }
                } else if let webWallpaperRootURL {
                    WebWallpaperPreviewView(
                        rootURL: webWallpaperRootURL,
                        onLoadFinished: onWebPreviewLoadFinished
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                } else if item.type == .video || item.type == .gif {
                    ThumbnailVideoPreview(item: item, library: library)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else if let previewImage {
                    Image(nsImage: previewImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.18, green: 0.21, blue: 0.24),
                                    Color(red: 0.10, green: 0.12, blue: 0.14)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            Image(systemName: item.type.icon)
                                .font(.system(size: 54, weight: .light))
                                .foregroundStyle(.white.opacity(0.30))
                        )
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .clipped()
            .ignoresSafeArea()
        }
    }
}
