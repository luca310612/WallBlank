import XCTest
import Combine
@testable import Artia

/// MockEventBus に対する subscribe/publish の確認。
/// Why: テスト時にイベントバスの spy が機能することを保証し、今後のイベント検証テストの土台にする。
final class EventBusTests: XCTestCase {

    func testPublishRecordsEventsAndNotifiesSubscriber() {
        let bus = MockEventBus()
        var received: [WallpaperEvent] = []

        let token = bus.subscribe { event in
            received.append(event)
        }

        bus.publish(.shaderChanged(shader: 1))
        bus.publish(.intensityChanged(intensity: 0.42))

        XCTAssertEqual(bus.publishedEvents.count, 2)
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(bus.subscribeCallCount, 1)

        // 1 件目の内容を検証
        if case .shaderChanged(let shader) = bus.publishedEvents[0] {
            XCTAssertEqual(shader, 1)
        } else {
            XCTFail("最初のイベントは shaderChanged のはず")
        }

        token.cancel()
    }

    func testResetSpyClearsHistory() {
        let bus = MockEventBus()
        bus.publish(.pauseStateChanged(paused: true))
        XCTAssertEqual(bus.publishedEvents.count, 1)

        bus.resetSpy()
        XCTAssertEqual(bus.publishedEvents.count, 0)
        XCTAssertEqual(bus.subscribeCallCount, 0)
    }
}
