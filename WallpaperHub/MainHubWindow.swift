import SwiftUI
import MetalKit
import UniformTypeIdentifiers

/// サイドバーのタブ
enum SidebarTab: String, CaseIterable {
    case gallery = "ギャラリー"
    case collections = "コレクション"
    case playlist = "プレイリスト"
    case store = "ストア"
    case settings = "設定"
    case profile = "プロフィール"
    case admin = "管理者"

    var icon: String {
        switch self {
        case .gallery: return "photo.stack"
        case .collections: return "heart.text.square"
        case .playlist: return "list.bullet.rectangle"
        case .store: return "globe"
        case .settings: return "gearshape"
        case .profile: return "person.crop.circle"
        case .admin: return "shield.lefthalf.filled"
        }
    }

    /// 管理者モード以外で表示するタブ
    static var standardTabs: [SidebarTab] {
        [.gallery, .collections, .playlist, .store]
    }

    /// 管理者モード時に表示するタブ
    static var adminTabs: [SidebarTab] {
        [.gallery, .collections, .playlist, .store, .admin]
    }
}

/// メインのArtiaウィンドウ
struct MainHubWindowContent: View {
    @ObservedObject var appDelegate: AppDelegate
    @ObservedObject var library: WallpaperLibrary
    @ObservedObject private var authManager = AuthManager.shared
    @ObservedObject private var appLockManager = AppLockManager.shared
    @Environment(\.openWindow) private var openWindow
    let previewRenderer: Renderer?
    let device: MTLDevice?

    @State private var selectedTab: SidebarTab = .gallery
    @State private var selectedCategory = "All"
    @State private var searchText = ""
    @State private var showingImportTagDialog = false
    @State private var pendingImportURLs: [URL] = []
    @State private var selectedCollectionID: String? = "favorites"
    @State private var showingCreateCollection = false
    @State private var newCollectionName = ""
    @State private var editingCollectionID: String?
    @State private var editingCollectionName = ""
    @State private var showingCommunitySubmit = false
    @State private var showingWallpaperDropHint = false
    @State private var isGalleryPreviewPresented = false

    var body: some View {
        ZStack {
            HubWindowBackground()

            VStack(spacing: 0) {
                if !isGalleryPreviewPresented {
                    contentHeader
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                currentContent
            }
        }
        .frame(minWidth: 500, minHeight: 300)
        .animation(.easeOut(duration: 0.18), value: isGalleryPreviewPresented)
        .sheet(isPresented: $showingImportTagDialog) {
            ImportTagDialogView(
                urls: pendingImportURLs,
                library: library,
                isPresented: $showingImportTagDialog
            )
        }
    }

    // MARK: - Gallery Content

    private var galleryContent: some View {
        ZStack(alignment: .bottomLeading) {
            WallpaperGalleryView(
                library: library,
                appDelegate: appDelegate,
                selectedCategory: $selectedCategory,
                isPreviewPresented: $isGalleryPreviewPresented,
                searchText: searchText
            )
            .overlay(alignment: .top) {
                if showingWallpaperDropHint {
                    Text("ここにフォルダ/ファイルをドロップして壁紙にできます")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                        .padding(.top, 12)
                }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $showingWallpaperDropHint) { providers in
                handleWallpaperDrop(providers)
            }

            // フォルダを開くボタン（左下）
            Button(action: { library.openWallpaperDirectory() }) {
                Label("フォルダを開く", systemImage: "folder")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(12)
        }
    }

    private var contentHeader: some View {
        ViewThatFits(in: .horizontal) {
            wideHeaderLayout
            compactHeaderLayout
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(0.09),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 6)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private var wideHeaderLayout: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                headerBrand
                headerTabsRow
                    .frame(maxWidth: .infinity)
                headerUtilityButtons
            }

            contextualHeader(compact: false)
        }
    }

