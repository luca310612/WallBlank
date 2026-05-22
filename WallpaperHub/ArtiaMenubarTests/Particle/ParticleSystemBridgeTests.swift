import Foundation
import XCTest

@testable import WallBlank

/// Phase 4A: ParticleSystemBridge の Codable / FFI ラウンドトリップ検証。
///
/// テスト方針:
/// - JSON ラウンドトリップは「Swift → JSON → Rust(serde) → JSON → Swift」の経路を
///   `ParticleSystemBridge.validateDescriptor(...)` で確認する。Engine を介さないので
///   GPU セットアップに依存しない。
/// - create/update/destroy は実 `WgpuEngine` (Metal バックエンド) を `RustCore` 経由で立ち上げて
///   ID 発行 → 部分更新 → 破棄 の一連のラウンドトリップを確認する。
///   GPU 初期化が許可されない CI 環境では engine 作成が nil になりテストをスキップする。
final class ParticleSystemBridgeTests: XCTestCase {

    // MARK: - Helpers

    /// テスト用の最小 descriptor。
    private func makeDescriptor() -> ParticleSystemDescriptor {
        ParticleSystemDescriptor(
            capacity: 256,
            seed: 0xDEAD_BEEF,
            emitter: ParticleEmitterDescriptor(
                origin: [0, 0],
                spawnRate: 5,
                burst: 0,
                shape: .circle(radius: 10)
            ),
            initializers: [
                .lifetimeRange(min: 1.0, max: 2.0),
                .randomDirection(speedMin: 5, speedMax: 10),
                .sizeRange(min: 1, max: 4),
                .colorRamp(color: [1, 1, 1, 1])
            ],
            operators: [
                .gravity(acceleration: [0, -9.8]),
                .drag(coefficient: 0.1),
                .killBeyondBounds(min: [-100, -100], max: [100, 100])
            ]
        )
    }

    // MARK: - Codable round-trip

    /// Swift JSON エンコード→Rust serde デコード→再エンコード→Swift デコードのラウンドトリップ検証。
    func test_descriptor_jsonRoundTrip_throughRustValidator() throws {
        let descriptor = makeDescriptor()
        guard let normalized = ParticleSystemBridge.validateDescriptor(descriptor) else {
            XCTFail("Rust 側の validate が nil を返した — Codable 表現がずれている可能性")
            return
        }
        // Rust の出力 JSON を再度 Swift 側で decode できることを確認する。
        let data = Data(normalized.utf8)
        let decoded = try JSONDecoder().decode(ParticleSystemDescriptor.self, from: data)
        XCTAssertEqual(decoded, descriptor, "Rust ラウンドトリップで descriptor が同値であるべき")
    }

    /// Initializer enum 各バリアントが pure-Swift round-trip できることを確認する。
    func test_initializerDescriptors_pureSwiftRoundTrip() throws {
        let cases: [ParticleInitializerDescriptor] = [
            .lifetimeRange(min: 0.5, max: 1.5),
            .velocityCone(direction: [0, -1], angle: 0.2, speedMin: 5, speedMax: 20),
            .sizeRange(min: 1, max: 3),
            .colorRamp(color: [1, 0.5, 0.25, 1]),
            .randomDirection(speedMin: 1, speedMax: 4)
        ]
        for value in cases {
            let data = try JSONEncoder().encode(value)
            let back = try JSONDecoder().decode(ParticleInitializerDescriptor.self, from: data)
            XCTAssertEqual(back, value)
        }
    }

    /// Operator enum 各バリアントが pure-Swift round-trip できることを確認する。
    func test_operatorDescriptors_pureSwiftRoundTrip() throws {
        let cases: [ParticleOperatorDescriptor] = [
            .gravity(acceleration: [0, -1]),
            .drag(coefficient: 0.2),
            .sizeOverLife(start: 1, end: 0),
            .colorOverLife(start: [1, 1, 1, 1], end: [1, 1, 1, 0]),
            .killBeyondBounds(min: [0, 0], max: [10, 10])
        ]
        for value in cases {
            let data = try JSONEncoder().encode(value)
            let back = try JSONDecoder().decode(ParticleOperatorDescriptor.self, from: data)
            XCTAssertEqual(back, value)
        }
    }

    /// `EmitterShape` の box / circle / point すべて round-trip すること。
    func test_emitterShape_allVariantsRoundTrip() throws {
        let cases: [ParticleEmitterShape] = [
            .point,
            .box(width: 100, height: 50),
            .circle(radius: 25)
        ]
        for value in cases {
            let data = try JSONEncoder().encode(value)
            let back = try JSONDecoder().decode(ParticleEmitterShape.self, from: data)
            XCTAssertEqual(back, value)
        }
    }

    // MARK: - FFI engine round-trip

    /// 実 WgpuEngine 経由で create → update → destroy が通ることを確認する。
    /// Metal アダプタが取れない環境では engine が nil となるため early-return でスキップする。
    func test_engineRoundTrip_createUpdateDestroy() throws {
        guard let engine = RustCore.createWgpuEngine(width: 256, height: 256) else {
            // GPU 不在の CI などでは PASS 扱いにする (FFI 単体は他テストで検証済み)。
            throw XCTSkip("Metal adapter 未取得のため engine round-trip をスキップ")
        }
        defer { RustCore.destroyWgpuEngine(engine) }

        let descriptor = makeDescriptor()
        let id = ParticleSystemBridge.create(engine: engine, descriptor: descriptor)
        XCTAssertGreaterThan(id, 0, "ParticleSystem 作成で 1 以上の ID が返るべき")

        let countAfterCreate = ParticleSystemBridge.systemCount(engine: engine)
        XCTAssertEqual(countAfterCreate, 1)

        let params = ParticleSystemParams(
            emitter: nil,
            initializers: nil,
            operators: [.drag(coefficient: 0.5)]
        )
        let updateError = ParticleSystemBridge.update(engine: engine, id: id, params: params)
        XCTAssertNil(updateError, "存在する ID への update は nil を返すべき (\(updateError ?? ""))")

        let destroyed = ParticleSystemBridge.destroy(engine: engine, id: id)
        XCTAssertTrue(destroyed)

        let countAfterDestroy = ParticleSystemBridge.systemCount(engine: engine)
        XCTAssertEqual(countAfterDestroy, 0)
    }

    /// 不正な ID への update は Rust 側からエラー JSON を返すこと。
    func test_engineUpdate_returnsErrorForUnknownId() throws {
        guard let engine = RustCore.createWgpuEngine(width: 64, height: 64) else {
            throw XCTSkip("Metal adapter 未取得のためスキップ")
        }
        defer { RustCore.destroyWgpuEngine(engine) }

        let params = ParticleSystemParams(
            emitter: nil,
            initializers: nil,
            operators: [.gravity(acceleration: [0, -1])]
        )
        let error = ParticleSystemBridge.update(engine: engine, id: 999_999, params: params)
        XCTAssertNotNil(error, "未登録 ID への update はエラーメッセージを返すべき")
    }
}
