import Cocoa
import ScreenSaver

/// Phase 9A: WallBlank スクリーンセーバー本体。
///
/// 目標 (本フェーズの最低ライン):
/// - .saver バンドルとして System Settings → Screen Saver に登録できる
/// - preview / 全画面どちらでも `animateOneFrame` で何かを描画する
/// - configureSheet で「壁紙の選択」「フレームレート」が編集できる
///
/// 注意:
/// - スクリーンセーバーは独立プロセスで動くので、メインアプリの `WgpuEngine` を
///   そのまま import するためには ArtiaCore.framework 化が必要。
/// - 本フェーズでは framework 化を保留し、最低限のスタブ描画 (グラデーション + 壁紙名) に留める。
/// - 設定値は App Group `group.com.artia.shared` の UserDefaults から読む。
public final class ArtiaScreenSaverView: ScreenSaverView {

    /// App Group 経由で受け取る現在のフレームレート (default 30)
    private var preferredFrameRate: Int = 30

    /// アニメーション時刻 (animateOneFrame 毎に進める)
    private var elapsed: TimeInterval = 0

    /// 描画用にキャッシュした NSImage (現在の壁紙サムネイル)
    private var cachedThumbnail: NSImage?

    /// 設定シートのコントローラ (lazy)
    private lazy var configController: ArtiaScreenSaverConfigController = {
        ArtiaScreenSaverConfigController()
    }()

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / Double(preferredFrameRate)
        loadSharedSettings()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0 / Double(preferredFrameRate)
        loadSharedSettings()
    }

    // MARK: - 設定読み込み

    /// App Group 共有 UserDefaults から「現在の壁紙サムネイル」と「フレームレート」を取得する
    private func loadSharedSettings() {
        let defaults = UserDefaults(suiteName: "group.com.artia.shared") ?? .standard
        if let path = defaults.string(forKey: "widget.currentWallpaperThumbnailPath"),
           let img = NSImage(contentsOfFile: path) {
            cachedThumbnail = img
        }
        let fps = defaults.integer(forKey: "screensaver.preferredFrameRate")
        if fps > 0 {
            preferredFrameRate = fps
            animationTimeInterval = 1.0 / Double(fps)
        }
    }

    // MARK: - アニメーション

    /// 1 フレーム分の進捗。スクリーンセーバーは ScreenSaver.framework が周期的に呼ぶ。
    public override func animateOneFrame() {
        elapsed += animationTimeInterval
        setNeedsDisplay(bounds)
    }

    public override func draw(_ rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 背景: ゆっくり動くグラデーション (壁紙が無いときのフォールバック)
        let phase = CGFloat((sin(elapsed) + 1) / 2)
        let top = NSColor(calibratedRed: 0.05 + 0.10 * phase, green: 0.10, blue: 0.20 + 0.10 * (1 - phase), alpha: 1)
        let bottom = NSColor(calibratedRed: 0.10 + 0.05 * (1 - phase), green: 0.05, blue: 0.10 + 0.10 * phase, alpha: 1)
        let gradient = NSGradient(colors: [top, bottom])
        gradient?.draw(in: bounds, angle: 90)

        // 壁紙サムネイルを中央に重ねる (あれば)
        if let img = cachedThumbnail {
            let aspect = img.size.width / max(img.size.height, 1)
            let targetHeight = bounds.height * 0.6
            let targetWidth = targetHeight * aspect
            let target = NSRect(
                x: (bounds.width - targetWidth) / 2,
                y: (bounds.height - targetHeight) / 2,
                width: targetWidth,
                height: targetHeight
            )
            img.draw(in: target)
        }

        // タイトル
        let title = "WallBlank"
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            .font: NSFont.systemFont(ofSize: max(bounds.height * 0.05, 18), weight: .light)
        ]
        let attributed = NSAttributedString(string: title, attributes: attrs)
        let size = attributed.size()
        let titleRect = NSRect(
            x: (bounds.width - size.width) / 2,
            y: 24,
            width: size.width,
            height: size.height
        )
        attributed.draw(in: titleRect)

        // CGContext は使い終わったら明示的にフラッシュ不要 (AppKit が管理)
        _ = context
    }

    // MARK: - 設定シート

    public override var hasConfigureSheet: Bool { true }

    public override var configureSheet: NSWindow? {
        configController.window
    }
}
