import Cocoa
import MetalKit
import SwiftUI
import WebKit

// MARK: - DisplayWallpaperInstance + Settings
// Why: 設定／エフェクト／パフォーマンスへの反映を集約。

extension DisplayWallpaperInstance {

    func setShader(_ shader: ShaderType) {
        renderer?.currentShader = shader
    }

    func setBackgroundImage(from url: URL) {
        var resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        resolved = WallpaperEngineWebResolver.canonicalFilesystemURL(matching: resolved) ?? resolved
        debugLog("[Instance:\(displayID)] setBackgroundImage called with: \(resolved.path)")

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir) {
            if isDir.boolValue {
                if isWebWallpaperDirectory(resolved) {
                    // 起動直後に Engine の初期適用と backgroundImageChanged の再適用が重なると、
                    // 同一フォルダで WKWebView・LocalHTTP が二重に作られ直す（ログの port が2回出る原因）。
                    if isWebWallpaperActive,
                       webWallpaperView != nil,
                       let existingRoot = webWallpaperProjectRoot,
                       Self.isSameResolvedDirectory(existingRoot, resolved) {
                        if shouldSkipReloadForSameWebWallpaper(root: resolved) {
                            debugLog("[Instance:\(displayID)] 同一 Web 壁紙フォルダの重複適用をクールダウン中のため抑制")
                            return
                        }
                        debugLog("[Instance:\(displayID)] 同一 Web 壁紙フォルダを再読み込みして復旧を試行")
                    }
                    loadWebWallpaper(from: resolved)
                    return
                }
                // フォルダの場合：ドロップされたファイルと同じ処理を適用
                debugLog("[Instance:\(displayID)] Loading folder as playlist")
                handleDroppedFiles([resolved])
            } else {
                loadPreparedNonWebWallpaper(from: resolved)
            }
        } else {
            debugLog("[Instance:\(displayID)] ✗ 壁紙パスが存在しないため適用できません（設定に保存されたパスがエンジンから見えているか確認）: \(resolved.path)")
        }
    }

    func clearBackgroundImage() {
        stopPlaylist()
        hideWebWallpaperIfNeeded()
        clearWallpaperTransitionOverlay()
        renderer?.clearBackgroundImage()
    }

    func enableTransparentMode() {
        stopPlaylist()
        hideWebWallpaperIfNeeded()
        clearWallpaperTransitionOverlay()
        renderer?.enableTransparentMode()
    }

    func setEffectIntensity(_ intensity: Float) {
        renderer?.effectIntensity = intensity
    }

    func setDesktopItemsClickable(_ enabled: Bool) {
        // Web/音楽プレイヤー型壁紙は操作を受け付ける必要があるため、表示中は設定を反映しない
        // （updateWindowPresentation が壁紙種別に応じて常に正しい ignoresMouseEvents を再設定する）。
        updateWindowPresentation()
        debugLog("[Instance:\(displayID)] Desktop items clickable: \(enabled) (web active=\(isWebWallpaperActive))")
    }

    func setVolume(_ volume: Float) {
        renderer?.volume = volume
    }

    func setEffectConfiguration(_ config: EffectConfiguration) {
        renderer?.updateEffectConfiguration(config)
    }

    func setMaskTexture(from maskData: MaskData) {
        renderer?.updateMaskTexture(from: maskData)
    }

    func clearMaskTexture() {
        renderer?.clearMaskTexture()
    }

    func setFrameRate(_ fps: Int) {
        metalView?.preferredFramesPerSecond = fps
        debugLog("[Instance:\(displayID)] Frame rate set to \(fps) fps")
    }

    func setResolutionScale(_ scale: Float) {
        currentResolutionScale = scale
        syncDrawableSizeToWindow()

        if let drawableSize = metalView?.drawableSize {
            debugLog("[Instance:\(displayID)] Resolution scale set to \(scale) (\(Int(drawableSize.width))x\(Int(drawableSize.height)))")
        } else {
            debugLog("[Instance:\(displayID)] Resolution scale set to \(scale)")
        }
    }

    func applyPerformancePreset(_ preset: PerformancePreset) {
        applyPerformanceSettings(
            preset: preset,
            frameRate: preset.frameRate,
            resolutionScale: preset.resolutionScale
        )
    }

    func applyPerformanceSettings(preset: PerformancePreset, frameRate: Int, resolutionScale: Float) {
        let maxFPS = displayRefreshRate()
        currentPerformancePreset = preset
        currentFrameRate = max(15, min(frameRate, 144))
        let clampedResolutionScale = max(0.01, min(resolutionScale, 1.0))
        let effectiveFPS = min(currentFrameRate, maxFPS)
        setFrameRate(effectiveFPS)
        setResolutionScale(clampedResolutionScale)
        renderer?.octaveCount = Int32(preset.octaveCount)
        if let webView = webWallpaperView {
            scheduleWallpaperEnginePropertyBridge(for: webView)
        }
        debugLog("[Instance:\(displayID)] Applied performance settings: \(preset.displayName) (FPS: \(effectiveFPS), resolution: \(Int(clampedResolutionScale * 100))%, capped by display: \(maxFPS)Hz)")
    }

    func displayRefreshRate() -> Int {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return 60
        }
        guard let mode = CGDisplayCopyDisplayMode(screenNumber) else { return 60 }
        let rate = Int(mode.refreshRate)
        return rate > 0 ? rate : 60
    }
}
