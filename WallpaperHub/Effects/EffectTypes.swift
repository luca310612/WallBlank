import Foundation
import simd
import Accelerate

// MARK: - Effect Types

/// エフェクトの種類
enum EffectType: Int, CaseIterable, Codable {
    case particle = 0   // パーティクル（雨・雪）
    case blur = 1       // ぼかし
    case wave = 2       // 波（髪アニメーション）
    case chromatic = 3  // 色収差
    case glitch = 4     // グリッチ
    case vignette = 5   // ビネット
    case pixelate = 6   // ピクセレート
    case bloom = 7      // ブルーム
    case heatHaze = 8   // 陽炎
    case waterRipple = 9 // 水面波紋
    case foliageSway = 10 // 植物揺れ

    var displayName: String {
        switch self {
        case .particle: return "パーティクル"
        case .blur: return "ぼかし"
        case .wave: return "ウェーブ"
        case .chromatic: return "色収差"
        case .glitch: return "グリッチ"
        case .vignette: return "ビネット"
        case .pixelate: return "ピクセレート"
        case .bloom: return "ブルーム"
        case .heatHaze: return "陽炎"
        case .waterRipple: return "水面波紋"
        case .foliageSway: return "植物揺れ"
        }
    }

    var icon: String {
        switch self {
        case .particle: return "cloud.rain"
        case .blur: return "drop.circle"
        case .wave: return "wind"
        case .chromatic: return "rainbow"
        case .glitch: return "tv"
        case .vignette: return "circle.dashed"
        case .pixelate: return "square.grid.3x3"
        case .bloom: return "sun.max"
        case .heatHaze: return "flame"
        case .waterRipple: return "water.waves"
        case .foliageSway: return "leaf"
        }
    }
}

/// パーティクルスタイル
enum ParticleStyle: Int, CaseIterable, Codable {
    case rain = 0   // 雨
    case snow = 1   // 雪

    var displayName: String {
        switch self {
        case .rain: return "雨"
        case .snow: return "雪"
        }
    }

    var icon: String {
        switch self {
        case .rain: return "cloud.rain.fill"
        case .snow: return "snowflake"
        }
    }
}

// MARK: - Effect Parameters

/// パーティクルエフェクトのパラメータ
struct ParticleParams: Codable, Equatable {
    var enabled: Bool = false
    var style: ParticleStyle = .rain
    var density: Float = 0.5      // 0.0 - 1.0
    var speed: Float = 0.5        // 0.0 - 1.0
    var windAngle: Float = 0.0    // -1.0 - 1.0 (左右の傾き)
    var size: Float = 0.5         // 0.0 - 1.0
    var opacity: Float = 0.8      // 0.0 - 1.0

    static let `default` = ParticleParams()

    /// Metal Uniformsへの変換用
    var densityValue: Float { density * 100.0 + 10.0 }        // 10 - 110
    var speedValue: Float { speed * 2.0 + 0.5 }               // 0.5 - 2.5
    var windAngleValue: Float { windAngle * 0.5 }             // -0.5 - 0.5
    var sizeValue: Float { size * 0.015 + 0.005 }             // 0.005 - 0.02
}

/// ぼかしエフェクトのパラメータ
struct BlurParams: Codable, Equatable {
    var enabled: Bool = false
    var intensity: Float = 0.5    // 0.0 - 1.0
    var useMask: Bool = false     // マスク領域のみにぼかしを適用

    static let `default` = BlurParams()

    /// Metal Uniformsへの変換用
    var intensityValue: Float { intensity * 10.0 + 1.0 }     // 1.0 - 11.0
}

/// ウェーブ（髪アニメーション）エフェクトのパラメータ
struct WaveParams: Codable, Equatable {
    var enabled: Bool = false
    var amplitude: Float = 0.5    // 0.0 - 1.0 (振幅)
    var frequency: Float = 0.5    // 0.0 - 1.0 (周波数)
    var speed: Float = 0.5        // 0.0 - 1.0 (速度)
    var useMask: Bool = true      // マスク領域のみに適用

    static let `default` = WaveParams()

    /// Metal Uniformsへの変換用
    var amplitudeValue: Float { amplitude * 0.04 + 0.01 }    // 0.01 - 0.05
    var frequencyValue: Float { frequency * 20.0 + 5.0 }     // 5.0 - 25.0
    var speedValue: Float { speed * 4.0 + 1.0 }              // 1.0 - 5.0
}