    private var compactHeaderLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                headerBrand
                Spacer(minLength: 0)
                headerUtilityButtons
            }

            headerTabsRow

            contextualHeader(compact: true)
        }
    }

    private var headerTabsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(visibleTabs, id: \.self) { tab in
                    HeaderTabButton(
                        icon: tab.icon,
                        title: tab.rawValue,
                        isSelected: selectedTab == tab,
                        action: {
                            selectedTab = tab
                            if tab != .collections {
                                showingCreateCollection = false
                                editingCollectionID = nil
                            }
                        },
                        badgeColor: tab == .admin ? .orange : nil
                    )
                }

            }
        }
    }

    private var headerUtilityButtons: some View {
        HStack(spacing: 8) {
            HeaderDisplayArrangementButton(
                appDelegate: appDelegate,
                displayManager: appDelegate.displayManager
            )
            HeaderSettingsButton(selectedTab: $selectedTab)
            HeaderAccountButton(selectedTab: $selectedTab)
            HeaderPowerMenuButton(appDelegate: appDelegate, appLockManager: appLockManager)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var currentContent: some View {
        if selectedTab == .gallery {
            galleryContent
        } else if selectedTab == .collections {
            collectionsContent
        } else if selectedTab == .playlist {
            PlaylistEditorView(manager: PlaylistManager.shared, library: library)
        } else if selectedTab == .store {
            storeContent
        } else if selectedTab == .profile {
            profileContent
        } else if selectedTab == .admin && authManager.isAdminMode {
            adminContent
        } else {
            settingsContent
        }
    }

    private var visibleTabs: [SidebarTab] {
        authManager.isAdminMode ? SidebarTab.adminTabs : SidebarTab.standardTabs
    }

    private var headerBrand: some View {
        HStack(spacing: 10) {
            Image(systemName: authManager.isAdminMode ? "shield.lefthalf.filled" : "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text("Artia")
                .font(.system(size: 20, weight: .semibold))

            if authManager.isAdminMode {
                Text("管理者モード")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.12), in: Capsule())
            }
        }
    }

    @ViewBuilder
    private func contextualHeader(compact: Bool) -> some View {
        switch selectedTab {
        case .gallery:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    searchField(expands: compact)
                    galleryCategoryMenu
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 8) {
                    searchField(expands: true)
                    galleryCategoryMenu
                }
            }
        case .collections:
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(library.collections) { collection in
                            if editingCollectionID == collection.id {
                                editingCollectionChip(for: collection)
                            } else {
                                collectionChip(for: collection)
                            }
                        }
                    }
                }

                HStack(spacing: 12) {
                    if showingCreateCollection {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.accentColor)

                            TextField("新しいコレクション名", text: $newCollectionName)
                                .textFieldStyle(.plain)
                                .frame(minWidth: 180)
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
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                    } else {
                        HeaderActionButton(
                            title: "新規コレクション",
                            icon: "plus.circle",
                            style: .secondary,
                            action: { showingCreateCollection = true }
                        )
                    }

                    Spacer()
                }
            }
        case .store:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    HeaderFilterChip(title: "注目", icon: "star.fill", isSelected: true, action: {})
                    HeaderFilterChip(title: "コミュニティ", icon: "person.2.fill", isSelected: false, action: {})
                    HeaderActionButton(
                        title: "壁紙を投稿",
                        icon: "paperplane",
                        style: .primary,
                        action: { showingCommunitySubmit = true }
                    )
                }
            }
        case .admin:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    HeaderFilterChip(title: "未承認", icon: "clock.badge.questionmark", isSelected: true, action: {})
                    HeaderFilterChip(title: "報告", icon: "exclamationmark.triangle", isSelected: false, action: {})
                    HeaderFilterChip(title: "ユーザー", icon: "person.3", isSelected: false, action: {})
                }
            }
        case .settings:
            compactHeaderLabel("設定")
        case .profile:
            compactHeaderLabel("プロフィール")
        case .playlist:
            compactHeaderLabel("プレイリスト")
        }
    }

    private func searchField(expands: Bool) -> some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("名前やタグで検索...", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .frame(maxWidth: expands ? .infinity : 360, alignment: .leading)
    }

    private var galleryCategoryMenu: some View {
        Menu {
            Button(action: { selectedCategory = "All" }) {
                categoryMenuItem(title: "All", icon: "square.grid.2x2", isSelected: selectedCategory == "All")
            }

            if !library.categories.isEmpty {
                Divider()
            }

            ForEach(library.categories, id: \.self) { category in
                Button(action: { selectedCategory = category }) {
                    categoryMenuItem(
                        title: category,
                        icon: WallpaperCategoryIcon.icon(for: category),
                        isSelected: selectedCategory == category
                    )
                }
            }
        } label: {
            HeaderMenuChip(
                title: selectedCategory == "All" ? "All" : selectedCategory,
                icon: "square.grid.2x2",
                isHighlighted: selectedCategory != "All"
            )
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
    }

    private func categoryMenuItem(title: String, icon: String, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark" : icon)
                .frame(width: 14)
            Text(title)
        }
    }

    private func compactHeaderLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func collectionChip(for collection: WallpaperCollection) -> some View {
        HeaderCollectionChip(
            title: collection.name,
            icon: collection.icon,
            count: collection.wallpaperIDs.count,
            isSelected: selectedCollectionID == collection.id,
            action: {
                selectedCollectionID = collection.id
                editingCollectionID = nil
            }
        )
        .contextMenu {
            if !collection.isSystem {
                Button("名前を変更") {
                    editingCollectionID = collection.id
                    editingCollectionName = collection.name
                    showingCreateCollection = false
                }

                Divider()

                Button("削除", role: .destructive) {
                    library.deleteCollection(id: collection.id)
                    if selectedCollectionID == collection.id {
                        selectedCollectionID = "favorites"
                    }
                }
            }
        }
    }

    private func editingCollectionChip(for collection: WallpaperCollection) -> some View {
        HStack(spacing: 8) {
            Image(systemName: collection.icon)
                .foregroundColor(.accentColor)

            TextField("名前", text: $editingCollectionName)
                .textFieldStyle(.plain)
                .frame(minWidth: 120)
                .onSubmit {
                    renameCollection(collection)
                }

            Button(action: { renameCollection(collection) }) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(editingCollectionName.trimmingCharacters(in: .whitespaces).isEmpty)

            Button(action: {
                editingCollectionID = nil
                editingCollectionName = ""
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func handleWallpaperDrop(_ providers: [NSItemProvider]) -> Bool {
        let typeID = UTType.fileURL.identifier
        var accepted = false

        for provider in providers where provider.hasItemConformingToTypeIdentifier(typeID) {
            accepted = true
            provider.loadItem(forTypeIdentifier: typeID, options: nil) { item, _ in
                let url: URL? = {
                    if let data = item as? Data {
                        return URL(dataRepresentation: data, relativeTo: nil)
                    }
                    if let url = item as? URL {
                        return url
                    }
                    return nil
                }()

                guard let url else { return }
                DispatchQueue.main.async {
                    appDelegate.setBackgroundImage(url: url)
                }
            }
        }

        return accepted
    }

    // MARK: - Collections Content

    private var collectionsContent: some View {
        CollectionContentView(
            library: library,
            appDelegate: appDelegate,
            selectedCollectionID: $selectedCollectionID
        )
    }

    // MARK: - Store Content

    private var storeContent: some View {
        OnlineGalleryView()
            .sheet(isPresented: $showingCommunitySubmit) {
                CommunitySubmitView(isPresented: $showingCommunitySubmit)
            }
    }

    // MARK: - Profile Content

    private var profileContent: some View {
        ProfilePageView()
    }

    // MARK: - Admin Content

    private var adminContent: some View {
        AdminDashboardView()
    }

    // MARK: - Settings Content

    private var settingsContent: some View {
        SettingsView(
            displayManager: appDelegate.displayManager,
            performanceMonitor: appDelegate.performanceMonitor,
            appDelegate: appDelegate
        )
    }

    // MARK: - Actions

    private func importWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, !panel.urls.isEmpty {
            pendingImportURLs = panel.urls
            showingImportTagDialog = true
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

    private func renameCollection(_ collection: WallpaperCollection) {
        let trimmed = editingCollectionName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        library.renameCollection(id: collection.id, name: trimmed)
        editingCollectionID = nil
        editingCollectionName = ""
    }
}

// MARK: - Header Components

struct HeaderTabButton: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void
    var badgeColor: Color? = nil

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                    .foregroundColor(iconForegroundColor)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(backgroundShape)
            .foregroundColor(labelForegroundColor)
        }
        .buttonStyle(.plain)
    }

    private var backgroundShape: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isSelected ? Color.white.opacity(0.14) : Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.white.opacity(0.14) : Color.white.opacity(0.07), lineWidth: 1)
            )
    }

    private var labelForegroundColor: Color {
        isSelected ? .primary : .primary.opacity(0.88)
    }

    private var iconForegroundColor: Color {
        isSelected ? (badgeColor ?? .primary) : (badgeColor ?? .secondary)
    }
}

