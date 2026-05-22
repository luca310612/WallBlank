import AppKit
import CoreGraphics
import Foundation
import XCTest

@testable import WallBlank

/// Phase 4B: TextLayerRenderer の出力検証。
///
/// テスト方針:
/// - フォント未指定時にシステムフォントへフォールバックして CGImage が得られること。
/// - 同じ descriptor + canvasSize で 2 回呼んだら同じ RGBA バイト列になる (決定性)。
/// - Codable round-trip。
final class TextLayerRendererTests: XCTestCase {

    private var sampleDescriptor: TextLayerDescriptor {
        TextLayerDescriptor(
            text: "WallBlank",
            fontName: nil, // システムフォント
            fontSize: 64,
            color: [1, 1, 1, 1],
            position: [40, 40],
            alignment: .center
        )
    }

    func test_renderImage_returnsNonNilForBasicDescriptor() {
        let img = TextLayerRenderer.renderImage(
            descriptor: sampleDescriptor,
            canvasSize: CGSize(width: 256, height: 128)
        )
        XCTAssertNotNil(img, "system font fallback で CGImage が得られるはず")
        XCTAssertEqual(img?.width, 256)
        XCTAssertEqual(img?.height, 128)
    }

    func test_renderRGBA_returnsExpectedByteCount() {
        guard let result = TextLayerRenderer.renderRGBA(
            descriptor: sampleDescriptor,
            canvasSize: CGSize(width: 64, height: 32)
        ) else {
            XCTFail("RGBA レンダが nil")
            return
        }
        XCTAssertEqual(result.1, 64)
        XCTAssertEqual(result.2, 32)
        XCTAssertEqual(result.0.count, 64 * 32 * 4)
    }

    func test_renderRGBA_isDeterministicForSameInput() {
        let canvas = CGSize(width: 96, height: 48)
        guard let a = TextLayerRenderer.renderRGBA(descriptor: sampleDescriptor, canvasSize: canvas),
              let b = TextLayerRenderer.renderRGBA(descriptor: sampleDescriptor, canvasSize: canvas) else {
            XCTFail("RGBA レンダが nil")
            return
        }
        XCTAssertEqual(a.0, b.0, "同一入力で同一バイト列になるべき (決定論的)")
    }

    func test_renderImage_handlesEmptyText() {
        var d = sampleDescriptor
        d.text = ""
        let img = TextLayerRenderer.renderImage(
            descriptor: d,
            canvasSize: CGSize(width: 32, height: 32)
        )
        // 空文字でも CGImage 自体は得られる (透明な 32x32)。
        XCTAssertNotNil(img)
    }

    func test_renderImage_invalidCanvasReturnsNil() {
        let img = TextLayerRenderer.renderImage(
            descriptor: sampleDescriptor,
            canvasSize: CGSize(width: 0, height: 0)
        )
        XCTAssertNil(img)
    }

    func test_descriptor_jsonRoundTrip() throws {
        let d = TextLayerDescriptor(
            text: "Hello",
            fontName: "Inter-Regular",
            fontSize: 32,
            color: [0.5, 0.25, 0.75, 1],
            position: [10, 20],
            alignment: .trailing
        )
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(TextLayerDescriptor.self, from: data)
        XCTAssertEqual(back, d)
    }

    func test_alignmentEnum_roundTripsAllCases() throws {
        for value in [TextLayerAlignment.leading, .center, .trailing] {
            let data = try JSONEncoder().encode(value)
            let back = try JSONDecoder().decode(TextLayerAlignment.self, from: data)
            XCTAssertEqual(back, value)
        }
    }
}
