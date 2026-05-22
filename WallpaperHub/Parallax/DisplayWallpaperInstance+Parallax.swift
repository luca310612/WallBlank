import AppKit
import Foundation

// Phase 4B: DisplayWallpaperInstance × ParallaxController の wire-up extension。
// Why: SharedSettings の `parallaxStrength` が有効な場合のみ、対応エンジンを
//      ParallaxController.shared に登録する。Renderer が wgpu engine を
//      生成 / 破棄するタイミングに合わせて attach / detach できる薄いフックを提供する。

extension DisplayWallpaperInstance {

    /// 指定エンジンをパララックス追従対象に登録する。
    /// - Note: `parallaxStrength` が 0.0 の時は no-op。
    func attachParallaxIfNeeded(engine: UnsafeMutableRawPointer) {
        let strength = SharedSettingsManager.shared.parallaxStrength
        guard strength > 0 else { return }
        ParallaxController.shared.register(engine: engine, screen: screen)
    }

    /// 指定エンジンの追従を解除する。
    func detachParallax(engine: UnsafeMutableRawPointer) {
        ParallaxController.shared.unregister(engine: engine)
    }
}