enum HeaderActionButtonStyle {
    case primary
    case secondary
}

struct HeaderActionButton: View {
    let title: String
    let icon: String
    let style: HeaderActionButtonStyle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .foregroundColor(foregroundColor)
                .background(backgroundShape)
                .cornerRadius(14)
        }
        .buttonStyle(.plain)
    }

    private var foregroundColor: Color {
        style == .primary ? .white : .primary.opacity(0.88)
    }

    private var backgroundShape: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(style == .primary ? Color.accentColor.opacity(0.88) : Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(style == .primary ? Color.accentColor.opacity(0.22) : Color.white.opacity(0.07), lineWidth: 1)
            )
    }
}

struct HeaderFilterChip: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.white.opacity(0.14) : Color.white.opacity(0.06), lineWidth: 1)
            )
            .foregroundColor(isSelected ? .primary : .primary.opacity(0.82))
        }
        .buttonStyle(.plain)
    }
}

struct HeaderMenuChip: View {
    let title: String
    let icon: String
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHighlighted ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isHighlighted ? Color.white.opacity(0.14) : Color.white.opacity(0.06), lineWidth: 1)
        )
        .foregroundColor(isHighlighted ? .primary : .primary.opacity(0.82))
    }
}

struct HeaderCollectionChip: View {
    let title: String
    let icon: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text("\(count)")
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? .primary.opacity(0.8) : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.white.opacity(0.14) : Color.white.opacity(0.06), lineWidth: 1)
            )
            .foregroundColor(isSelected ? .primary : .primary.opacity(0.88))
        }
        .buttonStyle(.plain)
    }
}

