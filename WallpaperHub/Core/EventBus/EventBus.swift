import Foundation
import Combine

/// イベントバスの抽象化（テスト時に Mock を注入できるようにする）
/// Why: 既存呼び出し側を一切変更しないため、`EventBus` を本プロトコルに後方適合させる。
protocol EventBusProtocol: AnyObject {
    func publish(_ event: WallpaperEvent)
    func subscribe(_ handler: @escaping (WallpaperEvent) -> Void) -> AnyCancellable
}

/// 型安全なイベントバス
/// DistributedNotificationCenterを置き換え、Combineベースで実装
class EventBus: EventBusProtocol {
    static let shared = EventBus()

    private let eventSubject = PassthroughSubject<WallpaperEvent, Never>()
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    /// イベントを発行
    func publish(_ event: WallpaperEvent) {
        print("[EventBus] イベント発行: \(event.name)")
        eventSubject.send(event)
    }

    /// イベントを購読
    /// - Parameter handler: イベントを受け取るハンドラー
    /// - Returns: キャンセル可能な購読
    func subscribe(_ handler: @escaping (WallpaperEvent) -> Void) -> AnyCancellable {
        eventSubject
            .receive(on: DispatchQueue.main)
            .sink { event in
                handler(event)
            }
    }

    /// 特定のイベントタイプのみを購読
    /// - Parameters:
    ///   - filter: イベントをフィルタリングする条件
    ///   - handler: イベントを受け取るハンドラー
    /// - Returns: キャンセル可能な購読
    func subscribe(
        filter: @escaping (WallpaperEvent) -> Bool,
        handler: @escaping (WallpaperEvent) -> Void
    ) -> AnyCancellable {
        eventSubject
            .filter(filter)
            .receive(on: DispatchQueue.main)
            .sink { event in
                handler(event)
            }
    }

    /// 複数のイベントをバッチで購読
    /// - Parameter events: 購読するイベント名のセット
    /// - Parameter handler: イベントを受け取るハンドラー
    /// - Returns: キャンセル可能な購読
    func subscribeToEvents(
        _ eventNames: Set<String>,
        handler: @escaping (WallpaperEvent) -> Void
    ) -> AnyCancellable {
        subscribe(filter: { event in
            eventNames.contains(event.name)
        }, handler: handler)
    }
}
