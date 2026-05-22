import Foundation
import Combine
@testable import WallBlank

/// EventBusProtocol の Mock 実装（spy 機能付き）。
/// Why: テスト時に publish された WallpaperEvent を直接検証するため、Combine 経由ではなく配列に記録する。
final class MockEventBus: EventBusProtocol {
    /// 発行されたイベントの履歴（最新が末尾）
    private(set) var publishedEvents: [WallpaperEvent] = []

    /// 直近の subscribe 呼び出し回数
    private(set) var subscribeCallCount: Int = 0

    private let subject = PassthroughSubject<WallpaperEvent, Never>()

    func publish(_ event: WallpaperEvent) {
        publishedEvents.append(event)
        subject.send(event)
    }

    func subscribe(_ handler: @escaping (WallpaperEvent) -> Void) -> AnyCancellable {
        subscribeCallCount += 1
        return subject.sink { event in
            handler(event)
        }
    }

    /// テストヘルパ: 履歴をリセット
    func resetSpy() {
        publishedEvents.removeAll()
        subscribeCallCount = 0
    }
}
