import AppKit
import Foundation

// MARK: - ApplicationWallpaperRuntimeProtocol

/// Phase 3C: Application 壁紙ランタイムの抽象インターフェース。
/// Why: 内製 .bundle (NSViewController プラグイン) を AppKit プロセス内で動的ロードする経路と、
///      将来の代替実装 (例: SwiftUI ホスト) を差し替えられるようにプロトコル化する。
protocol ApplicationWallpaperRuntimeProtocol: AnyObject {
    /// 指定された .bundle を解決し、principalClass の NSViewController を生成する。
    /// - Throws: ロード不能時 `ApplicationWallpaperRuntimeError`。
    func load(bundleURL: URL) throws

    /// ロード済みプラグインから NSViewController を取得する。`load` 前は nil。
    func viewController() -> NSViewController?

    /// プラグインを解放する。NSViewController.view を superview から外し、参照を nil 化する。
    /// - Note: macOS の Bundle はアンロードを公式サポートしないため、メモリは常駐したまま。
    func unload()
}

// MARK: - ApplicationWallpaperRuntimeError

/// `BundlePluginRuntime.load` が投げるエラー。
/// Why: macOS では SIP / App Sandbox / Mach-O 制約により、許容ケース (内製 .bundle) と
///      非許容ケース (任意 .app) を明示的に切り分け、UI 側で適切な誘導文を出す必要がある。
enum ApplicationWallpaperRuntimeError: LocalizedError, Equatable {
    case bundleNotFound(URL)
    case bundleLoadFailed(URL)
    case principalClassMissing(URL)
    case principalClassNotViewController(String)
    case appExtensionUnsupported

    var errorDescription: String? {
        switch self {
        case .bundleNotFound(let url):
            return "指定された .bundle が見つかりませんでした: \(url.lastPathComponent)"
        case .bundleLoadFailed(let url):
            return ".bundle のロードに失敗しました: \(url.lastPathComponent)"
        case .principalClassMissing(let url):
            return ".bundle の Info.plist に NSPrincipalClass が定義されていません: \(url.lastPathComponent)"
        case .principalClassNotViewController(let name):
            return "NSPrincipalClass \(name) は NSViewController サブクラスではありません"
        case .appExtensionUnsupported:
            return ".app のホストは macOS 仕様 (SIP / Mission Control) 上サポートしていません"
        }
    }
}

// MARK: - BundlePluginRuntime

/// AppKit `Bundle` 経由で .bundle を動的ロードし、NSPrincipalClass の NSViewController を取得する実装。
/// Why: Wallpaper Engine 互換の "Application 壁紙" のうち macOS で実現可能な範囲は、
///      App Sandbox 内で許可された dynamic linker 経由のロードに限定される。
///      任意 3rd party .app の取り込みは macOS では実現不能なため、本クラスで弾く。
final class BundlePluginRuntime: ApplicationWallpaperRuntimeProtocol {
    private var loadedBundle: Bundle?
    private var hostedViewController: NSViewController?

    init() {}

    func load(bundleURL: URL) throws {
        // 1. 拡張子が .app の場合は明示的に未対応として弾く。
        //    Why: 任意プロセスのウィンドウを desktop window level に貼る OS API が macOS には存在しない。
        if bundleURL.pathExtension.lowercased() == WallpaperItem.appBlockedExtension {
            throw ApplicationWallpaperRuntimeError.appExtensionUnsupported
        }

        // 2. ファイルシステム上に存在するか確認する。
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw ApplicationWallpaperRuntimeError.bundleNotFound(bundleURL)
        }

        // 3. Bundle として開けるか確認する。
        guard let bundle = Bundle(url: bundleURL) else {
            throw ApplicationWallpaperRuntimeError.bundleLoadFailed(bundleURL)
        }

        // 4. 実行コードがある .bundle のみ Bundle.load() を実行する。
        //    Why: テスト fixtures など Mach-O を持たない疑似 .bundle でも、
        //         NSPrincipalClass がランタイム既知クラスを指していれば principalClass で解決できるため、
        //         executablePath が無い場合は load() をスキップする。
        if bundle.executablePath != nil {
            guard bundle.load() else {
                throw ApplicationWallpaperRuntimeError.bundleLoadFailed(bundleURL)
            }
        }

        // 5. NSPrincipalClass の解決と NSViewController サブクラス検証。
        //    Why: Mach-O 実行コードを持たない .bundle (=テストフィクスチャ等) では
        //         `bundle.principalClass` が nil を返すため、Info.plist の文字列を
        //         `NSClassFromString` で直接ランタイム解決するフォールバックを設ける。
        let principal: AnyClass
        if let direct = bundle.principalClass {
            principal = direct
        } else if let className = bundle.infoDictionary?["NSPrincipalClass"] as? String,
                  let resolved = NSClassFromString(className) {
            principal = resolved
        } else {
            throw ApplicationWallpaperRuntimeError.principalClassMissing(bundleURL)
        }
        guard let vcClass = principal as? NSViewController.Type else {
            throw ApplicationWallpaperRuntimeError.principalClassNotViewController(NSStringFromClass(principal))
        }

        let vc = vcClass.init()
        loadedBundle = bundle
        hostedViewController = vc
    }

    func viewController() -> NSViewController? {
        hostedViewController
    }

    func unload() {
        // view が hierarchy 上にあれば外す。viewDidDisappear などライフサイクルは AppKit に委譲。
        if let vc = hostedViewController, vc.isViewLoaded {
            vc.view.removeFromSuperview()
        }
        hostedViewController = nil
        // Bundle 自身のアンロードは macOS では公式サポートが無く、参照を切ることでのみ解放を待つ。
        loadedBundle = nil
    }
}
