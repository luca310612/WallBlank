import Foundation
import CoreGraphics

// MARK: - RustBrushMaskRasterizer
// Why: 既存の `BrushMaskRasterizer` (enum + 静的メソッド) を BrushMaskRasterizing に
// 適合させる薄いアダプタ。挙動・出力は既存と完全互換 (内部で同じ Rust FFI を呼ぶ)。
// Phase 1.4+ の Strategy/Factory 切替で「flag OFF = この実装」がデフォルト経路になる。

/// Rust (artia-core/brush_mask) を経由する CPU マスクラスタライザ
final class RustBrushMaskRasterizer: BrushMaskRasterizing {

    init() {}

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

        // 既存マスクは CPU 形式に正規化してから渡す (Rust 側が UInt8 配列前提のため)。
        let existingCPU = existing?.toCPU()

        // 重い処理はバックグラウンドキューへ逃がしつつ async で結果を返す。
        return await withCheckedContinuation { continuation in
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
                continuation.resume(returning: mask.map { .cpu($0) })
            }
        }
    }
}
