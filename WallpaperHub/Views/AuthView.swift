import SwiftUI
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

/// ログイン / 新規登録画面
struct AuthView: View {
    @ObservedObject var authManager = AuthManager.shared
    @Binding var isPresented: Bool

    @State private var isLoginMode = true
    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var confirmPassword = ""
    @State private var showPasswordReset = false
    @State private var resetEmail = ""
    @State private var resetSent = false
    @State private var localError: String?

    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー
            HStack {
                Text(isLoginMode ? "ログイン" : "新規登録")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    // Google Sign-In ボタン
                    Button(action: signInWithGoogle) {
                        HStack(spacing: 10) {
                            Image(systemName: "globe")
                                .font(.system(size: 16))
                            Text("Googleでサインイン")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)

                    // 区切り
                    HStack {
                        Rectangle()
                            .fill(Color(NSColor.separatorColor))
                            .frame(height: 1)
                        Text("または")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Rectangle()
                            .fill(Color(NSColor.separatorColor))
                            .frame(height: 1)
                    }

                    // メール/パスワードフォーム
                    VStack(alignment: .leading, spacing: 12) {
                        if !isLoginMode {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("表示名")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.secondary)
                                TextField("名前を入力", text: $displayName)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: displayName) { _, newValue in
                                        if newValue.count > 50 {
                                            displayName = String(newValue.prefix(50))
                                        }
                                    }
                                Text("\(displayName.count)/50")
                                    .font(.system(size: 10))
                                    .foregroundColor(displayName.count > 45 ? .orange : .secondary)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("メールアドレス")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            TextField("example@mail.com", text: $email)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("パスワード")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            SecureField("8文字以上", text: $password)
                                .textFieldStyle(.roundedBorder)
                        }

                        if !isLoginMode {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("パスワード確認")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.secondary)
                                SecureField("もう一度入力", text: $confirmPassword)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }

                    // アクションボタン
                    Button(action: isLoginMode ? signInWithEmail : signUpWithEmail) {
                        HStack {
                            if authManager.isProcessing {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(isLoginMode ? "ログイン" : "アカウント作成")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isFormValid || authManager.isProcessing)

                    // エラーメッセージ
                    if let error = localError ?? authManager.errorMessage {
                        InlineErrorLabel(message: error)
                    }

                    Divider()

                    // モード切替
                    HStack(spacing: 4) {
                        Text(isLoginMode ? "アカウントをお持ちでない方" : "既にアカウントをお持ちの方")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Button(isLoginMode ? "新規登録" : "ログイン") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isLoginMode.toggle()
                                localError = nil
                                authManager.errorMessage = nil
                            }
                        }
                        .font(.system(size: 12, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                    }

                    // パスワードリセット
                    if isLoginMode {
                        Button("パスワードを忘れた方") {
                            showPasswordReset = true
                        }
                        .font(.system(size: 12))
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 400, height: isLoginMode ? 480 : 560)
        .sheet(isPresented: $showPasswordReset) {
            passwordResetSheet
        }
    }

    // MARK: - パスワードリセットシート

    private var passwordResetSheet: some View {
        VStack(spacing: 16) {
            Text("パスワードリセット")
                .font(.system(size: 16, weight: .semibold))

            if resetSent {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.green)
                    Text("リセットメールを送信しました")
                        .font(.system(size: 13))
                    Text("メールに記載のリンクからパスワードをリセットしてください")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else {
                Text("登録メールアドレスにパスワードリセットリンクを送信します")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                TextField("メールアドレス", text: $resetEmail)
                    .textFieldStyle(.roundedBorder)

                Button("送信") {
                    Task {
                        do {
                            try await authManager.sendPasswordReset(email: resetEmail)
                            resetSent = true
                        } catch {
                            localError = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(resetEmail.isEmpty)
            }

            Button("閉じる") {
                showPasswordReset = false
                resetSent = false
                resetEmail = ""
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(width: 340, height: 260)
    }

    // MARK: - バリデーション

    private var isFormValid: Bool {
        if isLoginMode {
            return !email.isEmpty && !password.isEmpty && isValidEmail(email)
        } else {
            return !email.isEmpty && !password.isEmpty &&
                   !displayName.isEmpty && displayName.count <= 50 &&
                   password == confirmPassword &&
                   password.count >= 8 && isValidEmail(email)
        }
    }

    /// メールアドレスの基本的なフォーマット検証
    private func isValidEmail(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("@") && trimmed.contains(".") && trimmed.count >= 5
    }

    // MARK: - アクション

    private func signInWithGoogle() {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else {
            localError = "ウィンドウが見つかりません"
            return
        }

        localError = nil
        Task {
            do {
                try await authManager.signInWithGoogle(presenting: window)
                await MainActor.run { isPresented = false }
            } catch {
                await MainActor.run { localError = error.localizedDescription }
            }
        }
    }

    private func signInWithEmail() {
        localError = nil
        Task {
            do {
                try await authManager.signInWithEmail(email: email, password: password)
                await MainActor.run { isPresented = false }
            } catch {
                await MainActor.run { localError = error.localizedDescription }
            }
        }
    }

    private func signUpWithEmail() {
        guard password == confirmPassword else {
            localError = "パスワードが一致しません"
            return
        }
        guard password.count >= 8 else {
            localError = "パスワードは8文字以上で入力してください"
            return
        }

        localError = nil
        Task {
            do {
                try await authManager.signUpWithEmail(
                    email: email,
                    password: password,
                    displayName: displayName
                )
                await MainActor.run { isPresented = false }
            } catch {
                await MainActor.run { localError = error.localizedDescription }
            }
        }
    }
}
