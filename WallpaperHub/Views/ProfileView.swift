import SwiftUI

/// ユーザープロフィール表示ビュー
struct ProfileView: View {
    @ObservedObject var authManager = AuthManager.shared
    @State private var isEditingName = false
    @State private var editedName = ""

    var body: some View {
        if let profile = authManager.currentProfile {
            HStack(spacing: 16) {
                // アバター（カスタム画像対応）
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
                .frame(width: 48, height: 48)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 4) {
                    // 表示名
                    if isEditingName {
                        HStack(spacing: 6) {
                            TextField("表示名", text: $editedName)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 180)
                                .onSubmit { saveName() }
                            Button(action: saveName) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            }
                            .buttonStyle(.plain)
                            Button(action: { isEditingName = false }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        HStack(spacing: 6) {
                            Text(profile.displayName)
                                .font(.system(size: 14, weight: .semibold))
                            Button(action: {
                                editedName = profile.displayName
                                isEditingName = true
                            }) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // メール
                    if let email = profile.email, !email.isEmpty {
                        Text(email)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }

                    // 認証プロバイダバッジ
                    HStack(spacing: 4) {
                        Image(systemName: providerIcon(profile.authProvider))
                            .font(.system(size: 10))
                        Text(providerName(profile.authProvider))
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(4)
                }

                Spacer()
            }
        }
    }

    private func providerIcon(_ provider: UserProfile.AuthProvider) -> String {
        switch provider {
        case .google: return "globe"
        case .email: return "envelope.fill"
        case .anonymous: return "person.fill.questionmark"
        }
    }

    private func providerName(_ provider: UserProfile.AuthProvider) -> String {
        switch provider {
        case .google: return "Google"
        case .email: return "メール"
        case .anonymous: return "匿名"
        }
    }

    private func saveName() {
        guard !editedName.isEmpty else { return }
        isEditingName = false
        Task {
            try? await authManager.updateDisplayName(editedName)
        }
    }
}
