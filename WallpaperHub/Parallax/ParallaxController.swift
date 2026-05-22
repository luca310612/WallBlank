import AppKit
import Foundation

// Phase 4B: パララックス (マウス連動レイヤーオフセット)
// Why: Wallpaper Engine 互換のレイヤー深度演出として、画面相対位置を正規化して
//      WgpuEngine.update_parallax(...) を 60fps で呼び出す。
//      ジャイロ (CMMotionManager) は macOS 非対応 — iPad 移植時に追加予定。

/// パララックス対象のエンジンを表す軽量 Box。
/// Why: `UnsafeMutableRawPointer` を Identifiable として扱うために包む。
final class ParallaxEngineRegistration {
    let engine: UnsafeMutableRawPointer
    var screen: NSScreen
    var enabled: Bool

    init(engine: UnsafeMutableRawPointer, screen: NSScreen, enabled: Bool = true) {
        self.engine = engine
        self.screen = screen
        self.enabled = enabled
    }
}

/// マウス位置 → 画面相対正規化座標の変換ロジック。
///
/// Why: テスト容易性のために pure function に切り出す。NSEvent / NSScreen に依存せず、
///      `frame: CGRect`, `mouse: CGPoint` の純粋計算で再現できる。
enum ParallaxNormalizer {
    /// 画面中央を (0,0)、画面端を ±1.0 にスケーリングしたマウスオフセットを返す。
    /// 範囲外は ±1.0 にクランプする。
    static func normalize(mouse: CGPoint, in frame: CGRect) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        let nx = ((mouse.x - frame.midX) / (frame.width * 0.5))
        let ny = ((mouse.y - frame.midY) / (frame.height * 0.5))
        return CGPoint(
            x: max(-1.0, min(1.0, nx)),
            y: max(-1.0, min(1.0, ny))
        )
    }
}

/// グローバルマウス追跡 → 登録エンジンへの正規化オフセット配信を担うコントローラ。
final class ParallaxController {
    static let shared = ParallaxController()

    private var registrations: [Int: ParallaxEngineRegistration] = [:]
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let queue = DispatchQueue(label: "com.artia.parallax.controller")

    /// 直近のグローバル正規化オフセット (テスト/デバッグ用)。
    private(set) var lastNormalizedOffset: CGPoint = .zero

    private init() {}

    deinit {
        stopMonitoring()
    }

    // MARK: - Registration

    /// 指定エンジンをパララックス追従対象に登録する。
    /// - Parameters:
    ///   - engine: WgpuEngine ハンドル
    ///   - screen: 正規化基準とする NSScreen
    func register(engine: UnsafeMutableRawPointer, screen: NSScreen) {
        let key = Int(bitPattern: engine)
        queue.sync {
            registrations[key] = ParallaxEngineRegistration(engine: engine, screen: screen)
        }
        startMonitoringIfNeeded()
    }

    /// 登録済みエンジンの screen を更新する (ディスプレイ移動時)。
    func updateScreen(engine: UnsafeMutableRawPointer, screen: NSScreen) {
        let key = Int(bitPattern: engine)
        queue.sync { registrations[key]?.screen = screen }
    }

    /// 指定エンジンを追跡対象から外す。
    func unregister(engine: UnsafeMutableRawPointer) {
        let key = Int(bitPattern: engine)
        _ = queue.sync { registrations.removeValue(forKey: key) }
        if registrations.isEmpty {
            stopMonitoring()
        }
    }

    /// 登録数 (テスト用)。
    var registrationCount: Int {
        queue.sync { registrations.count }
    }

    // MARK: - Manual update (test 用 / 動的呼び出し用)

    /// 既知のグローバルマウス位置を直接配信する。
    ///
    /// Why: NSEvent モニタが届かない環境 (XCTest) でも動作確認できるよう、
    ///      公開 API として用意する。
    func dispatchMouse(globalLocation: CGPoint) {
        let snapshot: [ParallaxEngineRegistration] = queue.sync {
            Array(registrations.values)
        }
        for reg in snapshot {
            guard reg.enabled else { continue }
            let normalized = ParallaxNormalizer.normalize(
                mouse: globalLocation,
                in: reg.screen.frame
            )
            artia_parallax_update(reg.engine, Float(normalized.x), Float(normalized.y))
        }
        lastNormalizedOffset = ParallaxNormalizer.normalize(
            mouse: globalLocation,
            in: snapshot.first?.screen.frame ?? .zero
        )
    }

    // MARK: - NSEvent monitoring

    private func startMonitoringIfNeeded() {
        guard globalMonitor == nil else { return }
        // グローバルモニタ: 他アプリがアクティブでも届く (壁紙アプリは常に裏で動くため必須)。
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            guard let self else { return }
            let location = NSEvent.mouseLocation
            self.dispatchMouse(globalLocation: location)
            _ = event
        }
        // ローカルモニタ: 自プロセス内のマウス移動も拾う (エディタプレビューなど)。
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            guard let self else { return event }
            let location = NSEvent.mouseLocation
            self.dispatchMouse(globalLocation: location)
            return event
        }
    }

    private func stopMonitoring() {
        if let m = globalMonitor {
            NSEvent.removeMonitor(m)
            globalMonitor = nil
        }
        if let m = localMonitor {
            NSEvent.removeMonitor(m)
            localMonitor = nil
        }
    }
}