struct HeaderDisplayArrangementButton: View {
    @ObservedObject var appDelegate: AppDelegate
    @ObservedObject var displayManager: DisplayManager
    @State private var isPresented = false

    var body: some View {
        Button(action: { isPresented.toggle() }) {
            Image(systemName: displayManager.spanWallpaperAcrossDisplays ? "rectangle.3.group.fill" : "display.2")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 38, height: 38)
                .background(buttonBackground)
                .foregroundColor(isPresented || displayManager.spanWallpaperAcrossDisplays ? .primary : .primary.opacity(0.88))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            DisplayArrangementPopover(
                appDelegate: appDelegate,
                displayManager: displayManager
            )
        }
        .help("ディスプレイ配置")
    }

    private var buttonBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isPresented || displayManager.spanWallpaperAcrossDisplays ? Color.white.opacity(0.14) : Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isPresented || displayManager.spanWallpaperAcrossDisplays ? Color.white.opacity(0.14) : Color.white.opacity(0.07), lineWidth: 1)
            )
    }
}

private struct DisplayArrangementPopover: View {
    @ObservedObject var appDelegate: AppDelegate
    @ObservedObject var displayManager: DisplayManager
    @State private var selectedDisplayID: String?
    @State private var draftArrangement: [String: DisplayLayoutConfiguration] = [:]
    @State private var canvasBounds: CGRect?

