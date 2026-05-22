import Foundation
import XCTest

@testable import Artia

/// Phase 4C: PuppetWarpBridge の Codable / FFI ラウンドトリップ検証。
final class PuppetWarpBridgeTests: XCTestCase {

    // MARK: - Helpers

    private func makeDescriptor() -> PuppetWarpDescriptor {
        PuppetWarpDescriptor(
            sourceLayerId: "test-layer",
            grid: [4, 4],
            layerSize: [256, 128],
            handles: [
                .anchor(at: [0, 0]),
                .anchor(at: [256, 128]),
                .pin(from: [128, 64], to: [140, 64])
            ],
            idwPower: 2.0,
            idwEpsilon: 1e-3,
            tpsLambda: 0.0,
            autoAnchorCorners: true
        )
    }

    // MARK: - Codable round-trip

    func test_descriptor_jsonRoundTrip_throughRustValidator() throws {
        let descriptor = makeDescriptor()
        guard let normalized = PuppetWarpBridge.validateDescriptor(descriptor) else {
            XCTFail("Rust 側の validate が nil を返した — Codable 表現がずれている可能性")
            return
        }
        let data = Data(normalized.utf8)
        let decoded = try JSONDecoder().decode(PuppetWarpDescriptor.self, from: data)
        XCTAssertEqual(decoded, descriptor, "Rust ラウンドトリップで descriptor が同値であるべき")
    }

    func test_handleKind_pureSwiftRoundTrip() throws {
        for value in [PuppetWarpHandleKind.anchor, .pin] {
            let data = try JSONEncoder().encode(value)
            let back = try JSONDecoder().decode(PuppetWarpHandleKind.self, from: data)
            XCTAssertEqual(back, value)
        }
    }

    func test_handleDescriptor_pureSwiftRoundTrip() throws {
        let cases: [PuppetWarpHandleDescriptor] = [
            .anchor(at: [0, 0]),
            .pin(from: [10, 20], to: [30, 40])
        ]
        for value in cases {
            let data = try JSONEncoder().encode(value)
            let back = try JSONDecoder().decode(PuppetWarpHandleDescriptor.self, from: data)
            XCTAssertEqual(back, value)
        }
    }

    func test_paramsCodable_handlesNilFields() throws {
        let params = PuppetWarpParams(handles: nil, idwPower: 3.0, idwEpsilon: nil)
        let data = try JSONEncoder().encode(params)
        let back = try JSONDecoder().decode(PuppetWarpParams.self, from: data)
        XCTAssertEqual(back, params)
    }

    // MARK: - FFI engine round-trip

    func test_engineRoundTrip_createUpdateDestroy() throws {
        guard let engine = RustCore.createWgpuEngine(width: 256, height: 256) else {
            throw XCTSkip("Metal adapter 未取得のため engine round-trip をスキップ")
        }
        defer { RustCore.destroyWgpuEngine(engine) }

        let descriptor = makeDescriptor()
        let id = PuppetWarpBridge.create(engine: engine, descriptor: descriptor)
        XCTAssertGreaterThan(id, 0, "PuppetWarp 作成で 1 以上の ID が返るべき")

        let countAfterCreate = PuppetWarpBridge.count(engine: engine)
        XCTAssertEqual(countAfterCreate, 1)

        let params = PuppetWarpParams(
            handles: [.pin(from: [128, 64], to: [150, 70])],
            idwPower: nil,
            idwEpsilon: nil
        )
        let updateError = PuppetWarpBridge.update(engine: engine, id: id, params: params)
        XCTAssertNil(updateError, "存在 ID への update は nil を返すべき (\(updateError ?? ""))")

        let destroyed = PuppetWarpBridge.destroy(engine: engine, id: id)
        XCTAssertTrue(destroyed)
        XCTAssertEqual(PuppetWarpBridge.count(engine: engine), 0)
    }

    func test_engineUpdate_returnsErrorForUnknownId() throws {
        guard let engine = RustCore.createWgpuEngine(width: 64, height: 64) else {
            throw XCTSkip("Metal adapter 未取得のためスキップ")
        }
        defer { RustCore.destroyWgpuEngine(engine) }

        let params = PuppetWarpParams(
            handles: [.anchor(at: [0, 0])],
            idwPower: nil,
            idwEpsilon: nil,
            tpsLambda: nil,
            autoAnchorCorners: nil
        )
        let error = PuppetWarpBridge.update(engine: engine, id: 999_999, params: params)
        XCTAssertNotNil(error, "未登録 ID への update はエラーメッセージを返すべき")
    }

