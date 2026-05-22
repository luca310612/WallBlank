import Foundation
import os.log

/// アプリ全体で使用される定数
enum AppConstants {

    // MARK: - App Identity

    /// 表示名（メニュー・ウィンドウタイトル等）
    static let appDisplayName = "WallBlank"
    /// キャッシュ・Application Support 等のディレクトリ名（統一用）
    static let appFolderName = "WallBlank"

    // MARK: - Timer Intervals

    enum TimerIntervals {
        /// フルスクリーン検出ポーリング間隔（秒）
        static let fullscreenCheck: TimeInterval = 1.0
        /// GPU使用率監視間隔（秒）
        static let gpuMonitoring: TimeInterval = 2.0
        /// プレイリスト切り替え間隔（秒）
        static let playlistDefault: TimeInterval = 10.0
        /// テクスチャキャッシュフラッシュ間隔（秒）
        static let textureCacheFlush: TimeInterval = 2.0
        /// クリックエフェクト持続時間（秒）
        static let clickEffectDuration: TimeInterval = 2.0
        /// デバウンス間隔（秒）
        static let debounce: TimeInterval = 0.1
        /// ウィンドウ表示遅延（秒）
        static let windowActivationDelay: TimeInterval = 0.1
    }

    // MARK: - GPU & Performance

    enum Performance {
        /// GPU使用率閾値デフォルト（%）
        static let defaultGPUThreshold: Float = 80.0
        /// フルスクリーンカバレッジ閾値
        static let fullscreenCoverageThreshold: CGFloat = 0.95
        /// 最小ウィンドウサイズ（ピクセル）
        static let minWindowSize: CGFloat = 100
        /// デフォルトリフレッシュレート（Hz）
        static let defaultRefreshRate: Int = 60
    }

    // MARK: - Rendering

    enum Rendering {
        /// トリプルバッファリング最大フレーム数
        static let maxFramesInFlight: Int = 3
        /// Uniformバッファアライメントマスク
        static let uniformAlignmentMask: Int = 0xFF
    }

    // MARK: - GIF Streaming

    enum GIF {
        /// リングバッファデフォルトサイズ（フレーム数）
        static let ringBufferDefaultSize: Int = 10
        /// リングバッファ最小サイズ
        static let ringBufferMinSize: Int = 3
        /// リングバッファ最大サイズ
        static let ringBufferMaxSize: Int = 15
        /// ターゲット最大メモリ使用量（MB）
        static let targetMaxMemoryMB: Int = 200
        /// デフォルトフレーム遅延（秒）
        static let defaultFrameDelay: Double = 0.1
        /// プリフェッチ範囲（フレーム数）
        static let prefetchRange: Int = 3
    }

    // MARK: - Hair Segmentation

    enum HairSegmentation {
        /// 人物マスク信頼度閾値
        static let personMaskThreshold: Float = 0.5
        /// 髪領域信頼度閾値
        static let hairRegionThreshold: Float = 0.3
        /// フォールバック髪領域比率（人物高さに対する割合）
        static let fallbackHairRegionRatio: Float = 0.25
        /// 顔検出時の髪領域下端マージン（顔高さに対する割合）
        static let faceBasedHairMargin: Float = 0.3
        /// フォールバック顔幅比率（画像幅に対する割合）
        static let fallbackFaceWidthRatio: Float = 0.4
        /// グラデーション指数
        static let gradientExponent: Float = 0.7
        /// 横方向ウェイト係数
        static let horizontalWeightFactor: Float = 0.3
        /// 顔幅マルチプライヤー
        static let faceWidthMultiplier: Float = 1.5
        /// マスクスムージング用ブラー半径
        static let maskBlurRadius: Int = 5
    }

    // MARK: - Export

    enum Export {
        /// GIF最大FPS
        static let gifMaxFPS: Int = 30
        /// GIF最大長さ（秒）
        static let gifMaxDuration: Double = 10.0
    }

    // MARK: - Editor

    enum Editor {
        /// エディターのデフォルトキャンバスサイズ
        static let defaultCanvasWidth: Int = 1920
        static let defaultCanvasHeight: Int = 1080
        /// Undo/Redoの最大ステップ数
        static let maxUndoSteps: Int = 50
        /// レンダリングデバウンス間隔（秒）
        static let renderDebounceInterval: TimeInterval = 0.05
        /// アニメーションデフォルトFPS
        static let defaultFPS: Double = 24
        /// アニメーションデフォルト長さ（秒）
        static let defaultDuration: Double = 5.0
        /// サポートする画像拡張子
        static let supportedImageExtensions = ["png", "jpg", "jpeg", "heic", "tiff", "bmp"]
    }

    // MARK: - Wallpaper window (desktop expose)