/// 色収差エフェクトのパラメータ
struct ChromaticParams: Codable, Equatable {
    var enabled: Bool = false
    var intensity: Float = 0.5    // 0.0 - 1.0 (RGB分離の強さ)
    var angle: Float = 0.0        // -1.0 - 1.0 (分離の角度)

    static let `default` = ChromaticParams()

    /// Metal Uniformsへの変換用
    var intensityValue: Float { intensity * 0.02 + 0.002 }   // 0.002 - 0.022
    var angleValue: Float { angle * Float.pi }                 // -π - π
}

/// グリッチエフェクトのパラメータ
struct GlitchParams: Codable, Equatable {
    var enabled: Bool = false
    var intensity: Float = 0.5    // 0.0 - 1.0 (グリッチの強さ)
    var speed: Float = 0.5        // 0.0 - 1.0 (グリッチの速度)
    var blockSize: Float = 0.5    // 0.0 - 1.0 (ブロックサイズ)

    static let `default` = GlitchParams()

    /// Metal Uniformsへの変換用
    var intensityValue: Float { intensity * 0.1 }              // 0.0 - 0.1
    var speedValue: Float { speed * 10.0 + 1.0 }              // 1.0 - 11.0
    var blockSizeValue: Float { blockSize * 0.09 + 0.01 }     // 0.01 - 0.1
}

/// ビネットエフェクトのパラメータ
struct VignetteParams: Codable, Equatable {
    var enabled: Bool = false
    var intensity: Float = 0.5    // 0.0 - 1.0 (暗さの強度)
    var radius: Float = 0.5       // 0.0 - 1.0 (ビネットの半径)

    static let `default` = VignetteParams()

    /// Metal Uniformsへの変換用
    var intensityValue: Float { intensity * 1.5 + 0.1 }       // 0.1 - 1.6
    var radiusValue: Float { radius * 0.5 + 0.3 }             // 0.3 - 0.8
}

/// ピクセレートエフェクトのパラメータ
struct PixelateParams: Codable, Equatable {
    var enabled: Bool = false
    var size: Float = 0.5         // 0.0 - 1.0 (ピクセルサイズ)

    static let `default` = PixelateParams()

    /// Metal Uniformsへの変換用
    var sizeValue: Float { size * 0.048 + 0.002 }             // 0.002 - 0.05
}

/// ブルームエフェクトのパラメータ
struct BloomParams: Codable, Equatable {
    var enabled: Bool = false
    var intensity: Float = 0.5    // 0.0 - 1.0 (発光の強さ)
    var threshold: Float = 0.5    // 0.0 - 1.0 (発光の閾値)

    static let `default` = BloomParams()

    /// Metal Uniformsへの変換用
    var intensityValue: Float { intensity * 2.0 }              // 0.0 - 2.0
    var thresholdValue: Float { threshold * 0.7 + 0.3 }       // 0.3 - 1.0
}

/// 陽炎エフェクトのパラメータ
struct HeatHazeParams: Codable, Equatable {
    var enabled: Bool = false
    var intensity: Float = 0.5    // 0.0 - 1.0 (歪みの強さ)
    var speed: Float = 0.5        // 0.0 - 1.0 (揺らぎの速度)
    var scale: Float = 0.5        // 0.0 - 1.0 (揺らぎのスケール)

    static let `default` = HeatHazeParams()

    /// Metal Uniformsへの変換用
    var intensityValue: Float { intensity * 0.02 + 0.001 }    // 0.001 - 0.021
    var speedValue: Float { speed * 4.0 + 0.5 }               // 0.5 - 4.5
    var scaleValue: Float { scale * 30.0 + 5.0 }              // 5.0 - 35.0
}

/// 水面波紋エフェクトのパラメータ
struct WaterRippleParams: Codable, Equatable {
    var enabled: Bool = false
    var intensity: Float = 0.5    // 0.0 - 1.0 (歪みの強さ)
    var speed: Float = 0.5        // 0.0 - 1.0 (波の速度)
    var scale: Float = 0.5        // 0.0 - 1.0 (波のスケール)
    var reflection: Float = 0.3   // 0.0 - 1.0 (反射の強さ)
    var useMask: Bool = false     // マスク領域のみに適用

