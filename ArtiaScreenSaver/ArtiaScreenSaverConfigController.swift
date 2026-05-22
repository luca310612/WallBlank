import Cocoa

/// Phase 9A: スクリーンセーバー設定シート。
/// 表示要素:
///   - フレームレート切替 (30 / 60)
///   - "Artia アプリで詳細設定" ボタン (artia:// URL を open する)
///
/// 設定値は App Group の UserDefaults に書き込まれ、ArtiaScreenSaverView が起動時に読み取る。
final class ArtiaScreenSaverConfigController: NSObject {

    /// シート用のウィンドウ。NSPanel ベース。
    let window: NSWindow

    /// フレームレート選択 (30 / 60)
    private let fpsPopUp: NSPopUpButton

    /// OK / キャンセルボタン
    private let okButton: NSButton
    private let openAppButton: NSButton

    override init() {
        let frame = NSRect(x: 0, y: 0, width: 320, height: 160)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Artia スクリーンセーバー設定"
        panel.isReleasedWhenClosed = false

        let contentView = NSView(frame: frame)

        // FPS ラベル
        let fpsLabel = NSTextField(labelWithString: "フレームレート:")
        fpsLabel.frame = NSRect(x: 20, y: 110, width: 120, height: 20)
        contentView.addSubview(fpsLabel)

        let popup = NSPopUpButton(frame: NSRect(x: 140, y: 105, width: 120, height: 26))
        popup.addItems(withTitles: ["30 FPS", "60 FPS"])
        let defaults = UserDefaults(suiteName: "group.com.artia.shared") ?? .standard
        let stored = defaults.integer(forKey: "screensaver.preferredFrameRate")
        popup.selectItem(at: stored == 60 ? 1 : 0)
        contentView.addSubview(popup)
        self.fpsPopUp = popup

        // 詳細設定ボタン (Artia アプリ起動)
        let openApp = NSButton(frame: NSRect(x: 20, y: 60, width: 280, height: 26))
        openApp.title = "Artia アプリで壁紙を選ぶ"
        openApp.bezelStyle = .rounded
        contentView.addSubview(openApp)
        self.openAppButton = openApp

        // OK ボタン
        let ok = NSButton(frame: NSRect(x: 220, y: 16, width: 80, height: 26))
        ok.title = "OK"
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        contentView.addSubview(ok)
        self.okButton = ok

        panel.contentView = contentView
        self.window = panel

        super.init()

        // self を参照する target/action は init の最後で設定する
        openApp.target = self
        openApp.action = #selector(openArtiaApp(_:))
        ok.target = self
        ok.action = #selector(closeSheet(_:))
    }

    @objc private func closeSheet(_ sender: Any?) {
        let defaults = UserDefaults(suiteName: "group.com.artia.shared") ?? .standard
        let fps = fpsPopUp.indexOfSelectedItem == 1 ? 60 : 30
        defaults.set(fps, forKey: "screensaver.preferredFrameRate")
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.orderOut(nil)
        }
    }

    @objc private func openArtiaApp(_ sender: Any?) {
        if let url = URL(string: "artia://") {
            NSWorkspace.shared.open(url)
        }
    }
}