    private var selectedDisplay: DisplayInfo? {
        guard let selectedDisplayID else { return nil }
        return displayManager.connectedDisplays.first { $0.id == selectedDisplayID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Label("ディスプレイ配置", systemImage: "display.2")
                    .font(.system(size: 17, weight: .semibold))

                Spacer()

                Toggle(isOn: Binding(
                    get: { displayManager.spanWallpaperAcrossDisplays },
                    set: { displayManager.setSpanWallpaperAcrossDisplays($0) }
                )) {
                    Text("一枚の壁紙")
                        .font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.switch)

                Button(action: resetArrangement) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .help("システム配置に戻す")
            }

            DisplayArrangementCanvas(
                displays: displayManager.connectedDisplays,
                arrangement: draftArrangement,
                canvasBounds: canvasBounds,
                enabledIDs: displayManager.enabledDisplayIDs,
                selectedDisplayID: $selectedDisplayID,
                wallpaperPath: wallpaperPath(for:),
                onMove: moveDisplay(_:to:),
                onCommit: commitDraftArrangement
            )
            .frame(height: 270)

            selectedDisplayControls
        }
        .padding(18)
        .frame(width: 700)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor))
        )
        .onAppear(perform: refreshDraftArrangement)
        .onChange(of: displayManager.connectedDisplays) { _ in
            refreshDraftArrangement()
        }
    }

    @ViewBuilder
    private var selectedDisplayControls: some View {
        if let display = selectedDisplay {
            HStack(spacing: 12) {
                Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                    .font(.system(size: 18))
                    .foregroundColor(.accentColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(display.localizedName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("\(Int(display.resolution.width)) x \(Int(display.resolution.height))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Toggle(isOn: Binding(
                    get: { displayManager.isDisplayEnabled(display.id) },
                    set: { displayManager.setDisplayEnabled(display.id, enabled: $0) }
                )) {
                    Text("表示")
                        .font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.switch)

                Button(action: { appDelegate.clearBackgroundImage(for: display.id) }) {
                    Label("解除", systemImage: "xmark.circle")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            HStack(spacing: 8) {
                Image(systemName: "hand.tap")
                    .foregroundColor(.secondary)
                Text("ディスプレイを選択")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func wallpaperPath(for display: DisplayInfo) -> String? {
        appDelegate.displayBackgroundPaths[display.id]
            ?? appDelegate.settings.backgroundImagePath
    }

    private func refreshDraftArrangement() {
        var arrangement = displayManager.displayArrangement
        for display in displayManager.connectedDisplays where arrangement[display.id] == nil {
            arrangement[display.id] = DisplayLayoutConfiguration(display: display)
        }
        draftArrangement = arrangement
        canvasBounds = Self.editableCanvasBounds(for: arrangement)
        if selectedDisplayID == nil {
            selectedDisplayID = displayManager.connectedDisplays.first?.id
        }
    }

    private func moveDisplay(_ displayID: String, to origin: CGPoint) {
        guard var layout = draftArrangement[displayID] else { return }
        layout.move(to: origin)
        draftArrangement[displayID] = layout
        expandCanvasBoundsIfNeeded(for: layout.rect)
    }

    private func commitDraftArrangement() {
        displayManager.setDisplayArrangement(draftArrangement)
    }

    private func resetArrangement() {
        displayManager.resetDisplayArrangementToSystem()
        refreshDraftArrangement()
    }

    private func expandCanvasBoundsIfNeeded(for rect: CGRect) {
        guard let currentBounds = canvasBounds else {
            canvasBounds = rect.insetBy(dx: -500, dy: -320)
            return
        }

        let fitsHorizontally = currentBounds.minX <= rect.minX && currentBounds.maxX >= rect.maxX
        let fitsVertically = currentBounds.minY <= rect.minY && currentBounds.maxY >= rect.maxY
        guard !fitsHorizontally || !fitsVertically else { return }

        canvasBounds = currentBounds.union(rect).insetBy(dx: -160, dy: -120)
    }

    private static func editableCanvasBounds(for arrangement: [String: DisplayLayoutConfiguration]) -> CGRect {
        let base = boundingRect(for: arrangement.values.map(\.rect))
        let paddingX = max(base.width * 0.6, 500)
        let paddingY = max(base.height * 0.6, 320)
        return base.insetBy(dx: -paddingX, dy: -paddingY)
    }

    private static func boundingRect(for rects: [CGRect]) -> CGRect {
        guard let first = rects.first else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return rects.dropFirst().reduce(first) { partial, rect in
            partial.union(rect)
        }
    }
}

private struct DisplayArrangementCanvas: View {
    let displays: [DisplayInfo]
    let arrangement: [String: DisplayLayoutConfiguration]
    let canvasBounds: CGRect?
    let enabledIDs: Set<String>
    @Binding var selectedDisplayID: String?
    let wallpaperPath: (DisplayInfo) -> String?
    let onMove: (String, CGPoint) -> Void
    let onCommit: () -> Void
    @State private var dragStartOrigins: [String: CGPoint] = [:]

    var body: some View {
        GeometryReader { proxy in
            let layouts = displays.map { layout(for: $0) }
            let bounds = canvasBounds ?? Self.boundingRect(for: layouts)
            let metrics = Self.metrics(for: bounds, in: proxy.size)

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )

                if displays.isEmpty {
                    Text("ディスプレイが見つかりません")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(displays) { display in
                        let layout = layout(for: display)
                        let rect = metrics.canvasRect(for: layout.rect)

                        DisplayArrangementTile(
                            display: display,
                            isEnabled: enabledIDs.contains(display.id),
                            isSelected: selectedDisplayID == display.id,
                            wallpaperPath: wallpaperPath(display)
                        )
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedDisplayID = display.id
                        }
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { value in
                                    selectedDisplayID = display.id
                                    if dragStartOrigins[display.id] == nil {
                                        dragStartOrigins[display.id] = CGPoint(x: layout.x, y: layout.y)
                                    }
                                    guard let start = dragStartOrigins[display.id] else { return }
                                    onMove(
                                        display.id,
                                        CGPoint(
                                            x: start.x + value.translation.width / metrics.scale,
                                            y: start.y + value.translation.height / metrics.scale
                                        )
                                    )
                                }
                                .onEnded { _ in
                                    dragStartOrigins[display.id] = nil
                                    onCommit()
                                }
                        )
                    }
                }
            }
        }
    }

    private func layout(for display: DisplayInfo) -> DisplayLayoutConfiguration {
        arrangement[display.id] ?? DisplayLayoutConfiguration(display: display)
    }

    private static func boundingRect(for layouts: [DisplayLayoutConfiguration]) -> CGRect {
        guard let first = layouts.first?.rect else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return layouts.dropFirst().reduce(first) { partial, layout in
            partial.union(layout.rect)
        }
    }

    private static func metrics(for bounds: CGRect, in size: CGSize) -> DisplayArrangementCanvasMetrics {
        let padding: CGFloat = 34
        let availableWidth = max(size.width - padding * 2, 1)
        let availableHeight = max(size.height - padding * 2, 1)
        let scale = max(0.02, min(availableWidth / max(bounds.width, 1), availableHeight / max(bounds.height, 1)))
        let contentSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let origin = CGPoint(
            x: (size.width - contentSize.width) / 2,
            y: (size.height - contentSize.height) / 2
        )
        return DisplayArrangementCanvasMetrics(bounds: bounds, scale: scale, origin: origin)
    }
}

private struct DisplayArrangementCanvasMetrics {
    let bounds: CGRect
    let scale: CGFloat
    let origin: CGPoint

    func canvasRect(for rect: CGRect) -> CGRect {
        CGRect(
            x: origin.x + (rect.minX - bounds.minX) * scale,
            y: origin.y + (rect.minY - bounds.minY) * scale,
            width: max(rect.width * scale, 48),
            height: max(rect.height * scale, 34)
        )
    }
}

private struct DisplayArrangementTile: View {
    let display: DisplayInfo
    let isEnabled: Bool
    let isSelected: Bool
    let wallpaperPath: String?

    private var previewImage: NSImage? {
        guard let wallpaperPath, !wallpaperPath.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: wallpaperPath, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        return NSImage(contentsOfFile: wallpaperPath)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.17, green: 0.50, blue: 0.78),
                        Color(red: 0.05, green: 0.30, blue: 0.46),
                        Color(red: 0.06, green: 0.55, blue: 0.60)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            if !isEnabled {
                Color.black.opacity(0.48)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                        .font(.system(size: 10, weight: .bold))
                    Text(display.localizedName)
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }

                Text(display.isMain ? "メイン" : "\(Int(display.resolution.width)) x \(Int(display.resolution.height))")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .opacity(0.82)
            }
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)
            .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.white.opacity(0.20), lineWidth: isSelected ? 3 : 1)
        )
        .shadow(color: .black.opacity(isSelected ? 0.28 : 0.16), radius: isSelected ? 12 : 7, x: 0, y: 5)
        .opacity(isEnabled ? 1 : 0.72)
    }
}

