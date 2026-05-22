import SwiftUI

/// 管理者ダッシュボード（管理者モード時のみ表示）
struct AdminDashboardView: View {
    @ObservedObject var galleryManager = GalleryManager.shared
    @ObservedObject var authManager = AuthManager.shared

    @State private var selectedSection: AdminSection = .pending
    @State private var pendingWallpapers: [GalleryItem] = []
    @State private var allCommunityWallpapers: [GalleryItem] = []
    @State private var reports: [(id: String, wallpaperID: String, reason: String, reporterID: String, reportedAt: Date)] = []
    @State private var users: [UserProfile] = []
    @State private var isLoading = false
    @State private var actionMessage: String?

    enum AdminSection: String, CaseIterable {
        case pending = "未承認"
        case community = "コミュニティ"
        case featured = "注目"
        case reports = "報告"
        case users = "ユーザー"

        var icon: String {
            switch self {
            case .pending: return "clock.badge.questionmark"
            case .community: return "person.2"
            case .featured: return "star.fill"
            case .reports: return "exclamationmark.triangle"
            case .users: return "person.3"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー
            HStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 18))
                    .foregroundColor(.orange)
                Text("管理者ダッシュボード")
                    .font(.system(size: 16, weight: .bold))

                Spacer()

                // アクションメッセージ
                if let message = actionMessage {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundColor(.green)
                        .transition(.opacity)
                }

