import Foundation
import CoreGraphics
import Metal

// MARK: - MetalBrushMaskRasterizer
// Why: Phase 1.4+ では「BrushMaskRasterizing protocol」を Strategy として 2 実装で束ねるのが
// 第一目的。ピクセル完全一致 (< 2/255) を Rust 経路と保つために、本クラスの
// `rasterize(...)` は Rust と同じピクセル列 (smoothstep / post / gradient 全段) を内部で確保し、
// その結果を MTLTexture(.r8Unorm, .shared) にアップロードして `.gpu(texture)` で返す。
//
// 設計のポイント:
// - 実際の GPU compute (1 ダブ単位の rasterizeDab kernel) は Phase 1.4 で BrushMaskGPURasterizer に
//   既に存在し、ストローク中のリアルタイム更新で利用される (engine.commit + per-dab dispatch)。
// - 本クラスはストローク確定後の「最終マスク計算」を担当し、Rust 同等のピクセル列を CPU 側で
//   一度生成した上で GPU 側へアップロードする橋渡しを行う。
// - こうすることで Settings.useGPUBrush=ON でも視覚挙動は完全に Rust と同じになり、
//   GPU 経路の利点 (テクスチャ常駐 → 後段の合成パスで CPU↔GPU 往復を 1 度減らせる) のみを取れる。
// - Phase 1.5+ で post/gradient/blur をすべて Metal kernel 化し、Rust 依存を外す予定。

/// Metal compute (テクスチャ常駐) 経路の full-stroke ラスタライザ
final class MetalBrushMaskRasterizer: BrushMaskRasterizing {

    private let device: MTLDevice

    /// 失敗時 (kernel 確認に失敗等) は nil を返す failable initializer。
    init?(device: MTLDevice) {
        // BrushMaskGPURasterizer の生成可能性で「Metal シェーダが揃っているか」を簡易検査する。
        // 本クラス自身は per-dab kernel を直接使わないが、生成失敗時は GPU 経路全体を
        // 引っ込めて Rust にフォールバックさせるシグナルとして利用する。
        guard BrushMaskGPURasterizer(device: device) != nil else { return nil }
        self.device = device
    }

    func rasterize(
        points: [CGPoint],
        canvas: CanvasSize,
        stroke: EditorBrushStrokeSettings,
        post: EditorMaskPostSettings,
        gradient: EditorMaskGradientSettings,
        combine: EditorMaskCombineMode,
        existing: SelectionMaskHandle?
    ) async -> SelectionMaskHandle? {
        let width = Int(canvas.width.rounded())
        let height = Int(canvas.height.rounded())
        guard width > 0, height > 0, points.count >= 2 else { return nil }

        // 既存マスクは CPU 形式で受ける (Rust API 側が UInt8 配列を必要とするため)。
        let existingCPU = existing?.toCPU()

        // Phase 1.4+: Rust と完全一致するバイト列を取得し、後で MTLTexture にアップロードする。
        // 重い処理は背景キューへ逃がす。
        let cpuMask: SelectionMask? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let mask = BrushMaskRasterizer.rasterizeBrushTrace(
                    points: points,
                    width: width,
                    height: height,
                    stroke: stroke,
                    post: post,
                    gradient: gradient,
                    combine: combine,
                    existingMask: existingCPU
                )
                continuation.resume(returning: mask)
            }
        }
        guard let cpuMask else { return nil }

        // .r8Unorm / .shared テクスチャに同期アップロードして GPU 経由の後段消費に備える。
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            // テクスチャ生成に失敗したら CPU マスクをそのまま返す (フォールバック)。
            return .cpu(cpuMask)
        }
        texture.label = "MetalBrushMaskRasterizer.r8Unorm.\(width)x\(height)"

        cpuMask.data.withUnsafeBytes { buffer in
            if let base = buffer.baseAddress {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: base,
                    bytesPerRow: width
                )
            }
        }
        return .gpu(texture)
    }
}
