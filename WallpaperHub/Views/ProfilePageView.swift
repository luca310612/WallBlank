import SwiftUI
import AppKit

/// プロフィール専用ページ
struct ProfilePageView: View {
    @ObservedObject private var authManager = AuthManager.shared
    @State private var showingAuthView = false
    @State private var showingDeleteConfirmation = false
    @State private var isEditingName = false
    @State private var editedName = ""
    @State private var errorMessage: String?

    // SNSリンク編集用
    @State private var isEditingSocialLinks = false
    @State private var editTwitter = ""
    @State private var editInstagram = ""
    @State private var editPixiv = ""
    @State private var editSkeb = ""
    @State private var editYouTube = ""

    // 自己紹介編集用
    @State private var isEditingBio = false
    @State private var editedBio = ""

    var body: some View {
        if authManager.isAuthenticated, let profile = authManager.currentProfile {
            authenticatedView(profile: profile)
        } else {
            unauthenticatedView
        }
    }

    // MARK: - 認証済みビュー

    private func authenticatedView(profile: UserProfile) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                // ヘッダー: アバター＆基本情報
                profileHeader(profile: profile)

                // セクション群
                VStack(spacing: 20) {
                    // 自己紹介セクション
                    bioSection(profile: profile)

                    // SNSリンクセクション
                    socialLinksSection(profile: profile)

                    // アカウント情報セクション
                    accountInfoSection(profile: profile)

                    // アカウント操作セクション
                    accountActionsSection
                }
                .padding(24)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .alert("アカウント削除", isPresented: $showingDeleteConfirmation) {
            Button("キャンセル", role: .cancel) {}
            Button("削除する", role: .destructive) {
                Task {
                    do {
                        try await authManager.deleteAccount()
                    } catch {
                        await MainActor.run { errorMessage = error.localizedDescription }
                    }
                }
            }
        } message: {
            Text("アカウントとクラウドデータがすべて削除されます。この操作は取り消せません。")
        }
    }

    // MARK: - ヘッダー

    private func profileHeader(profile: UserProfile) -> some View {
        VStack(spacing: 16) {
            // アバター（カスタム画像対応）
            ZStack(alignment: .bottomTrailing) {
                avatarImage(profile: profile)
                    .frame(width: 80, height: 80)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.accentColor.opacity(0.3), lineWidth: 2)
                    )

                // 画像変更ボタン
                Menu {
                    Button(action: selectAvatarImage) {
                        Label("画像を選択...", systemImage: "photo")
                    }
                    if profile.customAvatarPath != nil {
                        Button(role: .destructive, action: removeAvatar) {
                            Label("デフォルトに戻す", systemImage: "arrow.uturn.backward")
                        }
                    }
                } label: {
                    Image(systemName: "camera.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.accentColor)
                        .background(
                            Circle()
                                .fill(Color(NSColor.windowBackgroundColor))
                                .frame(width: 20, height: 20)
                        )
                }
                .buttonStyle(.plain)
                .offset(x: 2, y: 2)
            }

            // 表示名（編集可能）
            if isEditingName {
                HStack(spacing: 8) {
                    TextField("表示名", text: $editedName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 16))
                        .frame(maxWidth: 200)
                        .onSubmit { saveName() }
                    Button(action: saveName) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.green)
                    }
                    .buttonStyle(.plain)
                    Button(action: { isEditingName = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: 6) {
                    Text(profile.displayName)
                        .font(.system(size: 20, weight: .bold))
                    Button(action: {
                        editedName = profile.displayName
                        isEditingName = true
                    }) {
                        Image(systemName: "pencil.circle")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // メールアドレス
            if let email = profile.email, !email.isEmpty {
                Text(email)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

            // 認証プロバイダバッジ
            HStack(spacing: 6) {
                Image(systemName: providerIcon(profile.authProvider))
                    .font(.system(size: 11))
                Text(providerLabel(profile.authProvider))
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)

            // SNSリンクアイコン（設定済みの場合表示）
            if profile.socialLinks.hasAnyLink {
                socialLinksIconBar(links: profile.socialLinks)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.06), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - アバター画像

    @ViewBuilder
    private func avatarImage(profile: UserProfile) -> some View {
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
                        .foregroundColor(.secondary.opacity(0.4))
                }
            }
        }
    }

    private func selectAvatarImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "プロフィール画像を選択してください"

        if panel.runModal() == .OK, let url = panel.url {
            guard let image = NSImage(contentsOf: url) else { return }
            Task {
                do {
                    try await authManager.updateCustomAvatar(image)
                } catch {
                    await MainActor.run { errorMessage = "画像の保存に失敗しました" }
                }
            }
        }
    }

    private func removeAvatar() {
        Task {
            try? await authManager.removeCustomAvatar()
        }
    }

    // MARK: - SNSリンクアイコンバー（ヘッダー内）

    private func socialLinksIconBar(links: UserProfile.SocialLinks) -> some View {
        HStack(spacing: 12) {
            if let twitter = links.twitter, !twitter.isEmpty {
                socialLinkButton(icon: "bird", url: twitter, tooltip: "X (Twitter)")
            }
            if let instagram = links.instagram, !instagram.isEmpty {
                socialLinkButton(icon: "camera", url: instagram, tooltip: "Instagram")
            }
            if let pixiv = links.pixiv, !pixiv.isEmpty {
                socialLinkButton(icon: "paintbrush", url: pixiv, tooltip: "Pixiv")
            }
            if let skeb = links.skeb, !skeb.isEmpty {
                socialLinkButton(icon: "pencil.and.outline", url: skeb, tooltip: "Skeb")
            }
            if let youtube = links.youtube, !youtube.isEmpty {
                socialLinkButton(icon: "play.rectangle.fill", url: youtube, tooltip: "YouTube")
            }
        }
        .padding(.top, 4)
    }

    private func socialLinkButton(icon: String, url: String, tooltip: String) -> some View {
        Button(action: {
            if let linkURL = URL(string: url),
               let scheme = linkURL.scheme?.lowercased(),
               scheme == "https" || scheme == "http" {
                NSWorkspace.shared.open(linkURL)
            }
        }) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    // MARK: - 自己紹介セクション

    private func bioSection(profile: UserProfile) -> some View {
        SectionCard(icon: "text.quote", title: "自己紹介") {
            VStack(alignment: .leading, spacing: 10) {
                if isEditingBio {
                    TextEditor(text: $editedBio)
                        .font(.system(size: 13))
                        .frame(minHeight: 60, maxHeight: 120)
                        .padding(4)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )

                    HStack {
                        Text("\(editedBio.count)/200")
                            .font(.system(size: 10))
                            .foregroundColor(editedBio.count > 200 ? .red : .secondary)

                        Spacer()

                        Button("キャンセル") { isEditingBio = false }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                        Button("保存") {
                            saveBio()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(editedBio.count > 200)
                    }
                } else {
                    if let bio = profile.bio, !bio.isEmpty {
                        Text(bio)
                            .font(.system(size: 13))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("自己紹介を入力しましょう")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary.opacity(0.6))
                            .italic()
                    }

                    Button(action: {
                        editedBio = profile.bio ?? ""
                        isEditingBio = true
                    }) {
                        Label("編集", systemImage: "pencil")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private func saveBio() {
        let bio = editedBio.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditingBio = false
        Task {
            do {
                try await authManager.updateBio(bio)
            } catch {
                await MainActor.run { errorMessage = "自己紹介の更新に失敗しました" }
            }
        }
    }

    // MARK: - SNSリンク編集セクション

    private func socialLinksSection(profile: UserProfile) -> some View {
        SectionCard(icon: "link", title: "SNSリンク") {
            VStack(alignment: .leading, spacing: 10) {
                if isEditingSocialLinks {
                    socialLinkEditField(icon: "bird", label: "X (Twitter)", placeholder: "https://x.com/username", text: $editTwitter, requiredPrefix: "https://x.com/")
                    socialLinkEditField(icon: "camera", label: "Instagram", placeholder: "https://www.instagram.com/username", text: $editInstagram, requiredPrefix: "https://www.instagram.com/")
                    socialLinkEditField(icon: "paintbrush", label: "Pixiv", placeholder: "https://www.pixiv.net/users/12345", text: $editPixiv, requiredPrefix: "https://www.pixiv.net/users/")
                    socialLinkEditField(icon: "pencil.and.outline", label: "Skeb", placeholder: "https://skeb.jp/@username", text: $editSkeb, requiredPrefix: "https://skeb.jp/")
                    socialLinkEditField(icon: "play.rectangle", label: "YouTube", placeholder: "https://www.youtube.com/channel/...", text: $editYouTube, requiredPrefix: "https://www.youtube.com/")

                    HStack {
                        Spacer()
                        Button("キャンセル") { isEditingSocialLinks = false }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button("保存") {
                            saveSocialLinks()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!isSocialLinksValid)
                    }
                    .padding(.top, 4)
                } else {
                    if profile.socialLinks.hasAnyLink {
                        socialLinkDisplayRows(links: profile.socialLinks)
                    } else {
                        Text("SNSリンクを追加して、他のユーザーと繋がりましょう")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary.opacity(0.6))
                            .italic()
                    }

                    Button(action: {
                        editTwitter = profile.socialLinks.twitter ?? ""
                        editInstagram = profile.socialLinks.instagram ?? ""
                        editPixiv = profile.socialLinks.pixiv ?? ""
                        editSkeb = profile.socialLinks.skeb ?? ""
                        editYouTube = profile.socialLinks.youtube ?? ""
                        isEditingSocialLinks = true
                    }) {
                        Label("編集", systemImage: "pencil")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    /// SNSリンクのバリデーション結果
    private var isSocialLinksValid: Bool {
        let links = UserProfile.SocialLinks(
            twitter: editTwitter.isEmpty ? nil : editTwitter,
            instagram: editInstagram.isEmpty ? nil : editInstagram,
            pixiv: editPixiv.isEmpty ? nil : editPixiv,
            skeb: editSkeb.isEmpty ? nil : editSkeb,
            youtube: editYouTube.isEmpty ? nil : editYouTube
        )
        return links.isAllLinksValid
    }

    private func socialLinkEditField(icon: String, label: String, placeholder: String, text: Binding<String>, requiredPrefix: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 20)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .leading)
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
            if let error = UserProfile.SocialLinks.validationError(for: text.wrappedValue, prefix: requiredPrefix) {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .padding(.leading, 110)
            }
        }
    }

    private func socialLinkDisplayRows(links: UserProfile.SocialLinks) -> some View {
        VStack(spacing: 8) {
            if let twitter = links.twitter, !twitter.isEmpty {
                socialLinkDisplayRow(icon: "bird", label: "X (Twitter)", url: twitter)
            }
            if let instagram = links.instagram, !instagram.isEmpty {
                socialLinkDisplayRow(icon: "camera", label: "Instagram", url: instagram)
            }
            if let pixiv = links.pixiv, !pixiv.isEmpty {
                socialLinkDisplayRow(icon: "paintbrush", label: "Pixiv", url: pixiv)
            }
            if let skeb = links.skeb, !skeb.isEmpty {
                socialLinkDisplayRow(icon: "pencil.and.outline", label: "Skeb", url: skeb)
            }
            if let youtube = links.youtube, !youtube.isEmpty {
                socialLinkDisplayRow(icon: "play.rectangle", label: "YouTube", url: youtube)
            }
        }
    }

    private func socialLinkDisplayRow(icon: String, label: String, url: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.accentColor)
                .frame(width: 20)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            Button(action: {
                if let linkURL = URL(string: url),
                   let scheme = linkURL.scheme?.lowercased(),
                   scheme == "https" || scheme == "http" {
                    NSWorkspace.shared.open(linkURL)
                }
            }) {
                Text(url)
                    .font(.system(size: 12))
                    .foregroundColor(.accentColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    private func saveSocialLinks() {
        isEditingSocialLinks = false
        let links = UserProfile.SocialLinks(
            twitter: editTwitter.isEmpty ? nil : editTwitter,
            instagram: editInstagram.isEmpty ? nil : editInstagram,
            pixiv: editPixiv.isEmpty ? nil : editPixiv,
            skeb: editSkeb.isEmpty ? nil : editSkeb,
            youtube: editYouTube.isEmpty ? nil : editYouTube
        )
        Task {
            do {
                try await authManager.updateSocialLinks(links)
            } catch {
                await MainActor.run { errorMessage = "SNSリンクの更新に失敗しました" }
            }
        }
    }

    // MARK: - アカウント情報セクション

    private func accountInfoSection(profile: UserProfile) -> some View {
        SectionCard(icon: "person.text.rectangle", title: "アカウント情報") {
            VStack(spacing: 12) {
                InfoRow(label: "ユーザーID", value: String(profile.uid.prefix(12)) + "...")
                Divider()
                InfoRow(label: "認証方法", value: providerLabel(profile.authProvider))
                Divider()
                InfoRow(label: "作成日", value: dateString(profile.createdAt))
                if let lastSync = profile.lastSyncAt {
                    Divider()
                    InfoRow(label: "最終同期", value: dateString(lastSync))
                }
                if profile.isAdmin {
                    Divider()
                    HStack {
                        Text("権限")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "shield.lefthalf.filled")
                                .font(.system(size: 11))
                            Text("管理者")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.orange)
                    }
                }
            }
        }
    }

    // MARK: - アカウント操作セクション

    private var accountActionsSection: some View {
        SectionCard(icon: "ellipsis.circle", title: "アカウント操作") {
            VStack(spacing: 12) {
                // サインアウト
                Button(action: {
                    do {
                        try authManager.signOut()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }) {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 13))
                        Text("サインアウト")
                            .font(.system(size: 13))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .padding(10)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // アカウント削除
                Button(action: { showingDeleteConfirmation = true }) {
                    HStack {
                        Image(systemName: "trash")
                            .font(.system(size: 13))
                        Text("アカウントを削除")
                            .font(.system(size: 13))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .foregroundColor(.red.opacity(0.5))
                    }
                    .foregroundColor(.red)
                    .padding(10)
                    .background(Color.red.opacity(0.05))
                    .cornerRadius(8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let error = errorMessage {
                    InlineErrorLabel(message: error)
                }
            }
        }
    }

    // MARK: - 未認証ビュー

    private var unauthenticatedView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.circle")
                .font(.system(size: 64))
                .foregroundColor(.secondary.opacity(0.4))

            VStack(spacing: 8) {
                Text("サインインしてください")
                    .font(.system(size: 18, weight: .semibold))
                Text("ログインするとコミュニティ機能が利用できます")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(action: { showingAuthView = true }) {
                Label("ログイン / 新規登録", systemImage: "person.circle")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .sheet(isPresented: $showingAuthView) {
            AuthView(isPresented: $showingAuthView)
        }
    }

    // MARK: - ヘルパー

    private func providerIcon(_ provider: UserProfile.AuthProvider) -> String {
        switch provider {
        case .google: return "globe"
        case .email: return "envelope.fill"
        case .anonymous: return "person.fill.questionmark"
        }
    }

    private func providerLabel(_ provider: UserProfile.AuthProvider) -> String {
        switch provider {
        case .google: return "Googleアカウント"
        case .email: return "メール/パスワード"
        case .anonymous: return "匿名"
        }
    }

    private func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter.string(from: date)
    }

    private func saveName() {
        let name = editedName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isEditingName = false
        Task {
            do {
                try await authManager.updateDisplayName(name)
            } catch {
                await MainActor.run { errorMessage = "表示名の更新に失敗しました: \(error.localizedDescription)" }
            }
        }
    }

}

// MARK: - セクションカード

private struct SectionCard<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
    }
}

// MARK: - 情報行

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(.primary)
        }
    }
}

