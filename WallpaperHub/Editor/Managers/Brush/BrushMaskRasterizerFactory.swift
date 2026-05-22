import Foundation
import Metal

// MARK: - BrushMaskRasterizerFactory
// Why: Settings.useGPUBrush に応じて Rust / Metal を切り替える Strategy 工場。
// 呼び出し側は protocol 経由で利用するため、フラグ切替時もコールサイトを書き換えなくて済む。
// MTLDevice が取れない or Metal 実装の生成に失敗した場合は Rust にフォールバック。

enum BrushMaskRasterizerFactory {
    /// Strategy インスタンスを生成する。
    /// - Parameters:
    ///   - useGPU: Settings.useGPUBrush の値
    ///   - device: GPU 経路で使用する MTLDevice (取得失敗時は Rust に自動フォールバック)
    static func make(useGPU: Bool, device: MTLDevice?) -> BrushMaskRasterizing {
        if useGPU, let device, let metal = MetalBrushMaskRasterizer(device: device) {
            return metal
        }
        return RustBrushMaskRasterizer()
    }
}