    static let `default` = WaterRippleParams()

    /// Metal Uniformsへの変換用
    var intensityValue: Float { intensity * 0.03 + 0.002 }    // 0.002 - 0.032
    var speedValue: Float { speed * 3.0 + 0.5 }               // 0.5 - 3.5
    var scaleValue: Float { scale * 20.0 + 3.0 }              // 3.0 - 23.0
    var reflectionValue: Float { reflection * 0.5 }            // 0.0 - 0.5
}

/// 植物揺れエフェクトのパラメータ
struct FoliageSwayParams: Codable, Equatable {
    var enabled: Bool = false
    var intensity: Float = 0.5    // 0.0 - 1.0 (揺れの強さ)
    var speed: Float = 0.5        // 0.0 - 1.0 (揺れの速度)
    var complexity: Float = 0.5   // 0.0 - 1.0 (揺れの複雑さ)
    var useMask: Bool = true      // マスク領域のみに適用

    static let `default` = FoliageSwayParams()

    /// Metal Uniformsへの変換用
    var intensityValue: Float { intensity * 0.03 + 0.005 }    // 0.005 - 0.035
    var speedValue: Float { speed * 2.0 + 0.3 }               // 0.3 - 2.3
    var complexityValue: Float { complexity * 3.0 + 1.0 }     // 1.0 - 4.0 (ノイズレイヤー数)
}

// MARK: - Effect Configuration

/// エフェクト全体の設定
struct EffectConfiguration: Codable, Equatable {
    var particle: ParticleParams = .default
    var blur: BlurParams = .default
    var wave: WaveParams = .default
    var chromatic: ChromaticParams = .default
    var glitch: GlitchParams = .default
    var vignette: VignetteParams = .default
    var pixelate: PixelateParams = .default
    var bloom: BloomParams = .default
    var heatHaze: HeatHazeParams = .default
    var waterRipple: WaterRippleParams = .default
    var foliageSway: FoliageSwayParams = .default

    /// アクティブなエフェクト数
    var activeEffectCount: Int {
        var count = 0
        if particle.enabled { count += 1 }
        if blur.enabled { count += 1 }
        if wave.enabled { count += 1 }
        if chromatic.enabled { count += 1 }
        if glitch.enabled { count += 1 }
        if vignette.enabled { count += 1 }
        if pixelate.enabled { count += 1 }
        if bloom.enabled { count += 1 }
        if heatHaze.enabled { count += 1 }
        if waterRipple.enabled { count += 1 }
        if foliageSway.enabled { count += 1 }
        return count
    }

    /// エフェクトが有効かどうか
    var hasActiveEffects: Bool {
        activeEffectCount > 0
    }

    static let `default` = EffectConfiguration()
}

// MARK: - Metal Uniforms

/// Metal シェーダー用のエフェクトUniforms構造体
/// この構造体はShaders.metalのEffectUniforms構造体と完全に一致している必要がある
struct EffectUniforms {
    // パーティクル (32 bytes)
    var particleEnabled: Int32 = 0
    var particleStyle: Int32 = 0          // 0=雨, 1=雪
    var particleDensity: Float = 50.0
    var particleSpeed: Float = 1.0
    var particleWindAngle: Float = 0.0
    var particleSize: Float = 0.01
    var particleOpacity: Float = 0.8
    var _pad1: Float = 0                  // パディング（16バイトアライメント用）

    // ぼかし (16 bytes)
    var blurEnabled: Int32 = 0
    var blurIntensity: Float = 5.0
    var blurUseMask: Int32 = 0
    var _pad2: Float = 0                  // パディング

    // ウェーブ (32 bytes)
    var waveEnabled: Int32 = 0
    var waveAmplitude: Float = 0.02
    var waveFrequency: Float = 10.0
    var waveSpeed: Float = 2.0
    var waveUseMask: Int32 = 0
    var _pad3: Int32 = 0                  // パディング
    var _pad4: Int32 = 0                  // パディング
    var _pad5: Int32 = 0                  // パディング

    // 色収差 (16 bytes)
    var chromaticEnabled: Int32 = 0
    var chromaticIntensity: Float = 0.01
    var chromaticAngle: Float = 0.0
    var _pad6: Float = 0                  // パディング