    enum WallpaperWindow {
        /// Web 以外の壁紙面（Metal・メニューバー帯など）を何回クリックしたら `orderBack` してデスクトップを操作しやすくするか（1 = 従来どおり 1 回で奥へ）。
        static let clicksBeforeDesktopExpose: Int = 3
        /// デスクトップ露出用クリックカウントを、操作が途切れてから何秒でリセットするか。
        static let desktopExposeClickResetSeconds: TimeInterval = 2.5
        /// `orderBack` 後、Finder が前に出ても壁紙を自動で最前面に戻さない時間（秒）。この間はデスクトップアイコン等を操作しやすい。
        static let suppressFinderAutoReorderSeconds: TimeInterval = 12.0
    }

    // MARK: - Web Wallpaper (WKWebView)

    enum WebWallpaper {
        /// デスクトップ直後のウィンドウでは、1 クリック目が前面化だけで終わり Web に届かずボタンが効かないことがある。
        /// **何回目のクリックを WebKit に渡すか**（1 = 毎回すぐ渡す＝UI を最初から使える、3 = 先に前面化だけを複数回）。
        static let mouseClicksBeforeWebDelivery: Int = 1
        /// 上記のクリックカウントを、操作が途切れてから何秒でリセットするか（また最初から数え直し）。
        static let mouseActivationSequenceResetSeconds: TimeInterval = 2.5
    }

    // MARK: - Application Wallpaper (.bundle / .app)

    /// Phase 3C: Application 壁紙ランタイム関連の定数。
    /// Why: macOS では .app のホストが SIP / Mission Control 制約により不可なので、
    ///      未対応説明 UI から飛ばすドキュメント URL とラベルをここに集約する。
    enum ApplicationWallpaper {
        /// `.app` ドロップ時に開く解説ページ。Wallpaper Engine 公式 macOS ガイドが存在しないため、
        /// WallBlank 自前のドキュメントを案内する。
        static let documentationURL = URL(string: "https://artia.app/docs/application-wallpaper-macos")!
        /// 未対応説明 UI に表示する見出しの日本語文。
        static let unsupportedHeadline = "macOS 版では .app の壁紙化に対応していません"
        /// 未対応説明 UI に表示する詳細メッセージの日本語文。
        static let unsupportedMessage = """
        macOS は SIP / Mission Control の制約により、任意の .app を デスクトップウィンドウ層へ強制配置することができません。
        WallBlank では「内製 .bundle プラグイン」のみを Application 壁紙としてホストできます。
        詳細は下記のドキュメントをご確認ください。
        """
    }

    // MARK: - Schedule

    enum Schedule {
        /// 最小ローテーション間隔（秒）
        static let minimumInterval: TimeInterval = 60.0
        /// デフォルトローテーション間隔（秒）
        static let defaultInterval: TimeInterval = 3600.0
        /// 間隔プリセット（秒）
        static let presets: [(label: String, interval: TimeInterval)] = [
            ("1分", 60),
            ("5分", 300),
            ("15分", 900),
            ("30分", 1800),
            ("1時間", 3600),
            ("2時間", 7200),
            ("4時間", 14400),
            ("24時間", 86400)
        ]
    }
}

// MARK: - デバッグログ

/// DEBUGビルドのみコンソール出力するログ関数（Releaseではファイルパス等の情報漏洩を防止）
@inline(__always)
func debugLog(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    #if DEBUG
    let output = items.map { "\($0)" }.joined(separator: separator)
    print(output, terminator: terminator)
    #endif
}

// MARK: - 常時 Unified Logging

/// `Logger` の notice は環境によって `log stream` の `--level` と噛み合わないことがあるため `os_log(.info)` を使う。
private let artiaWebWallpaperOSLog = OSLog(subsystem: "com.artia.app", category: "WebWallpaper")

/// 診断ログをファイルに追記するためのキュー（書き込みを直列化して行の混線を防ぐ）。
private let artiaWebLogFileQueue = DispatchQueue(label: "com.artia.app.web-debug-log", qos: .utility)

/// 診断ログの出力先ファイル URL（`~/Library/Logs/WallBlank/web-debug.log`）。
private let artiaWebLogFileURL: URL = {
    let fm = FileManager.default
    let logsDir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Logs")
        .appendingPathComponent("WallBlank") ?? URL(fileURLWithPath: "/tmp")
    try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
    return logsDir.appendingPathComponent("web-debug.log")
}()

private let artiaWebLogTimestampFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

/// Web 壁紙・ローカル HTTP の診断用（DEBUG/Release 関係なく Unified Logging とログファイルに出る）
func artiaWebLog(_ message: String) {
    os_log("%{public}@", log: artiaWebWallpaperOSLog, type: .info, message)
    fputs("[WallBlank:WebWallpaper] \(message)\n", stderr)

    let line = "\(artiaWebLogTimestampFormatter.string(from: Date())) \(message)\n"
    artiaWebLogFileQueue.async {
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: artiaWebLogFileURL.path) {
            if let handle = try? FileHandle(forWritingTo: artiaWebLogFileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: artiaWebLogFileURL, options: [.atomic])
        }
    }
}
