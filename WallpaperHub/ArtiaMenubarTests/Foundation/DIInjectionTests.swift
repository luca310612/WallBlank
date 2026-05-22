import XCTest
import AppKit
@testable import WallBlank

/// DI が機能していることを最低限確認する基盤テスト。
/// Why: 各 Protocol の Mock を WallpaperEngine / DisplayWallpaperInstance に注入できることを検証する。
final class DIInjectionTests: XCTestCase {

    func testWallpaperEngineAcceptsMockDependencies() throws {
        // NSScreen が無い環境では skip（CI 等のヘッドレス用フォールバック）
        guard NSScreen.main != nil else {
            throw XCTSkip("NSScreen.main が無い環境では DisplayWallpaperInstance 初期化を検証できない")
        }
        let settings = MockSettingsManager()
        let displays = MockDisplayManager()

        // 構築だけ通ることを確認（重い setup 副作用を避けるためインスタンス参照は最小限）
        let engine = WallpaperEngine(settings: settings, displayManager: displays)
        XCTAssertNotNil(engine)

        // settings は startObserving が一度呼ばれているはず
        XCTAssertEqual(settings.startObservingCallCount, 1)
    }

    func testDisplayWallpaperInstanceAcceptsMockDependencies() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("NSScreen.main が無い環境では DisplayWallpaperInstance 初期化を検証できない")
        }
        let settings = MockSettingsManager()
        let displays = MockDisplayManager()

        let instance = DisplayWallpaperInstance(
            displayID: "test-display-1",
            screen: screen,
            settings: settings,
            displays: displays
        )

        XCTAssertEqual(instance.displayID, "test-display-1")
        // teardown も問題なく通ることを確認
        instance.destroy()
    }
}