    // グリッチ (16 bytes)
    var glitchEnabled: Int32 = 0
    var glitchIntensity: Float = 0.05
    var glitchSpeed: Float = 5.0
    var glitchBlockSize: Float = 0.05

    // ビネット (16 bytes)
    var vignetteEnabled: Int32 = 0
    var vignetteIntensity: Float = 0.8
    var vignetteRadius: Float = 0.5
    var _pad7: Float = 0                  // パディング

    // ピクセレート (16 bytes)
    var pixelateEnabled: Int32 = 0
    var pixelateSize: Float = 0.02
    var _pad8: Float = 0                  // パディング
    var _pad9: Float = 0                  // パディング

    // ブルーム (16 bytes)
    var bloomEnabled: Int32 = 0
    var bloomIntensity: Float = 1.0
    var bloomThreshold: Float = 0.7
    var _pad10: Float = 0                 // パディング

    // 陽炎 (16 bytes)
    var heatHazeEnabled: Int32 = 0
    var heatHazeIntensity: Float = 0.01
    var heatHazeSpeed: Float = 2.0
    var heatHazeScale: Float = 15.0

    // 水面波紋 (32 bytes)
    var waterRippleEnabled: Int32 = 0
    var waterRippleIntensity: Float = 0.015
    var waterRippleSpeed: Float = 1.5
    var waterRippleScale: Float = 10.0
    var waterRippleReflection: Float = 0.15
    var waterRippleUseMask: Int32 = 0
    var _pad11: Float = 0                 // パディング
    var _pad12: Float = 0                 // パディング

    // 植物揺れ (16 bytes)
    var foliageSwayEnabled: Int32 = 0
    var foliageSwayIntensity: Float = 0.015
    var foliageSwaySpeed: Float = 1.0
    var foliageSwayComplexity: Float = 2.0
    var foliageSwayUseMask: Int32 = 0
    var _pad13: Int32 = 0                 // パディング
    var _pad14: Int32 = 0                 // パディング
    var _pad15: Int32 = 0                 // パディング

    /// EffectConfigurationから初期化
    init(from config: EffectConfiguration) {
        // パーティクル
        particleEnabled = config.particle.enabled ? 1 : 0
        particleStyle = Int32(config.particle.style.rawValue)
        particleDensity = config.particle.densityValue
        particleSpeed = config.particle.speedValue
        particleWindAngle = config.particle.windAngleValue
        particleSize = config.particle.sizeValue
        particleOpacity = config.particle.opacity

        // ぼかし
        blurEnabled = config.blur.enabled ? 1 : 0
        blurIntensity = config.blur.intensityValue
        blurUseMask = config.blur.useMask ? 1 : 0

        // ウェーブ
        waveEnabled = config.wave.enabled ? 1 : 0
        waveAmplitude = config.wave.amplitudeValue
        waveFrequency = config.wave.frequencyValue
        waveSpeed = config.wave.speedValue
        waveUseMask = config.wave.useMask ? 1 : 0

        // 色収差
        chromaticEnabled = config.chromatic.enabled ? 1 : 0
        chromaticIntensity = config.chromatic.intensityValue
        chromaticAngle = config.chromatic.angleValue

        // グリッチ
        glitchEnabled = config.glitch.enabled ? 1 : 0
        glitchIntensity = config.glitch.intensityValue
        glitchSpeed = config.glitch.speedValue
        glitchBlockSize = config.glitch.blockSizeValue

        // ビネット
        vignetteEnabled = config.vignette.enabled ? 1 : 0
        vignetteIntensity = config.vignette.intensityValue
        vignetteRadius = config.vignette.radiusValue

        // ピクセレート
        pixelateEnabled = config.pixelate.enabled ? 1 : 0
        pixelateSize = config.pixelate.sizeValue

        // ブルーム
        bloomEnabled = config.bloom.enabled ? 1 : 0
        bloomIntensity = config.bloom.intensityValue
        bloomThreshold = config.bloom.thresholdValue

        // 陽炎
        heatHazeEnabled = config.heatHaze.enabled ? 1 : 0
        heatHazeIntensity = config.heatHaze.intensityValue
        heatHazeSpeed = config.heatHaze.speedValue
        heatHazeScale = config.heatHaze.scaleValue

        // 水面波紋
        waterRippleEnabled = config.waterRipple.enabled ? 1 : 0
        waterRippleIntensity = config.waterRipple.intensityValue
        waterRippleSpeed = config.waterRipple.speedValue
        waterRippleScale = config.waterRipple.scaleValue
        waterRippleReflection = config.waterRipple.reflectionValue
        waterRippleUseMask = config.waterRipple.useMask ? 1 : 0

        // 植物揺れ
        foliageSwayEnabled = config.foliageSway.enabled ? 1 : 0
        foliageSwayIntensity = config.foliageSway.intensityValue
        foliageSwaySpeed = config.foliageSway.speedValue
        foliageSwayComplexity = config.foliageSway.complexityValue
        foliageSwayUseMask = config.foliageSway.useMask ? 1 : 0
    }

