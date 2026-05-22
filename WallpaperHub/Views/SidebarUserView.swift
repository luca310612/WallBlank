import SwiftUI

/// サイドバー下部のユーザー表示
struct SidebarUserView: View {
    @ObservedObject var authManager = AuthManager.shared
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

    // MARK: - サインイン済み

    private func signedInView(profile: UserProfile) -> some View {
        Button(action: { selectedTab = .profile }) {
            HStack(spacing: 8) {
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
                .frame(width: 28, height: 28)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selectedTab == .profile ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.001))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 未サインイン

    private var signedOutView: some View {
        Button(action: { showingAuthView = true }) {
            HStack(spacing: 6) {
                Image(systemName: "person.circle")
                    .font(.system(size: 14))
                Text("ログイン")
                    .font(.system(size: 12))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
    }
}
