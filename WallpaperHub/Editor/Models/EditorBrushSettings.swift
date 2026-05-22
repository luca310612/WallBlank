import Foundation

// MARK: - 描画モード（マスクへの合成）

/// 自由ペン（ブラシ）ストロークのマスク合成モード
enum BrushMaskPaintMode: String, Codable, CaseIterable, Identifiable {
    /// アルファ合成（Photoshop「通常」に近い）
    case normal
    /// 値を加算（明るく蓄積）
    case add
    /// 値を減算（マスクを削る）
    case subtract

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal: return "通常"
        case .add: return "追加"
        case .subtract: return "減算"
        }
    }
}

// MARK: - ストローク（キャンバス上のブラシ）

/// ブラシストローク本体のパラメータ（直径・硬さ・フロー等）
struct EditorBrushStrokeSettings: Codable, Equatable {
    /// 円形ブラシの直径（キャンバスピクセル、最小 0.1）
    var diameterPixels: Double = 40
    /// エッジの硬さ 0…1（0 = ソフト、1 = シャープ）
    var hardness: Double = 0.65
    /// 1ストロークあたりの最大強度 0…1
    var opacity: Double = 1
    /// 蓄積の速さ 0.1…1（低いほどエアブラシ的）
    var flow: Double = 1
    /// 入力スムージング 0…100（パス補正の強さ）
    var smoothingPercent: Double = 10
    var paintMode: BrushMaskPaintMode = .normal

    /// 直径に応じた半径（下限 0.1px）
    var radius: CGFloat { CGFloat(max(0.1, diameterPixels * 0.5)) }
}

// MARK: - マスク仕上げ（ストローク確定後）

struct EditorMaskPostSettings: Codable, Equatable {
    /// ガウス風ぼかし（近似ボックス回数に相当する半径ピクセル）
    var postBlurRadius: Double = 0
    /// 境界の拡張（正）／収縮（負）ピクセル
    var edgeAdjustPixels: Int = 0
    /// レベル入力黒点 0…255
    var levelsInBlack: Double = 0
    /// レベル入力白点 0…255
    var levelsInWhite: Double = 255
    /// レベル出力黒点 0…255
    var levelsOutBlack: Double = 0
    /// レベル出力白点 0…255
    var levelsOutWhite: Double = 255
    /// 粒状ノイズの強さ 0…1
    var noiseAmount: Double = 0
}

// MARK: - グラデーション（マスク乗算プレビュー用・将来拡張）

enum BrushMaskGradientKind: String, Codable, CaseIterable, Identifiable {
    case none
    case linearVertical
    case linearHorizontal
    case radial

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none: return "なし"
        case .linearVertical: return "線形（縦）"
        case .linearHorizontal: return "線形（横）"
        case .radial: return "放射状"
        }
    }
}

struct EditorMaskGradientSettings: Codable, Equatable {
    var kind: BrushMaskGradientKind = .none
    /// グラデーションの乗算強度 0…1
    var strength: Double = 0.5
}

// MARK: - パーティクル（壁紙エンジン連携予定のパラメータ保持）

struct EditorParticleEmitterSettings: Codable, Equatable {
    var emissionRate: Double = 30
    var lifetimeSeconds: Double = 2
    var startSize: Double = 12
    var endSize: Double = 4
    var speed: Double = 80
    /// 放出方向（度、右向き0・反時計回り）
    var directionDegrees: Double = -90
    var textureAssetName: String = ""
    var colorR: Double = 1
    var colorG: Double = 1
    var colorB: Double = 1
    var alpha: Double = 1
    var additiveBlend: Bool = true
    var sizeRandom: Double = 0.2
    var positionRandom: Double = 0.15
    var rotationRandomDegrees: Double = 180
    var speedRandom: Double = 0.25
    var gravity: Double = 40
    var windX: Double = 0
    var windY: Double = 0
    var orbitStrength: Double = 0
    var noiseMotion: Double = 0
}

// MARK: - 画面エフェクト（後段シェーダ想定）

