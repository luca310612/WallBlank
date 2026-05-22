import Foundation
import AppKit
import AVFoundation
import Combine
import MetalKit
import UniformTypeIdentifiers

// MARK: - ImageEditorManager + Viewport
// Why: ビューポート(キャンバス)解像度とIOSurfaceテクスチャ更新を集約。

extension ImageEditorManager {

    func updateIOSurfaceTexture(engine: UnsafeMutableRawPointer) {
        guard let device = metalDevice else {
            debugLog("[ImageEditorManager] MTLDevice未初期化")
            return
        }

        // ビューポートモード時はアクティブIOSurface、それ以外はキャンバスIOSurfaceを使用
        guard let surface = RustCore.getWgpuActiveSurface(engine) else {
            debugLog("[ImageEditorManager] IOSurface取得失敗（active_surface）")
            return
        }

        // IOSurfaceポインタが変わっていなければスキップ（不要な再作成回避）
        let currentPtr = Unmanaged.passUnretained(surface).toOpaque()
        if currentPtr == lastIOSurfacePtr && ioSurfaceTexture != nil {
            return
        }
        lastIOSurfacePtr = currentPtr

        // IOSurfaceの実際のサイズを使用（ビューポートサイズ or キャンバスサイズ）
        let surfaceWidth = IOSurfaceGetWidth(surface)
        let surfaceHeight = IOSurfaceGetHeight(surface)

        // IOSurfaceの実際のbytesPerRowに合わせる（システムがアラインメント調整するためstrideバリデーションエラーを防止）
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2D
        desc.pixelFormat = .bgra8Unorm
        desc.width = surfaceWidth
        desc.height = surfaceHeight
        desc.usage = [.shaderRead]
        desc.storageMode = .shared

        ioSurfaceTexture = device.makeTexture(
            descriptor: desc,
            iosurface: surface,
            plane: 0
        )
        debugLog("[ImageEditorManager] IOSurfaceTexture更新: \(surfaceWidth)x\(surfaceHeight)")
    }

    @discardableResult
    func updateViewportSize(width: CGFloat, height: CGFloat) -> Bool {
        guard let engine = wgpuEngine else { return false }
        let minValidSize: CGFloat = 32
        if width < minValidSize || height < minValidSize {
            return false
        }
        // 同じ解像度ならスキップ（draw ループから毎フレーム呼ばれても再作成しない）
        if width == lastViewportPixelWidth && height == lastViewportPixelHeight {
            return false
        }
        lastViewportPixelWidth = width
        lastViewportPixelHeight = height
        let w = UInt32(width)
        let h = UInt32(height)

        // ビューポートモードが未有効なら有効化（初回呼び出し時）
        RustCore.wgpuSetViewportMode(engine, enabled: true)

        // Rustエンジンのビューポートサイズを更新（IOSurface再作成）
        if let surface = RustCore.wgpuSetViewportSize(engine, width: w, height: h) {
            // 新しいIOSurfaceからMTLTextureを再作成
            guard let device = metalDevice else { return false }

            // IOSurfaceの実際のサイズを使用（Rust側で調整される可能性があるため）
            let surfaceWidth = IOSurfaceGetWidth(surface)
            let surfaceHeight = IOSurfaceGetHeight(surface)
            guard surfaceWidth > 0, surfaceHeight > 0 else { return false }

            // IOSurfaceの実際のbytesPerRowに合わせる（strideバリデーションエラー防止）
            let desc = MTLTextureDescriptor()
            desc.textureType = .type2D
            desc.pixelFormat = .bgra8Unorm
            desc.width = surfaceWidth
            desc.height = surfaceHeight
            desc.usage = [.shaderRead]
            desc.storageMode = .shared

            ioSurfaceTexture = device.makeTexture(
                descriptor: desc,
                iosurface: surface,
                plane: 0
            )
            // IOSurfaceポインタ追跡を更新
            lastIOSurfacePtr = Unmanaged.passUnretained(surface).toOpaque()
            debugLog("[ImageEditorManager] ビューポートサイズ更新: \(surfaceWidth)x\(surfaceHeight), ioTex=\(ioSurfaceTexture != nil)")
            return true
        }
        return false
    }

    func updateViewportParams(from viewport: CanvasViewport, scaleFactor: CGFloat = 2.0) {
        guard let engine = wgpuEngine else { return }
        let origin = viewport.canvasOriginInView
        RustCore.wgpuSetViewportParams(
            engine,
            zoom: Float(viewport.totalScale * scaleFactor),
            panX: Float(viewport.panOffset.x * scaleFactor),
            panY: Float(viewport.panOffset.y * scaleFactor),
            canvasOriginX: Float(origin.x * scaleFactor),
            canvasOriginY: Float(origin.y * scaleFactor)
        )
    }
}
