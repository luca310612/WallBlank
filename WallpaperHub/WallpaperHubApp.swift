import SwiftUI
import MetalKit
import LocalAuthentication
#if canImport(FirebaseCore)
import FirebaseCore
#endif
#if canImport(FirebaseAuth)
import FirebaseAuth
#endif
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

@MainActor
final class AppLockManager: ObservableObject {
    static let shared = AppLockManager()

    @Published private(set) var isLocked = false
    @Published private(set) var isAuthenticating = false
    @Published var lastErrorMessage: String?
    private weak var appDelegate: AppDelegate?

    private init() {}

    func connect(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    func lock(using appDelegate: AppDelegate? = nil) {
        if let appDelegate {
            connect(appDelegate: appDelegate)
        }

        guard !isAuthenticating else { return }
        lastErrorMessage = nil
        isLocked = true
        self.appDelegate?.showLockScreenWindow()
    }

    func unlock(using appDelegate: AppDelegate? = nil) {
        if let appDelegate {
            connect(appDelegate: appDelegate)
        }

        guard isLocked, !isAuthenticating else { return }

        isAuthenticating = true
        lastErrorMessage = nil

        Task { [weak self] in
            guard let self else { return }
            let result = await self.requestAuthentication(reason: "WallBlankを開くには認証してください。")

            await MainActor.run {
                self.isAuthenticating = false

                switch result {
                case .success:
                    self.isLocked = false
                    self.lastErrorMessage = nil
                    self.appDelegate?.closeLockScreenWindow()
                case .failure(let error):
                    self.lastErrorMessage = self.errorMessage(for: error)
                }
            }
        }
    }

    private func requestAuthentication(reason: String) async -> Result<Void, Error> {
        let context = LAContext()
        context.localizedCancelTitle = "キャンセル"
        context.localizedFallbackTitle = "パスワードを使用"

        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            return .failure(authError ?? NSError(domain: "AppLockManager", code: -1))
        }

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if success {
                    continuation.resume(returning: .success(()))
                } else {
                    continuation.resume(returning: .failure(error ?? NSError(domain: "AppLockManager", code: -2)))
                }
            }
        }
    }

    private func errorMessage(for error: Error) -> String {
        guard let laError = error as? LAError else {
            return error.localizedDescription
        }

        switch laError.code {
        case .authenticationFailed:
            return "認証に失敗しました。"
        case .userCancel, .appCancel, .systemCancel:
            return "認証がキャンセルされました。"
        case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
            return "このMacではアプリロックを利用できません。"
        default:
            return laError.localizedDescription
        }
    }
}

private enum LockScreenFormatters {
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return formatter
    }()

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("HHmm")
        return formatter
    }()
}

struct LockScreenWindowContent: View {
    @ObservedObject var appLockManager: AppLockManager
    let previewRenderer: Renderer
    let device: MTLDevice

    @State private var now = Date()

    private var appIcon: NSImage? {
        NSApp.applicationIconImage
    }

    private var formattedDate: String {
        LockScreenFormatters.dateFormatter.string(from: now)
    }

    private var formattedTime: String {
        LockScreenFormatters.timeFormatter.string(from: now)
    }

    var body: some View {
        ZStack {
            MetalPreviewView(renderer: previewRenderer, device: device, cornerRadius: 0)
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    Color.black.opacity(0.12),
                    Color.black.opacity(0.30)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    Text(formattedDate)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.96))

                    Text(formattedTime)
                        .font(.system(size: 148, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 10)
                .padding(.top, 74)

                Spacer()

                VStack(spacing: 18) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.88))
                            .frame(width: 70, height: 70)

                        if let appIcon {
                            Image(nsImage: appIcon)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.black.opacity(0.75))
                        }
                    }

                    VStack(spacing: 6) {
                        Text("WallBlank はロックされています")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)

                        Text("Touch ID または Mac のパスワードで解除")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                    }

                    Button {
                        appLockManager.unlock()
                    } label: {
                        HStack(spacing: 8) {
                            if appLockManager.isAuthenticating {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            } else {
                                Image(systemName: "touchid")
                                    .font(.system(size: 16, weight: .semibold))
                            }

                            Text(appLockManager.isAuthenticating ? "認証中..." : "ロックを解除")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.black.opacity(0.34))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(appLockManager.isAuthenticating)

                    if let message = appLockManager.lastErrorMessage, !message.isEmpty {
                        Text(message)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.78))
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.bottom, 64)
            }
            .padding(.horizontal, 32)
        }
        .background(Color.black)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { value in
            now = value
        }
    }
}

struct AppLockContainer<Content: View>: View {
    @ObservedObject var appLockManager: AppLockManager
    let content: Content