struct HeaderSettingsButton: View {
    @Binding var selectedTab: SidebarTab

    var body: some View {
        Button(action: { selectedTab = .settings }) {
            Image(systemName: "gearshape")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 38, height: 38)
                .background(buttonBackground)
                .foregroundColor(selectedTab == .settings ? .primary : .primary.opacity(0.88))
        }
        .buttonStyle(.plain)
        .help("設定")
    }

    private var buttonBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(selectedTab == .settings ? Color.white.opacity(0.14) : Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selectedTab == .settings ? Color.white.opacity(0.14) : Color.white.opacity(0.07), lineWidth: 1)
            )
    }
}

struct HeaderAccountButton: View {
    @ObservedObject private var authManager = AuthManager.shared
    @Binding var selectedTab: SidebarTab
    @State private var showingAuthView = false

    var body: some View {
        Group {
            if let profile = authManager.currentProfile, authManager.isAuthenticated {
                signedInView(profile: profile)
            } else {
                signedOutView
            }
        }
        .sheet(isPresented: $showingAuthView) {
            AuthView(isPresented: $showingAuthView)
        }
    }

    private func signedInView(profile: UserProfile) -> some View {
        Button(action: { selectedTab = .profile }) {
            HStack(spacing: 8) {
                Group {
                    if let customImage = profile.resolvedAvatarImage {
                        Image(nsImage: customImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        AsyncImage(url: URL(string: profile.photoURL ?? "")) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            default:
                                Image(systemName: "person.circle.fill")
                                    .resizable()
                                    .foregroundColor(.secondary.opacity(0.5))
                            }
                        }
                    }
                }
                .frame(width: 26, height: 26)
                .clipShape(Circle())

                Text(profile.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(buttonBackground(isSelected: selectedTab == .profile))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var signedOutView: some View {
        Button(action: { showingAuthView = true }) {
            HStack(spacing: 6) {
                Image(systemName: "person.circle")
                    .font(.system(size: 14))
                Text("ログイン")
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(buttonBackground(isSelected: false))
        }
        .buttonStyle(.plain)
        .foregroundColor(.primary.opacity(0.86))
    }

    private func buttonBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isSelected ? Color.white.opacity(0.14) : Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.white.opacity(0.14) : Color.white.opacity(0.07), lineWidth: 1)
            )
    }
}

struct HeaderPowerMenuButton: View {
    @ObservedObject var appDelegate: AppDelegate
    @ObservedObject var appLockManager: AppLockManager