                Button(action: { refreshData() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            // セクションタブ
            HStack(spacing: 4) {
                ForEach(AdminSection.allCases, id: \.self) { section in
                    Button(action: {
                        selectedSection = section
                        refreshData()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: section.icon)
                                .font(.system(size: 11))
                            Text(section.rawValue)
                                .font(.system(size: 12, weight: .medium))
                            if section == .pending && !pendingWallpapers.isEmpty {
                                Text("\(pendingWallpapers.count)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.red)
                                    .cornerRadius(8)
                            }
                            if section == .reports && !reports.isEmpty {
                                Text("\(reports.count)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.orange)
                                    .cornerRadius(8)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(selectedSection == section ? Color.accentColor.opacity(0.15) : Color.clear)
                        .foregroundColor(selectedSection == section ? .accentColor : .secondary)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // コンテンツ
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("読み込み中...")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch selectedSection {
                case .pending:
                    pendingSection
                case .community:
                    communitySection
                case .featured:
                    featuredSection
                case .reports:
                    reportsSection
                case .users:
                    usersSection
                }
            }
        }
        .task {
            refreshData()
        }
    }

    // MARK: - 未承認セクション

    private var pendingSection: some View {
        Group {
            if pendingWallpapers.isEmpty {
                emptyState(icon: "checkmark.circle", message: "未承認の壁紙はありません")
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(pendingWallpapers) { item in
                            AdminWallpaperRow(
                                item: item,
                                onApprove: { approveItem(item) },
                                onPromote: { promoteItem(item) },
                                onDelete: { deleteItem(item) }
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    // MARK: - コミュニティセクション

    private var communitySection: some View {
        Group {
            if allCommunityWallpapers.isEmpty {
                emptyState(icon: "photo.stack", message: "コミュニティ壁紙はありません")
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(allCommunityWallpapers) { item in
                            AdminWallpaperRow(
                                item: item,
                                showApprovalStatus: true,
                                onApprove: { approveItem(item) },
                                onPromote: { promoteItem(item) },
                                onDelete: { deleteItem(item) }
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    // MARK: - 注目セクション

    private var featuredSection: some View {
        Group {
            if galleryManager.featuredWallpapers.isEmpty {
                emptyState(icon: "star", message: "注目の壁紙はありません")
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(galleryManager.featuredWallpapers) { item in
                            HStack(spacing: 12) {
                                // サムネイル
                                thumbnailView(for: item)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name)
                                        .font(.system(size: 13, weight: .medium))
                                    HStack(spacing: 8) {
                                        Label("\(item.downloadCount)", systemImage: "arrow.down")
                                        Label("\(item.likeCount)", systemImage: "heart")
                                    }
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                }

                                Spacer()

                                Button("注目解除") {
                                    demoteItem(item)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .foregroundColor(.orange)
                            }
                            .padding(12)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(8)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    // MARK: - 報告セクション

    private var reportsSection: some View {
        Group {
            if reports.isEmpty {
                emptyState(icon: "checkmark.shield", message: "報告はありません")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(reports, id: \.id) { report in
                            HStack(spacing: 12) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .font(.system(size: 16))

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("壁紙ID: \(report.wallpaperID)")
                                        .font(.system(size: 12, weight: .medium))
                                    Text("理由: \(report.reason)")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                    Text("報告日時: \(report.reportedAt, formatter: dateFormatter)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary.opacity(0.7))
                                }

                                Spacer()

                                HStack(spacing: 6) {
                                    Button("壁紙を削除") {
                                        Task {
                                            do {
                                                try await galleryManager.deleteWallpaper(id: report.wallpaperID)
                                                try await galleryManager.dismissReport(id: report.id)
                                                showAction("壁紙を削除し、報告を処理しました")
                                                refreshData()
                                            } catch {
                                                showAction("エラー: \(error.localizedDescription)")
                                            }
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .foregroundColor(.red)

                                    Button("却下") {
                                        Task {
                                            do {
                                                try await galleryManager.dismissReport(id: report.id)
                                                showAction("報告を却下しました")
                                                refreshData()
                                            } catch {
                                                showAction("エラー: \(error.localizedDescription)")
                                            }
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                            .padding(12)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(8)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    // MARK: - ユーザーセクション

    private var usersSection: some View {
        Group {
            if users.isEmpty {
                emptyState(icon: "person.2", message: "ユーザーデータがありません")
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        // ヘッダー
                        HStack(spacing: 0) {
                            Text("ユーザー名")
                                .frame(width: 150, alignment: .leading)
                            Text("メール")
                                .frame(width: 200, alignment: .leading)
                            Text("認証方法")
                                .frame(width: 80, alignment: .leading)
                            Text("ロール")
                                .frame(width: 60, alignment: .leading)
                            Text("登録日")
                                .frame(width: 100, alignment: .leading)
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

                        ForEach(users, id: \.uid) { user in
                            HStack(spacing: 0) {
                                HStack(spacing: 6) {
                                    Image(systemName: user.isAdmin ? "shield.fill" : "person.circle")
                                        .font(.system(size: 12))
                                        .foregroundColor(user.isAdmin ? .orange : .secondary)
                                    Text(user.displayName)
                                        .lineLimit(1)
                                }
                                .frame(width: 150, alignment: .leading)

                                Text(user.email ?? "なし")
                                    .lineLimit(1)
                                    .frame(width: 200, alignment: .leading)

                                Text(authProviderLabel(user.authProvider))
                                    .frame(width: 80, alignment: .leading)

                                Text(user.isAdmin ? "管理者" : "一般")
                                    .foregroundColor(user.isAdmin ? .orange : .primary)
                                    .frame(width: 60, alignment: .leading)

                                Text(user.createdAt, formatter: shortDateFormatter)
                                    .frame(width: 100, alignment: .leading)
                            }
                            .font(.system(size: 12))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(4)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    // MARK: - ヘルパー

    private func emptyState(icon: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.3))
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func thumbnailView(for item: GalleryItem) -> some View {
        if let cached = galleryManager.getCachedThumbnail(for: item.id) {
            Image(nsImage: cached)
                .resizable()
                .aspectRatio(16/10, contentMode: .fill)
                .frame(width: 80, height: 50)
                .clipped()
                .cornerRadius(4)
        } else {
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 80, height: 50)
                .cornerRadius(4)
                .overlay(
                    Image(systemName: "photo")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary.opacity(0.5))
                )
        }
    }

    private func refreshData() {
        isLoading = true
        Task {
            async let pending = galleryManager.fetchPendingWallpapers()
            async let fetchedReports = galleryManager.fetchReports()
            async let fetchedUsers = galleryManager.fetchAllUsers()
            await galleryManager.fetchFeatured()
            await galleryManager.fetchCommunity()

            let p = await pending
            let r = await fetchedReports
            let u = await fetchedUsers

            await MainActor.run {
                pendingWallpapers = p
                reports = r
                users = u
                allCommunityWallpapers = galleryManager.communityWallpapers
                isLoading = false
            }
        }
    }

    private func approveItem(_ item: GalleryItem) {
        Task {
            do {
                try await galleryManager.approveWallpaper(id: item.id)
                showAction("「\(item.name)」を承認しました")
                refreshData()
            } catch {
                showAction("エラー: \(error.localizedDescription)")
            }
        }
    }

    private func promoteItem(_ item: GalleryItem) {
        Task {
            do {
                try await galleryManager.promoteToFeatured(id: item.id)
                showAction("「\(item.name)」を注目に昇格しました")
                refreshData()
            } catch {
                showAction("エラー: \(error.localizedDescription)")
            }
        }
    }

    private func demoteItem(_ item: GalleryItem) {
        Task {
            do {
                try await galleryManager.demoteFromFeatured(id: item.id)
                showAction("「\(item.name)」を注目から解除しました")
                refreshData()
            } catch {
                showAction("エラー: \(error.localizedDescription)")
            }
        }
    }

    private func deleteItem(_ item: GalleryItem) {
        Task {
            do {
                try await galleryManager.deleteWallpaper(id: item.id)
                showAction("「\(item.name)」を削除しました")
                refreshData()
            } catch {
                showAction("エラー: \(error.localizedDescription)")
            }
        }
    }

    private func showAction(_ message: String) {
        Task { @MainActor in
            withAnimation { actionMessage = message }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation { actionMessage = nil }
        }
    }

    private func authProviderLabel(_ provider: UserProfile.AuthProvider) -> String {
        switch provider {
        case .email: return "メール"
        case .google: return "Google"
        case .anonymous: return "匿名"
        }
    }

    private var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }

    private var shortDateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }
}

// MARK: - 管理者用壁紙行

struct AdminWallpaperRow: View {
    let item: GalleryItem
    var showApprovalStatus: Bool = false
    let onApprove: () -> Void
    let onPromote: () -> Void
    let onDelete: () -> Void

    @ObservedObject private var galleryManager = GalleryManager.shared
    @State private var showDeleteConfirm = false

    var body: some View {
        HStack(spacing: 12) {
            // サムネイル
            if let cached = galleryManager.getCachedThumbnail(for: item.id) {
                Image(nsImage: cached)
                    .resizable()
                    .aspectRatio(16/10, contentMode: .fill)
                    .frame(width: 100, height: 62)
                    .clipped()
                    .cornerRadius(6)
            } else {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.blue.opacity(0.2), .purple.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 62)
                    .cornerRadius(6)
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary.opacity(0.5))
                    )
            }

            // 情報
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    if showApprovalStatus {
                        Text(item.isApproved ? "承認済み" : "未承認")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(item.isApproved ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                            .foregroundColor(item.isApproved ? .green : .orange)
                            .cornerRadius(4)
                    }
                }

                HStack(spacing: 8) {
                    Text("投稿者: \(item.authorName)")
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

                HStack(spacing: 12) {
                    Label("\(item.downloadCount)", systemImage: "arrow.down")
                    Label("\(item.likeCount)", systemImage: "heart")
                    Text(item.createdAt, formatter: dateFormatter)
                }
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.7))
            }

            Spacer()

            // アクションボタン
            HStack(spacing: 6) {
                if !item.isApproved {
                    Button(action: onApprove) {
                        Label("承認", systemImage: "checkmark")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                Button(action: onPromote) {
                    Label("注目", systemImage: "star")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: { showDeleteConfirm = true }) {
                    Label("削除", systemImage: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundColor(.red)
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .alert("壁紙を削除", isPresented: $showDeleteConfirm) {
            Button("キャンセル", role: .cancel) {}
            Button("削除する", role: .destructive) { onDelete() }
        } message: {
            Text("「\(item.name)」を完全に削除します。この操作は取り消せません。")
        }
    }

    private var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }
}