    init(appLockManager: AppLockManager, @ViewBuilder content: () -> Content) {
        self.appLockManager = appLockManager
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
                .blur(radius: appLockManager.isLocked ? 12 : 0)
                .allowsHitTesting(!appLockManager.isLocked)

            if appLockManager.isLocked {
                VStack(spacing: 14) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)

                    Text("WallBlank はロックされています")
                        .font(.system(size: 18, weight: .semibold))

                    Text("Touch ID または Mac のパスワードで解除できます。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)

                    Button {
                        appLockManager.unlock()
                    } label: {
                        Label(appLockManager.isAuthenticating ? "認証中..." : "ロックを解除", systemImage: "touchid")
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appLockManager.isAuthenticating)

                    if let message = appLockManager.lastErrorMessage, !message.isEmpty {
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(28)
                .frame(maxWidth: 360)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.22), radius: 24, x: 0, y: 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.28))
                .ignoresSafeArea()
            }
        }
        .animation(.easeInOut(duration: 0.18), value: appLockManager.isLocked)
    }
}

@main
struct ArtiaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appLockManager = AppLockManager.shared

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        #if canImport(FirebaseCore)
        if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
            FirebaseApp.configure()

            // macOSではKeychainアクセスグループを明示的に設定しないと
            // Keychainエラーが発生する場合がある
            do {
                #if canImport(FirebaseAuth)
                try Auth.auth().useUserAccessGroup(nil)
                #endif
            } catch {
                debugLog("[Firebase] Keychainアクセスグループの設定に失敗: \(error.localizedDescription)")
            }
        } else {
            debugLog("[Firebase] GoogleService-Info.plist が見つかりません。ストア機能は無効です。")
        }
        #else
        debugLog("[Firebase] SDK が未解決のため、ストア機能は無効です。")
        #endif

    }
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // メインウィンドウ
        Window("WallBlank", id: "main") {
            AppLockContainer(appLockManager: appLockManager) {
                MainWindowView(appDelegate: appDelegate)
                    .onOpenURL { url in
                        #if canImport(GoogleSignIn)
                        GIDSignIn.sharedInstance.handle(url)
                        #endif
                    }
                    .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenMainWindow"))) { _ in
                        openMainWindow()
                    }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
        .defaultPosition(.center)
        .windowResizability(.contentSize)

        // エディターウィンドウ（別ウィンドウ）
        Window("WallBlank エディター", id: "editor") {
            AppLockContainer(appLockManager: appLockManager) {
                ImageEditorView()
            }
        }
        .defaultSize(width: 1200, height: 800)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .saveItem) {
                Button("プロジェクトを保存") {
                    ImageEditorManager.shared.showSaveDialog()
                }
                .keyboardShortcut("s", modifiers: .command)
            }
            // Phase 1.1+: ブラシ用ショートカット (B/E/[/]/1-9)
            EditorBrushCommands()
        }

        // メニューバーアイコン（バックグラウンド制御用）
        MenuBarExtra {
            MenuContentView(appDelegate: appDelegate, appLockManager: appLockManager)
        } label: {
            Image(systemName: "sparkles")
        }
    }

    private func openMainWindow() {
        WindowHelper.openMainWindow(using: openWindow)
    }
}

/// メインウィンドウのビュー
struct MainWindowView: View {
    @ObservedObject var appDelegate: AppDelegate
    @StateObject private var viewModel = MainWindowViewModel()

    var body: some View {
        Group {
            if let renderer = viewModel.renderer, let device = viewModel.device {
                MainHubWindowContent(
                    appDelegate: appDelegate,
                    library: WallpaperLibrary.shared,
                    previewRenderer: renderer,
                    device: device
                )
            } else if viewModel.setupFailed {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)
                    Text("このデバイスではMetalがサポートされていません")
                        .font(.headline)
                    Text("このアプリにはMetal対応のGPUが必要です。")
                        .foregroundColor(.secondary)
                }
                .frame(width: 900, height: 600)
            } else {
                ProgressView("読み込み中...")
                    .frame(width: 900, height: 600)
                    .onAppear {
                        viewModel.setupRenderer(appDelegate: appDelegate)
                    }
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .background(
            MainWindowAccessor { window in
                window.identifier = NSUserInterfaceItemIdentifier("main")
                window.title = "WallBlank"
                window.tabbingMode = .disallowed
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.isMovableByWindowBackground = true
            }
        )
    }
}

/// MainWindowViewの状態管理
class MainWindowViewModel: ObservableObject {
    @Published var renderer: Renderer?
    @Published var device: MTLDevice?
    @Published var setupFailed = false
    private var isSetup = false

