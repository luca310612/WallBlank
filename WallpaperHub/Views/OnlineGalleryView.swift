import SwiftUI

/// オンラインギャラリービュー（ストアタブ）
struct OnlineGalleryView: View {
    @ObservedObject var galleryManager: GalleryManager
    @ObservedObject var authManager: AuthManager
    @ObservedObject var library: WallpaperLibrary

    /// プレビューモードフラグ（.taskのFirebase呼び出しを抑制）
    private let isPreview: Bool

    init(
        galleryManager: GalleryManager = .shared,
        authManager: AuthManager = .shared,
        library: WallpaperLibrary = .shared,
        isPreview: Bool = false
    ) {
        self.galleryManager = galleryManager
        self.authManager = authManager
        self.library = library
        self.isPreview = isPreview
    }

    @State private var searchText = ""
    @State private var selectedCategory: String?
    @State private var selectedItem: GalleryItem?
    @State private var showSubmitSheet = false
    @State private var showAuthSheet = false

    var body: some View {
        Group {
            if authManager.isAuthenticated {
                galleryContent
            } else {
                loginPrompt
            }
        }
        .sheet(isPresented: $showAuthSheet) {
            AuthView(isPresented: $showAuthSheet)
        }
        .sheet(isPresented: $showSubmitSheet) {
            CommunitySubmitView(isPresented: $showSubmitSheet)
        }
        .onChange(of: showSubmitSheet) { _, newValue in
            guard !isPreview else { return }
            if !newValue {
                Task { await galleryManager.fetchCommunity() }
            }
        }
        .onChange(of: authManager.isAuthenticated) { _, isAuth in
            guard !isPreview else { return }
            if isAuth {
                Task {
                    await galleryManager.checkFirebaseAvailability()
                    await galleryManager.fetchFeatured()
                    await galleryManager.fetchCommunity()
                }
            }
        }
    }

    // MARK: - ログイン促進画面

