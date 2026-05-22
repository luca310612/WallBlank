import Foundation
import AppKit

/// Phase 7B: スパニング壁紙コントローラ。
/// DisplayManager から NSScreen 群を取り出して仮想キャンバスを組み立て、
/// JSON で Rust エンジン (artia_spanning_set) へ渡す。
///
/// Why: ディスプレイレイアウトは macOS 側の SoT (NSScreen) なので、
///      Rust 側の `SpanningCanvas::from_screen_rects` ヘルパに渡しやすい
///      tuple 配列形式へ変換する責務を Swift に集約する。
struct DisplaySpanInfo: Equatable {
    let displayID: UInt32
    let originX: Int32
    let originY: Int32
    let width: UInt32
    let height: UInt32
}

/// Rust 側 `SpanningCanvas` と同じスキーマ (snake_case JSON)
struct SpanningCanvasPayload: Codable, Equatable {
    let width: UInt32
    let height: UInt32
    let displays: [DisplayPayload]

    struct DisplayPayload: Codable, Equatable {
        let display_id: UInt32
        let origin: [Int32]   // 2 要素 [x, y] (tuple → JSON 配列)
        let size: [UInt32]    // 2 要素 [w, h]
    }
}

/// 設定 + 入力 → JSON へ変換する純粋関数群を持つ controller。
@MainActor
final class SpanningCanvasController: ObservableObject {

    static let shared = SpanningCanvasController()

    @Published private(set) var lastPayload: SpanningCanvasPayload?
    @Published private(set) var isActive: Bool = false

    /// FFI を呼ぶための engine handle 注入 (テスト時は nil でも OK)
    var engineHandleProvider: (() -> UnsafeMutableRawPointer?)?

    init() {}

    /// macOS の NSScreen から `DisplaySpanInfo` 配列を構築する。
    /// Why: NSScreen.frame は y 軸下方向だが、SpanningCanvas は (min_x, min_y) を 0,0 に正規化するため
    ///      そのまま座標を渡せばよい (Rust 側で min を取って origin を平行移動する)。
    func collectScreenRects() -> [DisplaySpanInfo] {
        return NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else {
                return nil
            }
            let f = screen.frame
            return DisplaySpanInfo(
                displayID: id,
                originX: Int32(f.minX),
                originY: Int32(f.minY),
                width: UInt32(max(f.width, 1)),
                height: UInt32(max(f.height, 1))
            )
        }
    }

    /// `DisplaySpanInfo` 配列から JSON payload を組み立てる純粋関数。
    /// Rust 側の `SpanningCanvas::from_screen_rects` と同じ正規化を Swift 側でも複製。
    static func makePayload(from infos: [DisplaySpanInfo]) -> SpanningCanvasPayload? {
        guard !infos.isEmpty else { return nil }
        let minX = infos.map { $0.originX }.min() ?? 0
        let minY = infos.map { $0.originY }.min() ?? 0
        let maxX = infos.map { $0.originX + Int32($0.width) }.max() ?? 0
        let maxY = infos.map { $0.originY + Int32($0.height) }.max() ?? 0
        let width = UInt32(max(maxX - minX, 0))
        let height = UInt32(max(maxY - minY, 0))
        guard width > 0, height > 0 else { return nil }
        let displays = infos.map { info in
            SpanningCanvasPayload.DisplayPayload(
                display_id: info.displayID,
                origin: [info.originX - minX, info.originY - minY],
                size: [info.width, info.height]
            )
        }
        return SpanningCanvasPayload(width: width, height: height, displays: displays)
    }

    /// JSON 文字列にエンコード (FFI 用)
    static func encode(_ payload: SpanningCanvasPayload) throws -> String {
        let data = try JSONEncoder().encode(payload)
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - 適用

    /// 現在の NSScreen レイアウトから payload を組み立て、Rust エンジンへ送る。
    /// 失敗時は false を返す。エンジンが未注入なら no-op。
    @discardableResult
    func apply() -> Bool {
        let rects = collectScreenRects()
        guard let payload = Self.makePayload(from: rects) else {
            lastPayload = nil
            isActive = false
            return false
        }
        lastPayload = payload
        guard let engine = engineHandleProvider?() else {
            // Engine 未注入時は計算結果のみ保持 (テスト/Settings UI のプレビュー用)
            return true
        }
        do {
            let json = try Self.encode(payload)
            let result = json.withCString { ptr -> Int32 in
                artia_spanning_set(engine, ptr)
            }
            isActive = (result == 0)
            return result == 0
        } catch {
            return false
        }
    }

    /// Rust 側のスパニングをクリアし、ディスプレイ独立モードへ戻す。
    func clear() {
        lastPayload = nil
        isActive = false
        guard let engine = engineHandleProvider?() else { return }
        _ = artia_spanning_clear(engine)
    }
}