    init() {}
}

// MARK: - Mask Data

/// マスクデータ（ブラシ編集・AI検出結果を保持）
class MaskData {
    var width: Int
    var height: Int
    var data: [UInt8]  // R8フォーマット（0-255）

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.data = [UInt8](repeating: 0, count: width * height)
    }

    /// 指定位置の値を取得
    func getValue(x: Int, y: Int) -> UInt8 {
        guard x >= 0, x < width, y >= 0, y < height else { return 0 }
        return data[y * width + x]
    }

    /// 指定位置に値を設定
    func setValue(x: Int, y: Int, value: UInt8) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        data[y * width + x] = value
    }

    /// ブラシでペイント（処理本体は Rust `artia_mask_paint_circle`）
    /// Why: Swift の二重ループで重かったホットパスを Rust に集約し描画中の CPU を解放する
    func paint(centerX: Int, centerY: Int, radius: Int, value: UInt8, softness: Float = 0.5, isErasing: Bool = false) {
        guard radius > 0, width > 0, height > 0 else { return }
        RustCore.maskPaintCircle(
            data: &data,
            width: Int32(width),
            height: Int32(height),
            centerX: Int32(centerX),
            centerY: Int32(centerY),
            radius: Int32(radius),
            value: value,
            softness: softness,
            isErasing: isErasing
        )
    }

    /// 点列（ストローク）を一括でペイント（処理本体は Rust `artia_mask_paint_stroke`）
    func paintStroke(points: [CGPoint], radius: Int, value: UInt8, softness: Float = 0.5, isErasing: Bool = false) {
        guard !points.isEmpty, radius > 0, width > 0, height > 0 else { return }
        var interleaved = [Float](repeating: 0, count: points.count * 2)
        for (i, p) in points.enumerated() {
            interleaved[i * 2] = Float(p.x)
            interleaved[i * 2 + 1] = Float(p.y)
        }
        RustCore.maskPaintStroke(
            data: &data,
            width: Int32(width),
            height: Int32(height),
            pointsXY: interleaved,
            radius: Int32(radius),
            value: value,
            softness: softness,
            isErasing: isErasing
        )
    }

    /// マスクをクリア（Rust 経由）
    func clear() {
        guard !data.isEmpty else { return }
        RustCore.maskClear(data: &data)
    }

    /// 軸平行矩形を一様に塗る（Rust 経由）
    func fillAxisAlignedRect(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat, value: UInt8) {
        guard width > 0, height > 0 else { return }
        RustCore.maskFillRect(
            data: &data,
            width: Int32(width),
            height: Int32(height),
            x0: Float(x0),
            y0: Float(y0),
            x1: Float(x1),
            y1: Float(y1),
            value: value
        )
    }

    /// マスクを反転（Rust 経由）
    func invert() {
        guard !data.isEmpty else { return }
        RustCore.maskInvert(data: &data)
    }

    /// ボックスブラーを適用（Rust 経由）
    /// Why: 旧 vImageTentConvolve_Planar8 から Rust 実装へ統一し、依存を Accelerate に縛らない
    func applyGaussianBlur(radius: Int = 3) {
        guard radius > 0, width > 0, height > 0 else { return }
        RustCore.maskBoxBlur(
            data: &data,
            width: Int32(width),
            height: Int32(height),
            radius: Int32(radius)
        )
    }
}
