import AppKit
import Foundation
import XCTest

@testable import Artia

/// Phase 4B: ParallaxNormalizer / ParallaxController のロジック検証。
///
/// テスト方針:
/// - NSEvent モニタは XCTest 環境では届かないため、`dispatchMouse(globalLocation:)` を直接呼ぶ。
/// - 計算ロジックは `ParallaxNormalizer.normalize` に純粋関数として切り出してあるので、
///   ここでは座標変換と register/unregister の動作を検証する。
final class ParallaxControllerTests: XCTestCase {

    // MARK: - Normalizer

    func test_normalize_centerYieldsZero() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let mid = CGPoint(x: 500, y: 400)
        let n = ParallaxNormalizer.normalize(mouse: mid, in: frame)
        XCTAssertEqual(n.x, 0, accuracy: 1e-4)
        XCTAssertEqual(n.y, 0, accuracy: 1e-4)
    }

    func test_normalize_topRightCornerYieldsOne() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let topRight = CGPoint(x: 1000, y: 800)
        let n = ParallaxNormalizer.normalize(mouse: topRight, in: frame)
        XCTAssertEqual(n.x, 1.0, accuracy: 1e-4)
        XCTAssertEqual(n.y, 1.0, accuracy: 1e-4)
    }

    func test_normalize_bottomLeftYieldsMinusOne() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let bottomLeft = CGPoint(x: 0, y: 0)
        let n = ParallaxNormalizer.normalize(mouse: bottomLeft, in: frame)
        XCTAssertEqual(n.x, -1.0, accuracy: 1e-4)
        XCTAssertEqual(n.y, -1.0, accuracy: 1e-4)
    }

    func test_normalize_outOfBoundsClampsToUnitRange() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let off = CGPoint(x: 5000, y: -2000)
        let n = ParallaxNormalizer.normalize(mouse: off, in: frame)
        XCTAssertEqual(n.x, 1.0, accuracy: 1e-4)
        XCTAssertEqual(n.y, -1.0, accuracy: 1e-4)
    }

    func test_normalize_zeroSizedFrameYieldsZero() {
        let frame = CGRect(x: 0, y: 0, width: 0, height: 0)
        let n = ParallaxNormalizer.normalize(mouse: .init(x: 50, y: 50), in: frame)
        XCTAssertEqual(n, .zero)
    }

    func test_normalize_offsetOriginFrameRespectsMidpoint() {
        // 画面 #2 のように原点が (1920, 0) 等にある場合でも、frame.midX/midY を
        // 中心とするべきであることを保証する。
        let frame = CGRect(x: 1920, y: 0, width: 1280, height: 720)
        let center = CGPoint(x: 1920 + 640, y: 360)
        let n = ParallaxNormalizer.normalize(mouse: center, in: frame)
        XCTAssertEqual(n.x, 0, accuracy: 1e-4)
        XCTAssertEqual(n.y, 0, accuracy: 1e-4)
    }

    // MARK: - Controller registration

    /// register / unregister が `registrationCount` に正しく反映されることを確認する。
    /// Why: NSEvent モニタは XCTest で起動しないが、登録テーブルの管理は重要。
    func test_register_unregister_updatesCount() throws {
        let initial = ParallaxController.shared.registrationCount

        // 偽の engine ポインタ — ParallaxController は dispatch しない限り deref しない。
        let fake1 = UnsafeMutableRawPointer(bitPattern: 0xDEADBEEF)!
        let fake2 = UnsafeMutableRawPointer(bitPattern: 0xCAFEBABE)!
        guard let screen = NSScreen.screens.first else {
            throw XCTSkip("NSScreen が利用できないためスキップ")
        }

        ParallaxController.shared.register(engine: fake1, screen: screen)
        ParallaxController.shared.register(engine: fake2, screen: screen)
        XCTAssertEqual(ParallaxController.shared.registrationCount, initial + 2)

        ParallaxController.shared.unregister(engine: fake1)
        ParallaxController.shared.unregister(engine: fake2)
        XCTAssertEqual(ParallaxController.shared.registrationCount, initial)
    }
}
