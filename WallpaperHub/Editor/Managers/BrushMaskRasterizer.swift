import Foundation
import CoreGraphics

/// 自由ペン軌跡から選択マスクを生成（処理本体は Rust `artia-core` の `brush_mask`）
enum BrushMaskRasterizer {

    static func rasterizeBrushTrace(
        points: [CGPoint],
        width: Int,
        height: Int,
        stroke: EditorBrushStrokeSettings,
        post: EditorMaskPostSettings,
        gradient: EditorMaskGradientSettings,
        combine: EditorMaskCombineMode,
        existingMask: SelectionMask?
    ) -> SelectionMask? {
        guard width > 0, height > 0, points.count >= 2 else { return nil }

        var interleaved = [Float](repeating: 0, count: points.count * 2)
        for (i, p) in points.enumerated() {
            interleaved[i * 2] = Float(p.x)
            interleaved[i * 2 + 1] = Float(p.y)
        }

        let existingBytes: [UInt8]?
        if let ex = existingMask,
           ex.width == width, ex.height == height,
           ex.data.count == width * height {
            existingBytes = ex.data
        } else {
            existingBytes = nil
        }

        var params = ArtiaBrushMaskRasterParams(
            radius: Float(stroke.radius),
            hardness: Float(stroke.hardness),
            opacity: Float(stroke.opacity),
            flow: Float(stroke.flow),
            smoothing_percent: Float(stroke.smoothingPercent),
            paint_mode: brushPaintModeU32(stroke.paintMode),
            post_blur_radius: post.postBlurRadius,
            edge_adjust_pixels: Int32(post.edgeAdjustPixels),
            levels_in_black: post.levelsInBlack,
            levels_in_white: post.levelsInWhite,
            levels_out_black: post.levelsOutBlack,
            levels_out_white: post.levelsOutWhite,
            noise_amount: post.noiseAmount,
            gradient_kind: brushGradientKindU32(gradient.kind),
            gradient_strength: gradient.strength,
            combine_mode: brushCombineModeU32(combine)
        )

        guard let data = RustCore.brushRasterizeMask(
            pointsInterleavedXY: interleaved,
            pointCount: UInt32(points.count),
            canvasWidth: Int32(width),
            canvasHeight: Int32(height),
            params: &params,
            existingMask: existingBytes
        ) else {
            return nil
        }
        return SelectionMask(width: width, height: height, data: data)
    }

    private static func brushPaintModeU32(_ m: BrushMaskPaintMode) -> UInt32 {
        switch m {
        case .normal: return 0
        case .add: return 1
        case .subtract: return 2
        }
    }

    private static func brushGradientKindU32(_ k: BrushMaskGradientKind) -> UInt32 {
        switch k {
        case .none: return 0
        case .linearVertical: return 1
        case .linearHorizontal: return 2
        case .radial: return 3
        }
    }

    private static func brushCombineModeU32(_ c: EditorMaskCombineMode) -> UInt32 {
        switch c {
        case .replace: return 0
        case .add: return 1
        case .multiply: return 2
        case .difference: return 3
        }
    }
}