    func setupRenderer(appDelegate: AppDelegate) {
        // 既にセットアップ済みまたは進行中の場合はスキップ
        guard !isSetup else { return }
        isSetup = true

        guard let dev = MTLCreateSystemDefaultDevice() else {
            debugLog("[Metal] Metalがサポートされていません")
            setupFailed = true
            return
        }

        let tempView = MTKView(frame: NSRect(x: 0, y: 0, width: 160, height: 90), device: dev)
        tempView.colorPixelFormat = .bgra8Unorm
        guard let newRenderer = Renderer(metalView: tempView) else {
            debugLog("[Renderer] レンダラーの作成に失敗しました")
            setupFailed = true
            return
        }
        newRenderer.currentShader = appDelegate.currentShader
        newRenderer.effectIntensity = appDelegate.effectIntensity
        newRenderer.volume = appDelegate.videoVolume
        newRenderer.updateEffectConfiguration(appDelegate.effectConfiguration)

        if let bgURL = appDelegate.backgroundImageURL {
            newRenderer.loadBackground(from: bgURL)
        }

        // マスクテクスチャを設定
        if let maskData = appDelegate.effectManager.maskData {
            newRenderer.updateMaskTexture(from: maskData)
        }

        // AppDelegateにレンダラーを登録（背景変更時に更新されるように）
        appDelegate.hubPreviewRenderer = newRenderer

        // 状態を更新
        self.device = dev
        self.renderer = newRenderer
    }
}

private final class MainWindowObserverView: NSView {
    var onResolveWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        onResolveWindow?(window)
    }
}

private struct MainWindowAccessor: NSViewRepresentable {
    let onResolveWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> MainWindowObserverView {
        let view = MainWindowObserverView()
        view.onResolveWindow = onResolveWindow
        return view
    }

    func updateNSView(_ nsView: MainWindowObserverView, context: Context) {
        nsView.onResolveWindow = onResolveWindow
        if let window = nsView.window {
            onResolveWindow(window)
        }
    }
}

/// メニューバーのコンテンツ
struct MenuContentView: View {
    @ObservedObject var appDelegate: AppDelegate
    @ObservedObject var appLockManager: AppLockManager
    @Environment(\.openWindow) private var openWindow


    var body: some View {
        Button("クライアントを開く") {
            WindowHelper.openMainWindow(using: openWindow)
        }

        Divider()

        Button(appLockManager.isLocked ? "ロックを解除" : "ロック") {
            if appLockManager.isLocked {
                appLockManager.unlock(using: appDelegate)
            } else {
                appLockManager.lock(using: appDelegate)
            }
        }
        .disabled(appLockManager.isAuthenticating)

        Divider()

        Button(appDelegate.isPaused ? "再開" : "一時停止") {
            appDelegate.togglePause()
        }

        Divider()

        Button(appDelegate.isLaunchAtLoginEnabled() ? "✓ ログイン時に起動" : "ログイン時に起動") {
            appDelegate.toggleLaunchAtLogin()
        }

        Divider()

        Button("WallBlank を終了") {
            NSApplication.shared.terminate(nil)
        }
    }
}

/// ウィンドウ操作のユーティリティ
enum WindowHelper {
    private static func isMainWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == "main" || window.title == "WallBlank"
    }

    private static func allMainWindows() -> [NSWindow] {
        var windows: [NSWindow] = []

        for window in NSApp.windows where isMainWindow(window) {
            if !windows.contains(where: { $0 === window }) {
                windows.append(window)
            }
            for tabbedWindow in window.tabbedWindows ?? [] where isMainWindow(tabbedWindow) {
                if !windows.contains(where: { $0 === tabbedWindow }) {
                    windows.append(tabbedWindow)
                }
            }
        }

        return windows
    }

    private static func consolidateMainWindows(preferredWindow: NSWindow? = nil) -> NSWindow? {
        let windows = allMainWindows()
        guard let primaryWindow = preferredWindow ?? windows.first else { return nil }

        primaryWindow.identifier = NSUserInterfaceItemIdentifier("main")
        primaryWindow.title = "WallBlank"
        primaryWindow.tabbingMode = .disallowed

        for window in windows where window !== primaryWindow {
            window.close()
        }

        return primaryWindow
    }

    /// メインウィンドウが既に開いているか
    private static func findMainWindow() -> NSWindow? {
        consolidateMainWindows()
    }

    private static func configureMainWindowForForeground(_ window: NSWindow) {
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.title = "WallBlank"
        window.tabbingMode = .disallowed
        if window.collectionBehavior.contains(.fullScreenAllowsTiling) {
            window.collectionBehavior.remove(.fullScreenAllowsTiling)
        }
    }

    /// 既存ウィンドウを現在アクティブなSpaceへ移して前面表示する
    private static func bringWindowToCurrentSpace(_ window: NSWindow) {
        configureMainWindowForForeground(window)
        let originalBehavior = window.collectionBehavior

        if !originalBehavior.contains(.moveToActiveSpace) {
            window.collectionBehavior.insert(.moveToActiveSpace)
        }

        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)

        if !originalBehavior.contains(.moveToActiveSpace) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                window.collectionBehavior.remove(.moveToActiveSpace)
            }
        }
    }

    /// メインウィンドウを開いて前面に表示（既に開いていれば前面に持ってくる。1つまで）
    static func openMainWindow(using openWindow: OpenWindowAction) {
        if let existing = findMainWindow() {
            bringWindowToCurrentSpace(existing)
            return
        }

        openWindow(id: "main")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let window = consolidateMainWindows() {
                bringWindowToCurrentSpace(window)
            }
        }
    }
}