struct EditorProceduralEffectSettings: Codable, Equatable {
    var glowIntensity: Double = 0
    var glowThreshold: Double = 0.6
    var blurRadius: Double = 0
    var sharpenAmount: Double = 0
    var brightness: Double = 0
    var contrast: Double = 0
    var hueDegrees: Double = 0
    var saturation: Double = 0
    var waveAmplitude: Double = 0
    var waveFrequency: Double = 1
    var effectIntensity: Double = 1
    var distanceFade: Double = 0
}

// MARK: - アセット・入出力

struct EditorAssetPipelineSettings: Codable, Equatable {
    var preferPNGTransparency: Bool = true
    var allowJPEGBackground: Bool = true
    var useAlphaAsMask: Bool = true
    var useNoiseTexture: Bool = false
    var useExternalBrushPNG: Bool = false
    var externalBrushPath: String = ""
}

// MARK: - インタラクション・駆動

struct EditorInputReactivitySettings: Codable, Equatable {
    var mouseFollow: Bool = true
    var clickBurst: Bool = false
    var audioResponsive: Bool = false
    var audioBand: String = "bass"
    var timeAnimateParameters: Bool = false
    var timeSpeed: Double = 1
    var scriptEnabled: Bool = false
    var scriptName: String = ""
    var randomizeEachFrame: Bool = false
    var autoAnimateWithoutKeyframes: Bool = false
}

// MARK: - マスク合成モード（複数マスク）

enum EditorMaskCombineMode: String, Codable, CaseIterable, Identifiable {
    case replace
    case add
    case multiply
    case difference

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .replace: return "置換（新規マスク）"
        case .add: return "合成（描画モード適用）"
        case .multiply: return "乗算"
        case .difference: return "差分"
        }
    }
}

// MARK: - 一式（永続化）

/// ツールバー・インスペクターで編集するエディターツール設定の集合
struct EditorToolSettings: Codable, Equatable {
    var stroke: EditorBrushStrokeSettings = .init()
    var maskPost: EditorMaskPostSettings = .init()
    var gradient: EditorMaskGradientSettings = .init()
    var particle: EditorParticleEmitterSettings = .init()
    var procedural: EditorProceduralEffectSettings = .init()
    var assets: EditorAssetPipelineSettings = .init()
    var input: EditorInputReactivitySettings = .init()
    var maskCombine: EditorMaskCombineMode = .replace
    /// レイヤー表示優先（メタデータ・将来の並べ替え用）
    var displayPriority: Int = 0

    private static let storageKey = "artia.editor.toolSettings.v1"

    static func load() -> EditorToolSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              var decoded = try? JSONDecoder().decode(EditorToolSettings.self, from: data) else {
            return EditorToolSettings()
        }
        decoded.clampNumericMinimums()
        return decoded
    }

    /// UI 上の数値下限 0.1 に揃える（旧設定の自動移行）
    mutating func clampNumericMinimums() {
        stroke.opacity = max(0.1, min(1, stroke.opacity))
        stroke.flow = max(0.1, min(1, stroke.flow))
        stroke.hardness = max(0.1, min(1, stroke.hardness))
        stroke.smoothingPercent = max(0.1, min(100, stroke.smoothingPercent))
        maskPost.postBlurRadius = max(0.1, min(64, maskPost.postBlurRadius))
        maskPost.noiseAmount = max(0.1, min(1, maskPost.noiseAmount))
        maskPost.levelsInBlack = max(0.1, min(254, maskPost.levelsInBlack))
        gradient.strength = max(0.1, min(1, gradient.strength))
        particle.emissionRate = max(0.1, min(500, particle.emissionRate))
        particle.endSize = max(0.1, min(200, particle.endSize))
        particle.speed = max(0.1, min(400, particle.speed))
        particle.sizeRandom = max(0.1, min(1, particle.sizeRandom))
        particle.positionRandom = max(0.1, min(1, particle.positionRandom))
        procedural.effectIntensity = max(0.1, min(2, procedural.effectIntensity))
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
