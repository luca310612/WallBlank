import Cocoa
import MetalKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - DisplayWallpaperInstance

/// 1つのディスプレイ用の壁紙ウィンドウインスタンス
class DisplayWallpaperInstance: NSObject {
    static let sameWebWallpaperReloadCooldown: TimeInterval = 1.0
    static let webWallpaperReadyPollInterval: TimeInterval = 0.2
    static let webWallpaperReadyTimeout: TimeInterval = 25.0
    static let webContentTerminationReloadWindow: TimeInterval = 30.0
    static let maxWebContentTerminationReloads = 1

    let displayID: String
    var screen: NSScreen

    var window: NSWindow?
    /// Metal と Web 壁紙を重ねるためのルート（`contentView`）
    var wallpaperRootView: NSView?
    var metalView: DroppableMTKView?
    var webWallpaperView: DroppableWKWebView?
    var pendingWebWallpaperView: DroppableWKWebView?
    /// 音楽プレイヤー型壁紙（難読化 JS が WKWebView で動かないものを WallBlank ネイティブで再生）
    var musicWallpaperHostView: NSView?
    /// 音楽プレイヤー型壁紙の表示中ルート
    var musicWallpaperActiveRoot: URL?
    /// 音楽プレイヤー型壁紙の Player 参照（壁紙切替時に音/MV を確実に止めるために保持）
    var musicWallpaperActivePlayer: MusicWallpaperPlayer?
    /// `index.html` を表示している間は Metal を止めて Web を最前面にする
    var isWebWallpaperActive: Bool = false
    /// Web 壁紙のロード中は何も前面に出さず、macOS 既存壁紙を見せる。
    var isWebWallpaperPendingActivation: Bool = false
    var renderer: Renderer?
    /// Phase 3A: 新規動画形式 (webm/avi/wmv) 用のランタイム。
    /// Why: 既存 Renderer の AVPlayer ベース経路は mp4/mov/m4v 限定のため、
    ///      未対応形式は AVAssetReader ベースで HW デコードして wgpu レイヤーへ供給する。
    var videoRuntime: VideoWallpaperRuntime?
    /// Phase 3C: 内製 .bundle プラグイン (NSViewController) を Application 壁紙としてホストするランタイム。
    /// Why: Wallpaper Engine の "Application" モード相当を macOS で実現するためには SIP 制約により .bundle のみ可能。
    ///      壁紙切替時に確実に NSViewController を解放できるよう DisplayWallpaperInstance に保持する。
    var applicationRuntime: BundlePluginRuntime?
    /// Application 壁紙の NSViewController.view を載せるホストビュー。
    /// Why: Renderer / Web 壁紙とは独立した layer 階層に置き、display 切替時にすぐ removeFromSuperview できる。
    var applicationHostView: NSView?
    /// `.app` ドロップ時に未対応説明 (ApplicationUnsupportedView) をホストする NSHostingView 用の親ビュー。
    var applicationUnsupportedHostView: NSView?
    /// 現在 Application 壁紙が表示されているか。Window level / 透過処理の分岐に使う。
    var isApplicationWallpaperActive: Bool = false
    var webLogHandler: WebLogHandler?
    /// Phase 3B: Wallpaper Engine 互換 JS API (wallpaperRegisterAudioListener 等) の native 受信ハンドラ。
    /// Why: 壁紙ロード時に bridge.js と一緒に登録し、WKWebView が破棄されるタイミングで一緒に nil にする。
    var webBridgeHandler: WebWallpaperBridgeHandler?
    var webServer: LocalHTTPFileServer?
    var webSchemeHandler: WallpaperWebSchemeHandler?
    var pendingWebSchemeHandler: WallpaperWebSchemeHandler?
    /// Web 壁紙の `project.json` を読み、WE 互換の `applyUserProperties` を送るために保持
    var webWallpaperProjectRoot: URL?
    var webWallpaperEntryFileURL: URL?
    var pendingWebWallpaperProjectRoot: URL?
    var pendingWebWallpaperEntryFileURL: URL?
    var pendingWebReadinessProbeTargetID: ObjectIdentifier?
    var webContentTerminationWindowStartedAt: Date?
    var webContentTerminationReloadCount = 0
    /// 起動直後の重複適用だけ抑制し、時間が経った同一壁紙の再実行は復旧目的で許可する。
    var webWallpaperLastLoadStartedAt: Date?
    var webWallpaperLastLoadFinishedAt: Date?
    var webWallpaperLastRequestedRoot: URL?
    var menuBarBlendView: NSVisualEffectView?
    var wallpaperTransitionOverlayView: NSImageView?

    /// フォルダ内のメディアファイル（プレイリスト用）
    var mediaPlaylist: [URL] = []
    var currentPlaylistIndex: Int = 0
    var playlistTimer: Timer?

    var currentResolutionScale: Float = 1.0
    var currentWebWallpaperScale: CGFloat
    var currentPerformancePreset: PerformancePreset
    var currentFrameRate: Int
    var isSystemSuspended = false
    var isDetachedFromDisplay = false

    // 設定マネージャー（DI対応）
    let settings: SettingsManagerProtocol
    // ディスプレイ管理（DI対応）
    // Why: refreshDisplayArrangement で他ディスプレイの screen を引くため、Singleton 直参照を排して注入する。
    let displays: any DisplayManagerProtocol

    // フルスクリーン・アクティブアプリ監視
    var fullscreenCheckTimer: Timer?
    var isScreenCoveredByFullscreen: Bool = false
    var isWebWallpaperPlaybackPaused: Bool = false
    var userRequestedPause: Bool = false  // ユーザーが明示的に一時停止を要求したか
    var appActivationObserver: NSObjectProtocol?

    // 二重解放防止フラグ
    var isDestroyed: Bool = false

    let overlayPadding: CGFloat = 50

    // MARK: - 計算プロパティ
    // Why: 元は各セクションの近接位置に置かれていたが、extension で参照するため class 本体に集約。

    /// Web 壁紙が前面提示されるべきか（ロード中のチラつきを避けるため pending を除外）
    var shouldPresentWebWallpaper: Bool {
        isWebWallpaperActive && !isWebWallpaperPendingActivation
    }

    /// 現在の Web 壁紙描画 FPS（ディスプレイのリフレッシュレートで上限を切る）
    var currentWebWallpaperFPS: Int {
        min(currentFrameRate, displayRefreshRate())
    }

    /// 現状のシステム状態から Web 壁紙の再生を一時停止すべきか
    var shouldPauseWebWallpaperPlayback: Bool {
        userRequestedPause || isSystemSuspended || isDetachedFromDisplay || isScreenCoveredByFullscreen
    }

    init(
        displayID: String,
        screen: NSScreen,
        settings: SettingsManagerProtocol = SharedSettingsManager.shared,
        displays: any DisplayManagerProtocol = DisplayManager.shared
    ) {
        self.displayID = displayID
        self.screen = screen
        self.settings = settings
        self.displays = displays
        self.currentWebWallpaperScale = CGFloat(settings.webWallpaperScale)
        self.currentPerformancePreset = settings.performancePreset
        self.currentFrameRate = settings.performanceFrameRate
        super.init()
        setupWindow()
        setupFullscreenMonitor()
    }
}
