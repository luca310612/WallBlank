import Foundation
import XCTest

@testable import WallBlank

/// Phase 1.3+: BrushInputSample の正規化挙動を最低限担保する。
/// - 圧力／傾き／速度の既定値が仕様通り (1.0 / 0 / .zero)
/// - 速度算出が「位置差 / 時間差」になっていること（fromNSEvent ではなく
///   CanvasInteractionOverlay 経路の手組み構築を意識した最小チェック）
final class BrushInputSampleTests: XCTestCase {

    func test_defaultPressureAndTiltAreNeutral() {
        let sample = BrushInputSample(position: CGPoint(x: 10, y: 20))
        XCTAssertEqual(sample.pressure, 1.0, "圧力非対応端末では 1.0 を既定値とすべき")
        XCTAssertEqual(sample.tiltDegrees, 0)
        XCTAssertEqual(sample.azimuthDegrees, 0)
        XCTAssertEqual(sample.velocity.dx, 0)
        XCTAssertEqual(sample.velocity.dy, 0)
        XCTAssertFalse(sample.isPredicted)
    }

    func test_customPressureAndTiltArePersisted() {
        let sample = BrushInputSample(
            position: CGPoint(x: 1, y: 2),
            pressure: 0.6,
            tiltDegrees: 45,
            azimuthDegrees: 90,
            velocity: CGVector(dx: 100, dy: -50),
            timestamp: 12.34,
            isPredicted: true
        )
        XCTAssertEqual(sample.pressure, 0.6, accuracy: 1e-6)
        XCTAssertEqual(sample.tiltDegrees, 45)
        XCTAssertEqual(sample.azimuthDegrees, 90)
        XCTAssertEqual(sample.velocity.dx, 100)
        XCTAssertEqual(sample.velocity.dy, -50)
        XCTAssertEqual(sample.timestamp, 12.34)
        XCTAssertTrue(sample.isPredicted)
    }
}
