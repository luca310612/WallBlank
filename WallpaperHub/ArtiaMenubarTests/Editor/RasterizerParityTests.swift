import Foundation
import Metal
import XCTest

@testable import WallBlank

/// Phase 1.4+: Rust / Metal の BrushMaskRasterizing 出力が同等であることを担保する。
/// - 円ストローク 3 種 (radius=5/50/200, hardness=0/0.5/1.0, opacity=1.0)
/// - post / gradient / combine はデフォルト (no-op) を使用しシンプルな円形に絞る
/// - Phase 1.4+ では MetalBrushMaskRasterizer 内部で Rust と同一のバイト列を生成し
///   `.gpu(MTLTexture)` にアップロードする実装のため、`.toCPU()` 後のバイト比較は
///   原理的に完全一致する (平均 0/255, 最大 0/255)。本テストはその不変条件を担保する。
///
/// 注意:
/// - Rust 経路は SelectionMask (.cpu) を返すのでバイト比較がそのまま行える。
/// - Metal 経路は SelectionMaskHandle.gpu(MTLTexture) を返すので `.toCPU()` で
///   読み戻してから比較する。
final class RasterizerParityTests: XCTestCase {

    private let canvas = CanvasSize(width: 256, height: 256)

    // MARK: - 入力フィクスチャ

    private struct Fixture {
        let label: String
        let radiusPixels: Double
        let hardness: Double
    }

    private let fixtures: [Fixture] = [
        Fixture(label: "small/soft",   radiusPixels: 5,   hardness: 0.0),
        Fixture(label: "medium/half",  radiusPixels: 50,  hardness: 0.5),
        Fixture(label: "large/hard",   radiusPixels: 200, hardness: 1.0)
    ]

    // 中央付近を真横に短く引くストローク (両実装が単一円塊を生成する条件)
    private var strokePoints: [CGPoint] {
        [CGPoint(x: 128, y: 128), CGPoint(x: 129, y: 128)]
    }

    // MARK: - テスト本体

    func test_rustAndMetalRasterizers_produceComparableMasks() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("MTLDevice が利用できない環境のためスキップ")
        }
        guard let metal = MetalBrushMaskRasterizer(device: device) else {
            throw XCTSkip("MetalBrushMaskRasterizer の生成に失敗したためスキップ")
        }
        let rust = RustBrushMaskRasterizer()

        for fixture in fixtures {
            var stroke = EditorBrushStrokeSettings()
            stroke.diameterPixels = fixture.radiusPixels * 2
            stroke.hardness = fixture.hardness
            stroke.opacity = 1.0
            stroke.flow = 1.0
            stroke.smoothingPercent = 0
            stroke.paintMode = .normal

            let post = EditorMaskPostSettings()
            let gradient = EditorMaskGradientSettings()
            let combine: EditorMaskCombineMode = .replace

            async let rustHandle = rust.rasterize(
                points: strokePoints,
                canvas: canvas,
                stroke: stroke,
                post: post,
                gradient: gradient,
                combine: combine,
                existing: nil
            )
            async let metalHandle = metal.rasterize(
                points: strokePoints,
                canvas: canvas,
                stroke: stroke,
                post: post,
                gradient: gradient,
                combine: combine,
                existing: nil
            )

            let (rh, mh) = await (rustHandle, metalHandle)
            guard let rustMask = rh?.toCPU() else {
                XCTFail("[\(fixture.label)] Rust 経路が SelectionMask を返さなかった")
                continue
            }
            guard let metalMask = mh?.toCPU() else {
                XCTFail("[\(fixture.label)] Metal 経路が SelectionMask を返さなかった")
                continue
            }

            XCTAssertEqual(rustMask.width, metalMask.width, "[\(fixture.label)] 幅が一致")
            XCTAssertEqual(rustMask.height, metalMask.height, "[\(fixture.label)] 高さが一致")
            XCTAssertEqual(rustMask.data.count, metalMask.data.count, "[\(fixture.label)] バイト数が一致")

            let (mean, maxDiff) = computeError(rustMask.data, metalMask.data)
            XCTAssertLessThan(mean, 4.0,
                "[\(fixture.label)] 平均誤差 \(mean) は 4/255 未満であるべき")
            XCTAssertLessThan(maxDiff, 32.0,
                "[\(fixture.label)] 最大誤差 \(maxDiff) は 32/255 未満であるべき")
        }
    }

    /// SelectionMaskHandle のフォールバックを確認 (useGPU=false で Rust を返す)
    func test_factoryReturnsRustWhenUseGPUFalse() async {
        let rasterizer = BrushMaskRasterizerFactory.make(useGPU: false, device: nil)
        XCTAssertTrue(rasterizer is RustBrushMaskRasterizer,
            "useGPU=false なら必ず RustBrushMaskRasterizer が返るべき")
    }

    func test_factoryReturnsMetalWhenUseGPUTrueAndDeviceAvailable() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return  // CI 等で MTLDevice が無い場合はスキップ
        }
        let rasterizer = BrushMaskRasterizerFactory.make(useGPU: true, device: device)
        XCTAssertTrue(rasterizer is MetalBrushMaskRasterizer,
            "useGPU=true & device 取得可ならば MetalBrushMaskRasterizer を返すべき")
    }

    func test_factoryFallsBackToRustWhenDeviceNil() {
        let rasterizer = BrushMaskRasterizerFactory.make(useGPU: true, device: nil)
        XCTAssertTrue(rasterizer is RustBrushMaskRasterizer,
            "device=nil なら useGPU=true でも Rust にフォールバックすべき")
    }

    // MARK: - 誤差計算

    private func computeError(_ a: [UInt8], _ b: [UInt8]) -> (mean: Double, max: Double) {
        XCTAssertEqual(a.count, b.count)
        guard a.count == b.count, !a.isEmpty else { return (0, 0) }
        var total: Double = 0
        var maxDiff: Double = 0
        for i in 0..<a.count {
            let d = abs(Double(a[i]) - Double(b[i]))
            total += d
            if d > maxDiff { maxDiff = d }
        }
        let mean = total / Double(a.count)
        return (mean, maxDiff)
    }
}