    private var loginPrompt: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 56))
                .foregroundColor(.accentColor.opacity(0.6))

            Text("ログインしてコミュニティに参加")
                .font(.system(size: 18, weight: .semibold))

            Text("壁紙の閲覧・ダウンロード・投稿には\nアカウントが必要です")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 10) {
                Button(action: { showAuthSheet = true }) {
                    Label("ログイン / 新規登録", systemImage: "person.fill")
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: 240)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - ギャラリーコンテンツ

    private var galleryContent: some View {
        VStack(spacing: 0) {
            // ヘッダー
            HStack(spacing: 16) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("壁紙を検索...", text: $searchText)
                        .textFieldStyle(.plain)
                        .onSubmit { performSearch() }
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .frame(maxWidth: 300)

                Spacer()

                Button(action: { showSubmitSheet = true }) {
                    Label("投稿", systemImage: "square.and.arrow.up")
                        .font(.system(size: 13))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: {
                    Task {
                        await galleryManager.fetchFeatured()
                        await galleryManager.fetchCommunity()
                    }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if galleryManager.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("読み込み中...")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = galleryManager.errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.3))
                    Text("接続エラー")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.secondary)
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)

                    Button(action: {
                        galleryManager.errorMessage = nil
                        Task {
                            await galleryManager.fetchFeatured()
                            await galleryManager.fetchCommunity()
                        }
                    }) {
                        Label("再試行", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if galleryManager.featuredWallpapers.isEmpty && galleryManager.communityWallpapers.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if !galleryManager.featuredWallpapers.isEmpty {
                            sectionHeader(title: "注目", icon: "star.fill")
                            galleryGrid(items: galleryManager.featuredWallpapers)
                        }

                        if !galleryManager.communityWallpapers.isEmpty {
                            sectionHeader(title: "コミュニティ", icon: "person.2.fill")
                            galleryGrid(items: galleryManager.communityWallpapers)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .task {
            guard !isPreview else { return }
            debugLog("[Gallery] ストアタブ表示: isFirebaseAvailable=\(galleryManager.isFirebaseAvailable), isAuthenticated=\(authManager.isAuthenticated)")
            await galleryManager.checkFirebaseAvailability()
            debugLog("[Gallery] Firebase確認後: isFirebaseAvailable=\(galleryManager.isFirebaseAvailable)")
            await galleryManager.fetchFeatured()
            await galleryManager.fetchCommunity()
        }
    }

    private func sectionHeader(title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.accentColor)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
        }
    }

    private func galleryGrid(items: [GalleryItem]) -> some View {
        let columns = [GridItem(.adaptive(minimum: 220, maximum: 220), spacing: 16)]
        return LazyVGrid(columns: columns, spacing: 16) {
            ForEach(items) { item in
                OnlineGalleryThumbnail(
                    item: item,
                    onDownload: { downloadItem(item) },
                    onLike: { likeItem(item) },
                    galleryManager: galleryManager,
                    isPreview: isPreview,
                    isAdmin: authManager.isAdminMode
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.3))
            Text("まだ壁紙がありません")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.secondary)
            Text("最初の壁紙を投稿してコミュニティを盛り上げましょう！")
                .font(.system(size: 13))
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)

            // 接続状態の表示
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(galleryManager.isFirebaseAvailable ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(galleryManager.isFirebaseAvailable ? "Firebase接続済み" : "Firebase未接続")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(authManager.isAuthenticated ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(authManager.isAuthenticated ? "ログイン済み" : "未ログイン")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)

            HStack(spacing: 12) {
                Button(action: { showSubmitSheet = true }) {
                    Label("壁紙を投稿", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)

                Button(action: {
                    Task {
                        await galleryManager.checkFirebaseAvailability()
                        await galleryManager.fetchFeatured()
                        await galleryManager.fetchCommunity()
                    }
                }) {
                    Label("再読み込み", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @State private var searchResults: [GalleryItem] = []
    @State private var isSearching = false

    private func performSearch() {
        guard !searchText.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        Task {
            let results = await galleryManager.search(query: searchText)
            await MainActor.run {
                searchResults = results
            }
        }
    }

    private func downloadItem(_ item: GalleryItem) {
        Task {
            do {
                try await galleryManager.downloadWallpaper(item)
            } catch {
                await MainActor.run {
                    galleryManager.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func likeItem(_ item: GalleryItem) {
        Task {
            do {
                try await galleryManager.likeWallpaper(id: item.id)
            } catch {
                await MainActor.run {
                    galleryManager.errorMessage = "いいねに失敗しました: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - ギャラリーサムネイル

struct OnlineGalleryThumbnail: View {
    let item: GalleryItem
    let onDownload: () -> Void
    let onLike: () -> Void
    @ObservedObject var galleryManager: GalleryManager
    let isPreview: Bool
    let isAdmin: Bool

    init(
        item: GalleryItem,
        onDownload: @escaping () -> Void,
        onLike: @escaping () -> Void,
        galleryManager: GalleryManager = .shared,
        isPreview: Bool = false,
        isAdmin: Bool = false
    ) {
        self.item = item
        self.onDownload = onDownload
        self.onLike = onLike
        self.galleryManager = galleryManager
        self.isPreview = isPreview
        self.isAdmin = isAdmin
    }

    @State private var isHovering = false
    @State private var thumbnailImage: NSImage?
    @State private var isLoadingThumbnail = false
    /// ホバー時の光アニメーション用角度
    @State private var glowAngle: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                // サムネイル画像（非同期読み込み）
                if let image = thumbnailImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(16/10, contentMode: .fill)
                        .clipped()
                } else {
                    // 読み込み中のプレースホルダー
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.blue.opacity(0.3), .purple.opacity(0.3)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .aspectRatio(16/10, contentMode: .fill)
                        .overlay(
                            Group {
                                if isLoadingThumbnail {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "photo")
                                        .font(.system(size: 30))
                                        .foregroundColor(.white.opacity(0.5))
                                }
                            }
                        )
                }

                // ホバー時：ダウンロード進捗表示（進捗中のみ）
                if isHovering {
                    if item.isDownloaded {
                        // ダウンロード済みマーク（右上に小さく）
                    } else if let progress = galleryManager.downloadProgress[item.id] {
                        Color.black.opacity(0.4)
                            .overlay(
                                VStack(spacing: 4) {
                                    ProgressView(value: progress)
                                        .frame(width: 100)
                                    Text("\(Int(progress * 100))%")
                                        .font(.system(size: 11))
                                        .foregroundColor(.white)
                                }
                            )
                    }
                }

                // いいね・ダウンロード数バッジ
                VStack {
                    // ダウンロード済みバッジ（右上）
                    HStack {
                        Spacer()
                        if item.isDownloaded {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.green)
                                .padding(5)
                                .background(Color.black.opacity(0.5))
                                .cornerRadius(4)
                                .padding(4)
                        }
                    }
                    Spacer()
                    HStack {
                        HStack(spacing: 3) {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 9))
                            Text("\(item.likeCount)")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(4)

                        HStack(spacing: 3) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 9))
                            Text("\(item.downloadCount)")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(4)

                        Spacer()
                    }
                    .padding(6)
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
            .shadow(
                color: isHovering ? Color.accentColor.opacity(0.5) : Color.clear,
                radius: isHovering ? 10 : 0,
                x: 0,
                y: 0
            )
            .brightness(isHovering ? 0.05 : 0)
            .animation(.easeInOut(duration: 0.15), value: isHovering)
            .allowsHitTesting(false)
            .task {
                guard !isPreview else { return }
                // キャッシュから取得を試みる
                if let cached = galleryManager.getCachedThumbnail(for: item.id) {
                    thumbnailImage = cached
                    return
                }
                // 非同期で読み込み
                isLoadingThumbnail = true
                thumbnailImage = await galleryManager.loadThumbnail(for: item)
                isLoadingThumbnail = false
            }

            // 名前
            Text(item.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

            // 作者 + カテゴリ
            HStack(spacing: 6) {
                Text(item.authorName)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(item.category)
                    .font(.system(size: 10))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.1))
                    .foregroundColor(.accentColor)
                    .cornerRadius(4)
            }
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
        .contextMenu {
            Button(action: onDownload) {
                Label("ダウンロード", systemImage: "arrow.down.circle")
            }
            .disabled(item.isDownloaded)

            Button(action: onLike) {
                Label("いいね", systemImage: "heart")
            }

            Divider()

            Button(action: {
                Task {
                    do {
                        try await galleryManager.reportWallpaper(id: item.id, reason: "不適切なコンテンツ")
                    } catch {
                        await MainActor.run {
                            galleryManager.errorMessage = "報告に失敗しました: \(error.localizedDescription)"
                        }
                    }
                }
            }) {
                Label("報告する", systemImage: "exclamationmark.triangle")
            }

            // 管理者用メニュー
            if isAdmin {
                Divider()

                Button(action: {
                    Task {
                        do {
                            try await galleryManager.approveWallpaper(id: item.id)
                        } catch {
                            await MainActor.run {
                                galleryManager.errorMessage = "承認に失敗: \(error.localizedDescription)"
                            }
                        }
                    }
                }) {
                    Label("承認する", systemImage: "checkmark.circle")
                }

                Button(action: {
                    Task {
                        do {
                            try await galleryManager.promoteToFeatured(id: item.id)
                        } catch {
                            await MainActor.run {
                                galleryManager.errorMessage = "注目設定に失敗: \(error.localizedDescription)"
                            }
                        }
                    }
                }) {
                    Label("注目に昇格", systemImage: "star.fill")
                }

                Button(action: {
                    Task {
                        do {
                            try await galleryManager.deleteWallpaper(id: item.id)
                        } catch {
                            await MainActor.run {
                                galleryManager.errorMessage = "削除に失敗: \(error.localizedDescription)"
                            }
                        }
                    }
                }) {
                    Label("削除する（管理者）", systemImage: "trash.fill")
                }
            }
        }
    }
}

/// コミュニティ投稿ビュー
struct CommunitySubmitView: View {
    @ObservedObject var library = WallpaperLibrary.shared
    @ObservedObject var galleryManager = GalleryManager.shared
    @Binding var isPresented: Bool

    @State private var selectedWallpaper: WallpaperItem?
    @State private var submitName = ""
    @State private var submitCategory = "General"
    @State private var submitTags = ""
    @State private var isSubmitting = false
    @State private var submitError: String?

    /// 自作タグが付いた壁紙のみをフィルタリング（画像・動画・GIF対応）
    private var uploadableWallpapers: [WallpaperItem] {
        let uploadableTypes: Set<WallpaperType> = [.image, .video, .gif]
        return library.wallpapers.filter { uploadableTypes.contains($0.type) && $0.isDownloaded && $0.tags.contains("自作") }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("壁紙を投稿")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("閉じる") { isPresented = false }
                    .buttonStyle(.bordered)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 壁紙選択（自作タグ付きのみ）
                    HStack(spacing: 6) {
                        Text("投稿する壁紙を選択")
                            .font(.system(size: 13, weight: .medium))
                        Text("（自作壁紙のみ）")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    if uploadableWallpapers.isEmpty {
                        // 自作壁紙がない場合のメッセージ
                        VStack(spacing: 12) {
                            Image(systemName: "paintbrush.pointed")
                                .font(.system(size: 32))
                                .foregroundColor(.secondary.opacity(0.4))
                            Text("投稿できる壁紙がありません")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                            Text("「壁紙を作成」から壁紙を作成すると、\n自動的に「自作」タグが付与され投稿可能になります")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary.opacity(0.7))
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(uploadableWallpapers) { item in
                                    VStack {
                                        if let thumb = library.getThumbnailImage(for: item) {
                                            Image(nsImage: thumb)
                                                .resizable()
                                                .aspectRatio(16/10, contentMode: .fill)
                                                .frame(width: 120, height: 75)
                                                .clipped()
                                                .cornerRadius(6)
                                        }
                                        Text(item.name)
                                            .font(.system(size: 10))
                                            .lineLimit(1)
                                    }
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(selectedWallpaper?.id == item.id ? Color.accentColor : Color.clear, lineWidth: 2)
                                    )
                                    .onTapGesture {
                                        selectedWallpaper = item
                                        submitName = item.name
                                        // 壁紙に既存のタグがあれば自動入力（「自作」タグは除外）
                                        let existingTags = item.tags.filter { $0 != "自作" }
                                        if !existingTags.isEmpty {
                                            submitTags = existingTags.joined(separator: ", ")
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if selectedWallpaper != nil {
                        // メタデータ入力
                        VStack(alignment: .leading, spacing: 8) {
                            Text("名前")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            TextField("壁紙の名前", text: $submitName)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("カテゴリ")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            TextField("カテゴリ", text: $submitCategory)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("タグ（カンマ区切り）")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            TextField("風景, 自然, 山", text: $submitTags)
                                .textFieldStyle(.roundedBorder)
                        }

                        // エラー表示
                        if let error = submitError {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text(error)
                                    .font(.system(size: 12))
                                    .foregroundColor(.red)
                                Spacer()
                                Button(action: { submitError = nil }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(10)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(8)
                        }

                        // 投稿ボタン
                        HStack {
                            Spacer()
                            if isSubmitting {
                                ProgressView()
                                    .controlSize(.small)
                                Text("アップロード中...")
                                    .font(.system(size: 13))
                            } else {
                                Button(action: submitWallpaper) {
                                    Label("投稿する", systemImage: "paperplane.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(submitName.isEmpty || selectedWallpaper == nil || submitCategory.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 500, height: 500)
    }

    private func submitWallpaper() {
        guard let wallpaper = selectedWallpaper,
              let url = library.getWallpaperURL(for: wallpaper) else {
            submitError = "壁紙ファイルが見つかりません。選択し直してください。"
            return
        }

        isSubmitting = true
        submitError = nil
        let tags = submitTags.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        Task {
            do {
                try await galleryManager.submitWallpaper(
                    name: submitName,
                    category: submitCategory,
                    tags: tags,
                    fileURL: url
                )
                await MainActor.run {
                    isSubmitting = false
                    isPresented = false
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    submitError = error.localizedDescription
                }
            }
        }
    }
}
