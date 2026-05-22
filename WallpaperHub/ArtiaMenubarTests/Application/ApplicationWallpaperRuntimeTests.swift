import AppKit
import Foundation
import XCTest

@testable import WallBlank

/// Phase 3C: ApplicationWallpaperRuntime / WallpaperItem 拡張の挙動を検証するテスト。
/// - 内製 .bundle (NSPrincipalClass = NSViewController) のロード成功
/// - 不正パスの .bundle が `bundleNotFound` を投げる
/// - .app 拡張子が `appExtensionUnsupported` を投げる
/// - WallpaperItem.applicationFormat が拡張子から正しく判定する
///
/// テスト方針:
/// - Mach-O 実行コードを持たない疑似 .bundle を temp ディレクトリに合成して使う。
///   Why: テストフィクスチャをリポジトリに同梱せず、CI 上でも安定して再現可能にする。
///        Bundle.load() は executablePath が無い場合スキップされ、
///        Info.plist の NSPrincipalClass = "NSViewController" がランタイムで解決される。
final class ApplicationWallpaperRuntimeTests: XCTestCase {

    // MARK: - Fixture

    /// 一時ディレクトリに `Sample.bundle/Contents/Info.plist` を生成し、URL を返す。
    /// - Parameter principalClass: Info.plist の NSPrincipalClass に書き込むクラス名。
    private func makeMinimalBundle(principalClass: String = "NSViewController") throws -> URL {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ArtiaApplicationWallpaperRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = tempRoot.appendingPathComponent("Sample.bundle", isDirectory: true)
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        let infoPlist: [String: Any] = [
            "CFBundleIdentifier": "com.artia.test.sample-bundle",
            "CFBundleName": "Sample",
            "CFBundlePackageType": "BNDL",
            "CFBundleVersion": "1.0",
            "NSPrincipalClass": principalClass
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: infoPlist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))
        return bundleURL
    }

    private func cleanup(_ url: URL) {
        // テスト後に temp ディレクトリを掃除する。失敗しても無視する。
        if let parent = url.deletingLastPathComponent().pathComponents.last,
           parent.hasPrefix("ArtiaApplicationWallpaperRuntimeTests-") {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    // MARK: - Bundle ロード成功

    /// 最小構成の .bundle (NSPrincipalClass = NSViewController) がロード成功し、
    /// viewController() が NSViewController サブクラスを返すこと。
    func test_bundlePluginRuntime_loadsMinimalBundleSuccessfully() throws {
        let bundleURL = try makeMinimalBundle()
        defer { cleanup(bundleURL) }

        let runtime = BundlePluginRuntime()
        try runtime.load(bundleURL: bundleURL)

        let vc = runtime.viewController()
        XCTAssertNotNil(vc, "principalClass=NSViewController から NSViewController が生成されるべき")
        XCTAssertTrue(vc is NSViewController, "viewController() は NSViewController サブクラスを返すべき")

        runtime.unload()
        XCTAssertNil(runtime.viewController(), "unload 後は viewController() が nil を返すべき")
    }

    // MARK: - 不正 .bundle のロード失敗

    /// 存在しないパスを渡したとき `bundleNotFound` を投げること。
    func test_bundlePluginRuntime_throwsBundleNotFoundForMissingPath() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Nonexistent-\(UUID().uuidString).bundle")

        let runtime = BundlePluginRuntime()
        XCTAssertThrowsError(try runtime.load(bundleURL: missing)) { error in
            guard let runtimeError = error as? ApplicationWallpaperRuntimeError else {
                XCTFail("ApplicationWallpaperRuntimeError を期待したが \(type(of: error)) だった")
                return
            }
            switch runtimeError {
            case .bundleNotFound: break
            default: XCTFail("bundleNotFound を期待したが \(runtimeError) だった")
            }
        }
    }

    /// NSPrincipalClass が NSViewController サブクラスでない場合 `principalClassNotViewController` を投げること。
    /// Why: NSObject はアプリ起動時に常に runtime に存在するクラスなので、
    ///      "クラスは見つかるが ViewController ではない" 経路を確実に通せる。
    func test_bundlePluginRuntime_throwsWhenPrincipalClassIsNotViewController() throws {
        let bundleURL = try makeMinimalBundle(principalClass: "NSObject")
        defer { cleanup(bundleURL) }

        let runtime = BundlePluginRuntime()
        XCTAssertThrowsError(try runtime.load(bundleURL: bundleURL)) { error in
            guard let runtimeError = error as? ApplicationWallpaperRuntimeError else {
                XCTFail("ApplicationWallpaperRuntimeError を期待したが \(type(of: error)) だった")
                return
            }
            switch runtimeError {
            case .principalClassNotViewController: break
            default: XCTFail("principalClassNotViewController を期待したが \(runtimeError) だった")
            }
        }
    }

    // MARK: - .app は未対応

    /// `.app` 拡張子の URL を渡したとき `appExtensionUnsupported` を投げること。
    /// Why: macOS は SIP / Mission Control の制約により任意 .app をデスクトップ層へ固定できないため、
    ///      ランタイム入口で明示的にブロックする。
    func test_bundlePluginRuntime_throwsAppExtensionUnsupportedForAppURL() {
        let appURL = URL(fileURLWithPath: "/Applications/Safari.app")
        let runtime = BundlePluginRuntime()
        XCTAssertThrowsError(try runtime.load(bundleURL: appURL)) { error in
            guard let runtimeError = error as? ApplicationWallpaperRuntimeError else {
                XCTFail("ApplicationWallpaperRuntimeError を期待したが \(type(of: error)) だった")
                return
            }
            XCTAssertEqual(runtimeError, .appExtensionUnsupported)
        }
    }

    // MARK: - WallpaperItem 拡張子判定

    /// `.bundle` URL に対して `detectApplicationFormat` が `.bundle` を返すこと。
    func test_wallpaperItem_detectsBundleFormat() {
        let url = URL(fileURLWithPath: "/tmp/Plugin.bundle")
        XCTAssertEqual(WallpaperItem.detectApplicationFormat(for: url), .bundle)
        XCTAssertTrue(WallpaperItem.isApplicationExtension(url))
    }

    /// `.app` URL に対して `detectApplicationFormat` が `.appBlocked` を返すこと。
    func test_wallpaperItem_detectsAppBlockedFormat() {
        let url = URL(fileURLWithPath: "/Applications/Sample.app")
        XCTAssertEqual(WallpaperItem.detectApplicationFormat(for: url), .appBlocked)
        XCTAssertTrue(WallpaperItem.isApplicationExtension(url))
    }

    /// それ以外の拡張子では nil を返すこと。
    func test_wallpaperItem_returnsNilForNonApplicationExtensions() {
        let mp4 = URL(fileURLWithPath: "/tmp/movie.mp4")
        XCTAssertNil(WallpaperItem.detectApplicationFormat(for: mp4))
        XCTAssertFalse(WallpaperItem.isApplicationExtension(mp4))
    }

    /// WallpaperItem インスタンスの fileName から isApplication / applicationFormat が解決されること。
    /// Why: テスト要件「.app の場合は isApplication=true / format=.appBlocked を返す」を満たす。
    func test_wallpaperItem_instanceProperties_resolveFromFileName() {
        let appItem = WallpaperItem(
            name: "Sample.app",
            type: .image,
            thumbnailName: "thumb.png",
            fileName: "Sample.app"
        )
        XCTAssertTrue(appItem.isApplication)
        XCTAssertEqual(appItem.applicationFormat, .appBlocked)

        let bundleItem = WallpaperItem(
            name: "Plugin.bundle",
            type: .image,
            thumbnailName: "thumb.png",
            fileName: "Plugin.bundle"
        )
        XCTAssertTrue(bundleItem.isApplication)
        XCTAssertEqual(bundleItem.applicationFormat, .bundle)

        let imageItem = WallpaperItem(
            name: "wallpaper.jpg",
            type: .image,
            thumbnailName: "thumb.png",
            fileName: "wallpaper.jpg"
        )
        XCTAssertFalse(imageItem.isApplication)
        XCTAssertNil(imageItem.applicationFormat)
    }
}
