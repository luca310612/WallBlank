import Foundation
import Metal
import MetalKit
import XCTest

@testable import Artia

/// Phase 1.2+ シェーダ回帰テスト。
/// - Composite.metal の `kShaderType` Function Constant 化により 4 種の PSO バリアントが
///   正しくビルド/特殊化できることを担保する。
/// - 同一入力でレンダリングしたフレーム同士は完全一致 (PSNR=∞、ここでは ≥50dB を満たす)。
/// - 異なる shaderType 同士は出力が同一でないこと (procedural と transparent で内容が違う)
///   をネガティブ側で確認する。
///
/// リファレンス PNG をバンドル同梱せずに回帰を担保する設計：
/// - 4 種ベース (transparent / gradientWave / plasma / noiseFlow) を `MTLTexture` で
///   2 回レンダリングし、PSNR ≥ 50dB をアサート。
/// - シェーダの非自明な分岐 (Function Constant の特殊化) が壊れていれば
///   そもそも fragment function の生成/PSO 作成で失敗する。
final class ShaderRegressionTests: XCTestCase {

    private let renderSize = CGSize(width: 64, height: 64)

    private struct RenderTarget {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let library: MTLLibrary
        let vertexFunction: MTLFunction
        let vertexBuffer: MTLBuffer
    }

    // MARK: - PSO 生成テスト

    func test_allShaderTypePSOsBuildSuccessfully() throws {
        let target = try makeRenderTarget()
        for shaderType in 0...3 {
            let pso = try buildPipeline(target: target, shaderType: Int32(shaderType))
            XCTAssertNotNil(pso, "shaderType=\(shaderType) の PSO が生成できるべき")
        }
    }

    // MARK: - 決定性 (同入力 → 同出力)

    func test_transparentShaderIsDeterministicAcrossRenders() throws {
        let target = try makeRenderTarget()
        let pso = try buildPipeline(target: target, shaderType: 0)

        let frameA = try render(target: target, pso: pso, time: 0.5)
        let frameB = try render(target: target, pso: pso, time: 0.5)

        let psnr = computePSNR(frameA, frameB)
        XCTAssertGreaterThanOrEqual(psnr, 50.0,
            "決定的レンダリングは PSNR ≥ 50dB を満たすべき (実測=\(psnr))")
    }

    func test_proceduralShadersAreDeterministicAcrossRenders() throws {
        let target = try makeRenderTarget()
        // 1=gradient, 2=plasma, 3=noiseFlow
        for shaderType: Int32 in [1, 2, 3] {
            let pso = try buildPipeline(target: target, shaderType: shaderType)
            let frameA = try render(target: target, pso: pso, time: 0.25)
            let frameB = try render(target: target, pso: pso, time: 0.25)
            let psnr = computePSNR(frameA, frameB)
            XCTAssertGreaterThanOrEqual(psnr, 50.0,
                "shaderType=\(shaderType) の決定性 PSNR が低い (実測=\(psnr))")
        }
    }

    // MARK: - shaderType ごとに出力が違うこと

    func test_differentShaderTypesProduceDifferentOutputs() throws {
        let target = try makeRenderTarget()
        let psoTransparent = try buildPipeline(target: target, shaderType: 0)
        let psoGradient = try buildPipeline(target: target, shaderType: 1)

        let frameTransparent = try render(target: target, pso: psoTransparent, time: 0.0, hasBackground: 0)
        let frameGradient = try render(target: target, pso: psoGradient, time: 0.0, hasBackground: 0)

        // 透過 (alpha=0 出力) と gradientWave (RGB 強い) では明らかに違う。
        // PSNR が極端に高いと「同じ画像」を意味するため、ここでは < 50dB を期待。
        let psnr = computePSNR(frameTransparent, frameGradient)
        XCTAssertLessThan(psnr, 50.0,
            "shaderType=0 (transparent) と shaderType=1 (gradient) は別画像であるべき (実測=\(psnr))")
    }

    // MARK: - ヘルパ

