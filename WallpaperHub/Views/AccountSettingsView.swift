import SwiftUI

/// アカウント管理ビュー（設定タブ内に表示）
struct AccountSettingsView: View {
    @ObservedObject var authManager = AuthManager.shared
    @State private var showingAuthView = false
    @State private var showingSignOutConfirmation = false
    @State private var showingDeleteConfirmation = false
    @State private var showingDeleteFinalConfirmation = false
    @State private var deleteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // セクションヘッダー
            HStack(spacing: 8) {
                Image(systemName: "person.circle")
                    .font(.system(size: 14))
                    .foregroundColor(.accentColor)
                Text("アカウント")
                    .font(.system(size: 14, weight: .semibold))
            }

            if authManager.isAuthenticated {
                authenticatedContent
            } else {
                unauthenticatedContent
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
        .sheet(isPresented: $showingAuthView) {
            AuthView(isPresented: $showingAuthView)
        }
    }

    // MARK: - 認証済みコンテンツ

    private var authenticatedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // プロフィール
            ProfileView()

            Divider()

            // アカウント操作
            HStack(spacing: 12) {
                Button(action: { showingSignOutConfirmation = true }) {
                    Label("サインアウト", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: { showingDeleteConfirmation = true }) {
                    Label("アカウント削除", systemImage: "trash")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundColor(.red)
            }

            if let error = deleteError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }
        }
        // サインアウト確認（1回）
        .alert("サインアウト", isPresented: $showingSignOutConfirmation) {
            Button("キャンセル", role: .cancel) {}
            Button("サインアウト", role: .destructive) {
                do {
                    try authManager.signOut()
                } catch {
                    authManager.errorMessage = error.localizedDescription
                }
            }
        } message: {
            Text("サインアウトしますか？ローカルデータはそのまま残ります。")
        }
        // アカウント削除確認（1回目）
        .alert("アカウント削除", isPresented: $showingDeleteConfirmation) {
            Button("キャンセル", role: .cancel) {}
            Button("続ける", role: .destructive) {
                showingDeleteFinalConfirmation = true
            }
        } message: {
            Text("アカウントとクラウドデータがすべて削除されます。この操作は取り消せません。")
        }
        // アカウント削除確認（2回目・最終確認）
        .alert("本当に削除しますか？", isPresented: $showingDeleteFinalConfirmation) {
            Button("キャンセル", role: .cancel) {}
            Button("完全に削除する", role: .destructive) {
                Task {
                    do {
                        try await authManager.deleteAccount()
                    } catch {
                        await MainActor.run { deleteError = error.localizedDescription }
                    }
                }
            }
        } message: {
            Text("この操作は元に戻せません。アカウントデータがすべて完全に削除されます。本当によろしいですか？")
        }
    }

    // MARK: - 未認証コンテンツ

    private var unauthenticatedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ログインしてコミュニティ機能を利用しましょう")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Button(action: { showingAuthView = true }) {
                Label("ログイン / 新規登録", systemImage: "person.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

}