    // MARK: - 座標系契約 (Phase 4C+ 追加)

    func test_handleDescriptor_normalizedScalesByCanvasSize() {
        let raw = PuppetWarpHandleDescriptor.pin(from: [128, 64], to: [192, 64])
        let normalized = raw.normalized(canvasSize: CGSize(width: 256, height: 128))
        XCTAssertEqual(normalized.source[0], 0.5, accuracy: 1e-4)
        XCTAssertEqual(normalized.source[1], 0.5, accuracy: 1e-4)
        XCTAssertEqual(normalized.target[0], 0.75, accuracy: 1e-4)
        XCTAssertEqual(normalized.target[1], 0.5, accuracy: 1e-4)
        XCTAssertEqual(normalized.kind, .pin)
    }

    func test_handleDescriptor_normalizedClampsZeroSize() {
        // 0 や負の canvas size でも 0 除算しない
        let raw = PuppetWarpHandleDescriptor.anchor(at: [10, 20])
        let normalized = raw.normalized(canvasSize: CGSize(width: 0, height: -5))
        XCTAssertEqual(normalized.source[0], 10.0, accuracy: 1e-4)
        XCTAssertEqual(normalized.source[1], 20.0, accuracy: 1e-4)
    }

    // MARK: - パーティクル演出フック (Phase 4C+)

    func test_strokeHook_invokesBurstHandlerOnBeginAndEnd() {
        var received: [PuppetWarpParticleBurst] = []
        PuppetWarpEffectHooks._burstHandler = { burst in received.append(burst) }
        defer { PuppetWarpEffectHooks._burstHandler = nil }

        PuppetWarpEffectHooks.notifyStrokeBegan(at: [0.8, 0.5])
        PuppetWarpEffectHooks.notifyStrokeEnded(at: [0.7, 0.5])

        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0].position[0], 0.8, accuracy: 1e-4)
        XCTAssertGreaterThan(received[0].count, 0)
        XCTAssertEqual(received[1].position[0], 0.7, accuracy: 1e-4)
    }

    func test_strokeHook_noopWhenHandlerNotInstalled() {
        // 既に nil の状態で呼び出してもクラッシュしない
        PuppetWarpEffectHooks._burstHandler = nil
        PuppetWarpEffectHooks.notifyStrokeBegan(at: [0.5, 0.5])
        PuppetWarpEffectHooks.notifyStrokeEnded(at: [0.5, 0.5])
    }

    // MARK: - バグ再現テスト: 右側 pin で左側が translate しない

    func test_rightSidePin_leavesLeftCornersIntact_viaRustEngine() throws {
        guard let engine = RustCore.createWgpuEngine(width: 256, height: 256) else {
            throw XCTSkip("Metal adapter 未取得のためスキップ")
        }
        defer { RustCore.destroyWgpuEngine(engine) }

        // 正規化座標で右側 (顔) を pin、auto_anchor_corners=true で 4 隅固定
        let descriptor = PuppetWarpDescriptor(
            sourceLayerId: "regression-layer",
            grid: [8, 8],
            layerSize: [1.0, 1.0],
            handles: [
                .pin(from: [0.85, 0.5], to: [0.95, 0.5])
            ],
            idwPower: 2.0,
            idwEpsilon: 1e-3,
            tpsLambda: 0.0,
            autoAnchorCorners: true
        )
        let id = PuppetWarpBridge.create(engine: engine, descriptor: descriptor)
        XCTAssertGreaterThan(id, 0, "auto_anchor_corners + 右側 pin で生成できるべき")
        defer { PuppetWarpBridge.destroy(engine: engine, id: id) }
        // Rust 側内部メッシュは FFI で直接観測できないため、ここでは生成成功と
        // descriptor JSON 往復のみ確認する。数学的な左右分離は Rust 単体テスト
        // (warp::tests::right_side_pin_with_auto_anchor_leaves_left_intact) で担保。
        XCTAssertEqual(PuppetWarpBridge.count(engine: engine), 1)
    }
}