    var body: some View {
        Menu {
            Button {
                if appLockManager.isLocked {
                    appLockManager.unlock(using: appDelegate)
                } else {
                    appLockManager.lock(using: appDelegate)
                }
            } label: {
                Label(appLockManager.isLocked ? "ロックを解除" : "ロック", systemImage: appLockManager.isLocked ? "lock.open" : "lock")
            }
            .disabled(appLockManager.isAuthenticating)

            Divider()

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Artia を終了", systemImage: "power")
            }
        } label: {
            Image(systemName: appLockManager.isLocked ? "lock.fill" : "power")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 38, height: 38)
                .background(buttonBackground)
                .foregroundColor(appLockManager.isLocked ? .primary : .primary.opacity(0.88))
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .help(appLockManager.isLocked ? "ロックを解除" : "ロックと終了")
    }

    private var buttonBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(appLockManager.isLocked ? Color.white.opacity(0.14) : Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(appLockManager.isLocked ? Color.white.opacity(0.14) : Color.white.opacity(0.07), lineWidth: 1)
            )
    }
}

struct HubWindowBackground: View {
    var body: some View {
        ZStack {
            VisualEffectView()

            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.08, blue: 0.10).opacity(0.92),
                    Color(red: 0.09, green: 0.11, blue: 0.13).opacity(0.88),
                    Color(red: 0.05, green: 0.06, blue: 0.08).opacity(0.92)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
