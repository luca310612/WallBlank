import Foundation
import Combine
import MetalKit

/// エフェクト状態管理マネージャー
class EffectManager: ObservableObject {

    static let shared = EffectManager()

    // MARK: - Published Properties

    @Published var configuration: EffectConfiguration = .default {
        didSet {
            debouncedSaveAndNotify()
        }
    }

    @Published var maskData: MaskData?
    @Published var isMaskEditorActive: Bool = false

    // MARK: - Private Properties

    private let defaults = UserDefaults.standard
    private static let configurationKey = "effectConfiguration"

    // マスクテクスチャキャッシュ
    private var maskTextureCache: [String: MTLTexture] = [:]
    var lastMaskUpdateTime: TimeInterval = 0

    /// 保存・通知のデバウンス用
    private var saveDebounceWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.1

    // MARK: - Initialization

    private init() {
        loadConfiguration()
    }

    // MARK: - Configuration Management

    private func loadConfiguration() {
        if let data = defaults.data(forKey: Self.configurationKey),
           let config = try? JSONDecoder().decode(EffectConfiguration.self, from: data) {
            configuration = config
        }
    }

    /// デバウンス付きの保存・通知（スライダー操作時の連続呼び出しを抑制）
    private func debouncedSaveAndNotify() {
        saveDebounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.saveConfiguration()
            self?.notifyConfigurationChanged()
        }
        saveDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func saveConfiguration() {
        do {
            let data = try JSONEncoder().encode(configuration)
            defaults.set(data, forKey: Self.configurationKey)
        } catch {
            print("[EffectManager] 設定の保存に失敗: \(error)")
        }
    }

