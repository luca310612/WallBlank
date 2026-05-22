import Foundation
import AppKit
import AVFoundation
import Combine
import MetalKit
import UniformTypeIdentifiers

// MARK: - ImageEditorManager + Selection
// Why: 選択範囲のラスタ化、ブラシアウトライン管理を集約。

extension ImageEditorManager {

    func rasterizeSelectionMask(from penPath: PenPath) -> SelectionMask? {
        guard penPath.isClosed, penPath.points.count >= 3 else { return nil }
        let width = project.canvasWidth
        let height = project.canvasHeight
        guard width > 0, height > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bytesPerRow = width

        guard let ctx = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        // Canvas座標系（Y下向き）に合わせる
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        let cgPath = penPath.cgPath(closing: penPath.isClosed)
        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.addPath(cgPath)
        ctx.fillPath(using: .winding)

        // 0/255 に正規化
        for i in buffer.indices {
            buffer[i] = buffer[i] >= 128 ? 255 : 0
        }

        return SelectionMask(width: width, height: height, data: buffer)
    }

    func rasterizeSelectionMask(fromBrushTrace points: [CGPoint]) -> SelectionMask? {
        BrushMaskRasterizer.rasterizeBrushTrace(
            points: points,
            width: project.canvasWidth,
            height: project.canvasHeight,
            stroke: toolSettings.stroke,
            post: toolSettings.maskPost,
            gradient: toolSettings.gradient,
            combine: toolSettings.maskCombine,
            existingMask: selection.mask
        )
    }

    func rasterizeSelectionMask(
        fromBrushTrace points: [CGPoint],
        stroke: EditorBrushStrokeSettings,
        post: EditorMaskPostSettings,
        gradient: EditorMaskGradientSettings,
        combine: EditorMaskCombineMode
    ) -> SelectionMask? {
        BrushMaskRasterizer.rasterizeBrushTrace(
            points: points,
            width: project.canvasWidth,
            height: project.canvasHeight,
            stroke: stroke,
            post: post,
            gradient: gradient,
            combine: combine,
            existingMask: selection.mask
        )
    }

    func rasterizeSelectionMaskAsync(
        fromBrushTrace points: [CGPoint],
        stroke: EditorBrushStrokeSettings,
        post: EditorMaskPostSettings,
        gradient: EditorMaskGradientSettings,
        combine: EditorMaskCombineMode,
        completion: @escaping (SelectionMask?) -> Void
    ) {
        let pts = points
        Self.selectionMaskRasterQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            var existing: SelectionMask?
            var cw = 0
            var ch = 0
            DispatchQueue.main.sync {
                existing = self.selection.mask
                cw = self.project.canvasWidth
                ch = self.project.canvasHeight
            }
            guard cw > 0, ch > 0 else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // Phase 1.4+: Strategy 経由で Rust / Metal を切り替える。
            // Settings.useGPUBrush が OFF なら RustBrushMaskRasterizer が選ばれ、
            // 既存と完全互換 (同じ Rust FFI を呼び戻す)。
            let useGPU = SharedSettingsManager.shared.useGPUBrush
            let rasterizer = BrushMaskRasterizerFactory.make(
                useGPU: useGPU,
                device: useGPU ? MTLCreateSystemDefaultDevice() : nil
            )
            let canvas = CGSize(width: cw, height: ch)
            let existingHandle = existing.map { SelectionMaskHandle.cpu($0) }

            // 直列キューから async コンテキストへブリッジ。
            let semaphore = DispatchSemaphore(value: 0)
            var resolvedMask: SelectionMask?
            Task {
                let handle = await rasterizer.rasterize(
                    points: pts,
                    canvas: canvas,
                    stroke: stroke,
                    post: post,
                    gradient: gradient,
                    combine: combine,
                    existing: existingHandle
                )
                resolvedMask = handle?.toCPU()
                semaphore.signal()
            }
            semaphore.wait()

            // 次の直列ジョブが古い existing を読まないよう、このジョブ内でメインへ確実に反映してから戻る
            DispatchQueue.main.sync {
                completion(resolvedMask)
            }
        }
    }

    func buildMagneticSelectionMaskAsync(
        seedCanvasPoints: [CGPoint],
        tolerance01: Float = 0.12,
        combineMode: EditorMaskCombineMode,
        completion: @escaping (SelectionMask?) -> Void
    ) {
        guard !seedCanvasPoints.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        guard let exported = exportCompositeRGBAForSelection() else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let w = exported.width
        let h = exported.height
        guard w > 0, h > 0, exported.rgba.count >= w * h * 4 else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let bytes = [UInt8](exported.rgba)
        let seeds = seedCanvasPoints
        let tol = tolerance01
        let combine = combineMode
        Self.selectionMaskRasterQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            var existing: SelectionMask?
            DispatchQueue.main.sync {
                existing = self.selection.mask
            }
            let mask = Self.computeMagneticSelectionMaskFromRGBA(
                bytes: bytes,
                width: w,
                height: h,
                seedCanvasPoints: seeds,
                tolerance01: tol,
                combineMode: combine,
                existing: existing
            )
            DispatchQueue.main.sync {
                completion(mask)
            }
        }
    }

    func mutateToolSettings(_ body: (inout EditorToolSettings) -> Void) {
        var t = toolSettings
        body(&t)
        toolSettings = t
        toolSettings.save()
        syncSelectionBrushRadiusFromToolSettings()
    }

    func syncSelectionBrushRadiusFromToolSettings() {
        var s = selection
        s.brushRadius = toolSettings.stroke.radius
        selection = s
    }

    func clearSelection() {
        selection = .init()
        freeformBrushCompletedOutlines = []
    }

    func appendFreeformBrushOutline(_ points: [CGPoint]) {
        guard points.count >= 2 else { return }
        freeformBrushCompletedOutlines.append(points)
    }

    func clearFreeformBrushOutlinePreviews() {
        freeformBrushCompletedOutlines = []
    }
}
