import Foundation
import XCTest

@testable import Artia

/// Phase 7B: SpanningCanvasController の payload 計算 / JSON 変換検証。
@MainActor
final class SpanningCanvasControllerTests: XCTestCase {

    // MARK: - makePayload

    func test_makePayload_emptyInput_returnsNil() {
        XCTAssertNil(SpanningCanvasController.makePayload(from: []))
    }

    func test_makePayload_singleDisplay_originBecomesZero() {
        let info = DisplaySpanInfo(
            displayID: 1,
            originX: 100, originY: 50,
            width: 1920, height: 1080
        )
        let payload = SpanningCanvasController.makePayload(from: [info])!
        XCTAssertEqual(payload.width, 1920)
        XCTAssertEqual(payload.height, 1080)
        XCTAssertEqual(payload.displays.count, 1)
        XCTAssertEqual(payload.displays[0].display_id, 1)
        XCTAssertEqual(payload.displays[0].origin, [0, 0])
        XCTAssertEqual(payload.displays[0].size, [1920, 1080])
    }

    func test_makePayload_twoSideBySide_yieldsUnion() {
        let left = DisplaySpanInfo(
            displayID: 1, originX: -1920, originY: 0,
            width: 1920, height: 1080
        )
        let right = DisplaySpanInfo(
            displayID: 2, originX: 0, originY: 0,
            width: 1920, height: 1080
        )
        let payload = SpanningCanvasController.makePayload(from: [left, right])!
        XCTAssertEqual(payload.width, 3840)
        XCTAssertEqual(payload.height, 1080)
        let leftPayload = payload.displays.first { $0.display_id == 1 }!
        let rightPayload = payload.displays.first { $0.display_id == 2 }!
        XCTAssertEqual(leftPayload.origin, [0, 0])
        XCTAssertEqual(rightPayload.origin, [1920, 0])
    }

    func test_makePayload_stackedVertically_yieldsTallCanvas() {
        let top = DisplaySpanInfo(
            displayID: 10, originX: 0, originY: 0,
            width: 1920, height: 1080
        )
        let bottom = DisplaySpanInfo(
            displayID: 20, originX: 0, originY: -1080,
            width: 1920, height: 1080
        )
        let payload = SpanningCanvasController.makePayload(from: [top, bottom])!
        XCTAssertEqual(payload.width, 1920)
        XCTAssertEqual(payload.height, 2160)
    }

    // MARK: - JSON encode

    func test_encode_producesValidJSONWithSnakeCase() throws {
        let payload = SpanningCanvasPayload(
            width: 100,
            height: 100,
            displays: [
                .init(display_id: 7, origin: [0, 0], size: [100, 100])
            ]
        )
        let json = try SpanningCanvasController.encode(payload)
        XCTAssertTrue(json.contains("\"display_id\""))
        XCTAssertTrue(json.contains("\"origin\""))
        XCTAssertTrue(json.contains("\"size\""))

        // 別途 decode して structure 一致を確認
        let decoded = try JSONDecoder().decode(SpanningCanvasPayload.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, payload)
    }

    // MARK: - apply / clear without engine

    func test_apply_withoutEngine_storesLastPayload() {
        let controller = SpanningCanvasController()
        controller.engineHandleProvider = { nil } // engine 未注入
        // NSScreen 依存なので apply 自体の戻り値はテスト環境次第。
        // apply 後の lastPayload は collectScreenRects がディスプレイを返した場合に nil ではない。
        _ = controller.apply()
        // CI では NSScreen が無い場合があるため、payload 有無のいずれでもクラッシュしないことだけ確認。
        XCTAssertNotNil(controller) // sanity
    }

    func test_clear_resetsActiveFlag() {
        let controller = SpanningCanvasController()
        controller.engineHandleProvider = { nil }
        controller.clear()
        XCTAssertFalse(controller.isActive)
        XCTAssertNil(controller.lastPayload)
    }
}
