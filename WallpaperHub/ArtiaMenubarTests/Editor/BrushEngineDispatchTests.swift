import Foundation
import XCTest

@testable import Artia

/// Phase 1.3+: PenToolKind ↔ BrushEngineID マッピング、各エンジンの圧力反応、
/// および BrushEngineRegistry のフォールバック挙動を検証する。
@MainActor
final class BrushEngineDispatchTests: XCTestCase {

    // MARK: - PenToolKind → BrushEngineID マッピング

    func test_penToolKindMapping_freeformAndMagneticPen_mapToCircle() {
        XCTAssertEqual(PenToolKind.freeform.brushEngineID, .circle)
        XCTAssertEqual(PenToolKind.magneticPen.brushEngineID, .circle)
    }

    func test_penToolKindMapping_vectorPathTools_returnNil() {
        let vectorCases: [PenToolKind] = [
            .standard, .curvature, .polygonal,
            .pathSelect, .directSelect,
            .addAnchor, .deleteAnchor, .convertPoint
        ]
        for kind in vectorCases {
            XCTAssertNil(kind.brushEngineID,
                "ベクター系 \(kind.rawValue) は BrushEngine ではなくパス編集経路に流すべき")
        }
    }

    func test_isFreeformBrushLikeEquivalentToBrushEngineIDPresence() {
        // Phase 1.3+: 既存の isFreeformBrushLike と新マッピング (brushEngineID != nil) が
        // 全 case で等価であることを担保する (将来 freeform 派生を増やしても両者をズラさない)。
        for kind in PenToolKind.allCases {
            XCTAssertEqual(kind.isFreeformBrushLike, kind.brushEngineID != nil,
                "\(kind.rawValue): isFreeformBrushLike と brushEngineID 有無が一致すべき")
        }
    }

    // MARK: - BrushEngineRegistry

    func test_registry_resolvesAllBuiltInEngines() {
        let registry = BrushEngineRegistry.shared
        for id in BrushEngineID.allCases {
            XCTAssertNotNil(registry.engine(for: id),
                "組み込みエンジン \(id.rawValue) が registry から取得できるべき")
        }
    }

    func test_registry_engineOrFallbackReturnsCircleForUnregisteredID() {
        // 全組み込み登録済みなので、登録済み ID の照会は必ず非 nil。
        // フォールバック経路は CircleBrushEngine が返ることを supportsTilt の値で識別する。
        let circle = BrushEngineRegistry.shared.engineOrFallback(for: .circle)
        XCTAssertEqual(circle.id, .circle)
    }

    // MARK: - 各エンジンの圧力反応マッピング

    func test_circleBrush_mapsPressureToRadius() {
        let engine = CircleBrushEngine()
        let strong = engine.pressureResponse(for: BrushInputSample(position: .zero, pressure: 1.0))
        let weak = engine.pressureResponse(for: BrushInputSample(position: .zero, pressure: 0.3))
        XCTAssertGreaterThan(strong.radiusMultiplier, weak.radiusMultiplier,
            "CircleBrush は強圧で半径倍率が大きくなるべき")
        // 他の経路は無補正のままであるべき
        XCTAssertEqual(strong.flowMultiplier, 1.0)
        XCTAssertEqual(strong.densityMultiplier, 1.0)
        XCTAssertEqual(strong.strengthMultiplier, 1.0)
        XCTAssertEqual(strong.opacityMultiplier, 1.0)
    }

    func test_airBrush_mapsPressureToFlow() {
        let engine = AirBrushEngine()
        let r = engine.pressureResponse(for: BrushInputSample(position: .zero, pressure: 0.5))
        XCTAssertEqual(r.flowMultiplier, 0.5, accuracy: 1e-6,
            "Air は圧力をフロー倍率に直接反映するべき")
        XCTAssertEqual(r.radiusMultiplier, 1.0)
    }

    func test_textureBrush_mapsPressureToDensity_withFloor() {
        let engine = TextureBrushEngine()
        let veryWeak = engine.pressureResponse(for: BrushInputSample(position: .zero, pressure: 0.0))
        XCTAssertGreaterThanOrEqual(veryWeak.densityMultiplier, 0.3,
            "Texture は弱圧でも 0.3 を下限としてクランプ (粒の存在感を担保)")
    }

    func test_smudgeBrush_mapsPressureToStrength() {
        let engine = SmudgeBrushEngine()
        let weak = engine.pressureResponse(for: BrushInputSample(position: .zero, pressure: 0.0))
        let strong = engine.pressureResponse(for: BrushInputSample(position: .zero, pressure: 1.0))
        XCTAssertGreaterThan(strong.strengthMultiplier, weak.strengthMultiplier)
        XCTAssertGreaterThanOrEqual(weak.strengthMultiplier, 0.15)
    }

    func test_eraserBrush_mapsPressureToOpacity() {
        let engine = EraserBrushEngine()
        let r = engine.pressureResponse(for: BrushInputSample(position: .zero, pressure: 0.7))
        XCTAssertEqual(r.opacityMultiplier, 0.7, accuracy: 1e-6,
            "Eraser は圧力を不透明度倍率に直接反映するべき")
    }

    // MARK: - ストローク dispatch (engine.continueStroke)

    func test_circleBrush_continueStrokeAccumulatesStampPoints() {
        let engine = CircleBrushEngine()
        var ctx = BrushStrokeContext(
            stroke: EditorBrushStrokeSettings(),
            canvas: CGSize(width: 1000, height: 1000)
        )
        let begin = BrushInputSample(position: CGPoint(x: 0, y: 0))
        _ = engine.beginStroke(context: &ctx, sample: begin)
        XCTAssertEqual(ctx.stampPoints.count, 1)

        // 距離を稼いでスタンプが複数生成されることを確認 (radius=20 → 2*20*0.1=4pt 間隔)
        let next = BrushInputSample(position: CGPoint(x: 100, y: 0))
        let stamps = engine.continueStroke(context: &ctx, sample: next)
        XCTAssertGreaterThan(stamps.count, 1,
            "100pt 移動でスタンプ間隔 spacing 単位の点が複数生成されるべき")
        XCTAssertGreaterThan(ctx.stampPoints.count, 1)
    }
}