    private func notifyConfigurationChanged() {
        // 同一プロセス内のリスナー（AppDelegate 等）には EventBus 経由で型安全に届ける。
        EventBus.shared.publish(.effectConfigurationChanged(config: configuration))
        // 別プロセス（--engine-only / --controller-only 起動時）への IPC のため DNC を保持。
        // Why: WallpaperEngine が controller プロセスから配信される設定変更通知を DNC で受信している。
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.artia.effectConfigurationChanged"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    // MARK: - Setter Methods

    func setParticleStyle(_ style: ParticleStyle) { configuration.particle.style = style }
    func setParticleDensity(_ value: Float) { configuration.particle.density = value }
    func setParticleSpeed(_ value: Float) { configuration.particle.speed = value }
    func setParticleWindAngle(_ value: Float) { configuration.particle.windAngle = value }
    func setParticleSize(_ value: Float) { configuration.particle.size = value }

    func setBlurIntensity(_ value: Float) { configuration.blur.intensity = value }
    func setBlurUseMask(_ value: Bool) { configuration.blur.useMask = value }

    func setWaveAmplitude(_ value: Float) { configuration.wave.amplitude = value }
    func setWaveFrequency(_ value: Float) { configuration.wave.frequency = value }
    func setWaveSpeed(_ value: Float) { configuration.wave.speed = value }
    func setWaveUseMask(_ value: Bool) { configuration.wave.useMask = value }

    func setChromaticIntensity(_ value: Float) { configuration.chromatic.intensity = value }
    func setChromaticAngle(_ value: Float) { configuration.chromatic.angle = value }

    func setGlitchIntensity(_ value: Float) { configuration.glitch.intensity = value }
    func setGlitchSpeed(_ value: Float) { configuration.glitch.speed = value }
    func setGlitchBlockSize(_ value: Float) { configuration.glitch.blockSize = value }

    func setVignetteIntensity(_ value: Float) { configuration.vignette.intensity = value }
    func setVignetteRadius(_ value: Float) { configuration.vignette.radius = value }

    func setPixelateSize(_ value: Float) { configuration.pixelate.size = value }

    func setBloomIntensity(_ value: Float) { configuration.bloom.intensity = value }
    func setBloomThreshold(_ value: Float) { configuration.bloom.threshold = value }

    func setHeatHazeIntensity(_ value: Float) { configuration.heatHaze.intensity = value }
    func setHeatHazeSpeed(_ value: Float) { configuration.heatHaze.speed = value }
    func setHeatHazeScale(_ value: Float) { configuration.heatHaze.scale = value }

    func setWaterRippleIntensity(_ value: Float) { configuration.waterRipple.intensity = value }
    func setWaterRippleSpeed(_ value: Float) { configuration.waterRipple.speed = value }
    func setWaterRippleScale(_ value: Float) { configuration.waterRipple.scale = value }
    func setWaterRippleReflection(_ value: Float) { configuration.waterRipple.reflection = value }
    func setWaterRippleUseMask(_ value: Bool) { configuration.waterRipple.useMask = value }

    func setFoliageSwayIntensity(_ value: Float) { configuration.foliageSway.intensity = value }
    func setFoliageSwaySpeed(_ value: Float) { configuration.foliageSway.speed = value }
    func setFoliageSwayComplexity(_ value: Float) { configuration.foliageSway.complexity = value }
    func setFoliageSwayUseMask(_ value: Bool) { configuration.foliageSway.useMask = value }

    /// すべてのエフェクトを無効にする
    func disableAllEffects() {
        // ローカルコピーで変更し、didSetを1回だけ発火させる
        var config = configuration
        config.particle.enabled = false
        config.blur.enabled = false
        config.wave.enabled = false
        config.chromatic.enabled = false
        config.glitch.enabled = false
        config.vignette.enabled = false
        config.pixelate.enabled = false
        config.bloom.enabled = false
        config.heatHaze.enabled = false
        config.waterRipple.enabled = false
        config.foliageSway.enabled = false
        configuration = config
    }

    /// 設定をリセット
    func resetConfiguration() {
        configuration = .default
        maskData = nil
        clearMaskTextureCache()
    }

    // MARK: - Mask Management

    /// マスクを初期化
    func initializeMask(width: Int, height: Int) {
        maskData = MaskData(width: width, height: height)
        lastMaskUpdateTime = CACurrentMediaTime()
    }

    /// マスクにペイント（画像ピクセル座標を直接使用）
    func paintMaskDirect(at imagePoint: CGPoint, radius: Int, value: UInt8, softness: Float, isErasing: Bool) {
        guard let mask = maskData else { return }

        let x = Int(imagePoint.x)
        let y = Int(imagePoint.y)

        mask.paint(centerX: x, centerY: y, radius: radius, value: value, softness: softness, isErasing: isErasing)
        lastMaskUpdateTime = CACurrentMediaTime()
    }

    /// マスクにストローク（点列）を一括適用（画像ピクセル座標）
    func applyMaskStrokeDirect(points: [CGPoint], radius: Int, value: UInt8, softness: Float, isErasing: Bool) {
        guard let mask = maskData, !points.isEmpty else { return }
        mask.paintStroke(points: points, radius: radius, value: value, softness: softness, isErasing: isErasing)
        lastMaskUpdateTime = CACurrentMediaTime()
    }

    /// 軸平行矩形でマスクを一括設定（画像ピクセル座標）
    func fillMaskRect(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat, value: UInt8) {
        guard let mask = maskData else { return }
        mask.fillAxisAlignedRect(x0: x0, y0: y0, x1: x1, y1: y1, value: value)
        lastMaskUpdateTime = CACurrentMediaTime()
    }

    /// マスクをクリア
    func clearMask() {
        maskData?.clear()
        lastMaskUpdateTime = CACurrentMediaTime()
    }

    /// マスクを反転
    func invertMask() {
        maskData?.invert()
        lastMaskUpdateTime = CACurrentMediaTime()
    }

    /// マスクをぼかす
    func blurMask(radius: Int = 3) {
        maskData?.applyGaussianBlur(radius: radius)
        lastMaskUpdateTime = CACurrentMediaTime()
    }

    // MARK: - Mask Texture

    /// マスクデータからMTLTextureを生成
    func createMaskTexture(device: MTLDevice) -> MTLTexture? {
        guard let mask = maskData else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: mask.width,
            height: mask.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        let region = MTLRegionMake2D(0, 0, mask.width, mask.height)
        texture.replace(region: region, mipmapLevel: 0, withBytes: mask.data, bytesPerRow: mask.width)

        return texture
    }

    /// マスクテクスチャを取得（キャッシュ利用）
    func getMaskTexture(device: MTLDevice, key: String) -> MTLTexture? {
        // キャッシュが最新ならそれを返す
        if let cached = maskTextureCache[key] {
            return cached
        }

        // 新しいテクスチャを生成
        guard let texture = createMaskTexture(device: device) else {
            return nil
        }

        maskTextureCache[key] = texture
        return texture
    }

    /// マスクテクスチャを更新
    func updateMaskTexture(device: MTLDevice, key: String) -> MTLTexture? {
        clearMaskTextureCache()
        return getMaskTexture(device: device, key: key)
    }

    /// マスクテクスチャキャッシュをクリア
    func clearMaskTextureCache() {
        maskTextureCache.removeAll()
    }

    /// マスクが更新されたかチェック
    func isMaskUpdated(since time: TimeInterval) -> Bool {
        return lastMaskUpdateTime > time
    }

    // MARK: - EffectUniforms Generation

    /// 現在の設定からEffectUniformsを生成
    func generateUniforms() -> EffectUniforms {
        return EffectUniforms(from: configuration)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let effectConfigurationChanged = Notification.Name("com.artia.effectConfigurationChanged")
}