    private func makeRenderTarget() throws -> RenderTarget {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("MTLDevice が利用できない環境のためスキップ")
        }
        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("MTLCommandQueue を確保できないためスキップ")
        }
        // 本体の default library をテストから参照する。CI ホストアプリ経由で
        // Resources/Effects/*.metal がバンドルされていることを前提とする。
        guard let library = device.makeDefaultLibrary() else {
            throw XCTSkip("default Metal library が読み込めないためスキップ")
        }
        guard let vertexFunction = library.makeFunction(name: "vertexShader") else {
            throw XCTSkip("vertexShader 関数が見つからないためスキップ")
        }

        // フルスクリーン三角形ストリップ用の頂点 (Renderer.swift と同じレイアウト)
        var vertices: [SIMD4<Float>] = [
            SIMD4<Float>(-1, -1, 0, 1),
            SIMD4<Float>( 1, -1, 0, 1),
            SIMD4<Float>(-1,  1, 0, 1),
            SIMD4<Float>( 1,  1, 0, 1)
        ]
        let byteLength = MemoryLayout<SIMD4<Float>>.stride * vertices.count
        guard let vertexBuffer = device.makeBuffer(bytes: &vertices, length: byteLength, options: []) else {
            throw XCTSkip("頂点バッファを確保できないためスキップ")
        }

        return RenderTarget(
            device: device,
            queue: queue,
            library: library,
            vertexFunction: vertexFunction,
            vertexBuffer: vertexBuffer
        )
    }

    private func buildPipeline(target: RenderTarget, shaderType: Int32) throws -> MTLRenderPipelineState {
        let constants = MTLFunctionConstantValues()
        var typeValue = shaderType
        constants.setConstantValue(&typeValue, type: .int, index: 0)

        let fragmentFunction = try target.library.makeFunction(name: "fragmentShader", constantValues: constants)

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = target.vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        return try target.device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func render(target: RenderTarget,
                        pso: MTLRenderPipelineState,
                        time: Float,
                        hasBackground: Int32 = 0) throws -> [UInt8] {
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(renderSize.width),
            height: Int(renderSize.height),
            mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .managed
        guard let texture = target.device.makeTexture(descriptor: textureDescriptor) else {
            throw XCTSkip("出力テクスチャを確保できないためスキップ")
        }

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = texture
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let commandBuffer = target.queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            throw XCTSkip("encoder を作成できないためスキップ")
        }

        var uniforms = Uniforms(
            time: time,
            resolution: SIMD2<Float>(Float(renderSize.width), Float(renderSize.height)),
            shaderType: 0,           // PSO に function constant で埋め込み済み。実行時値は使われない。
            hasBackgroundImage: hasBackground,
            effectIntensity: 0.0,
            mousePosition: SIMD2<Float>(0.5, 0.5),
            clickTime: 100.0,
            clickActive: 0,
            octaveCount: 4,
            hasMaskTexture: 0,
            spanWallpaperAcrossDisplays: 0,
            displayOrigin: SIMD2<Float>(0, 0),
            displaySize: SIMD2<Float>(0, 0),
            canvasSize: SIMD2<Float>(0, 0)
        )

        var effectUniforms = EffectUniforms()  // 全エフェクト無効 (デフォルト 0)

        encoder.setRenderPipelineState(pso)
        encoder.setVertexBuffer(target.vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 0)
        encoder.setFragmentBytes(&effectUniforms, length: MemoryLayout<EffectUniforms>.size, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: texture)
            blit.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return readBytes(from: texture)
    }

    private func readBytes(from texture: MTLTexture) -> [UInt8] {
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        let region = MTLRegionMake2D(0, 0, texture.width, texture.height)
        bytes.withUnsafeMutableBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                texture.getBytes(baseAddress, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
            }
        }
        return bytes
    }

    /// Peak Signal-to-Noise Ratio (BGRA8 想定)。完全一致 → +inf を最大値として扱う。
    private func computePSNR(_ a: [UInt8], _ b: [UInt8]) -> Double {
        XCTAssertEqual(a.count, b.count, "比較対象のサイズが一致するべき")
        guard a.count == b.count, !a.isEmpty else { return 0.0 }

        var mse: Double = 0.0
        for i in 0..<a.count {
            let diff = Double(a[i]) - Double(b[i])
            mse += diff * diff
        }
        mse /= Double(a.count)
        if mse <= .ulpOfOne {
            // 完全一致 → 大きな値で打ち止め。50dB を確実に超える 200dB を返す。
            return 200.0
        }
        let maxValue: Double = 255.0
        return 20.0 * log10(maxValue) - 10.0 * log10(mse)
    }
}
