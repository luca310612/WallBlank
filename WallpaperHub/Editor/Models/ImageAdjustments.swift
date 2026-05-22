import Foundation

// MARK: - 画像調整パラメータ

/// 画像の色・明るさ等の調整パラメータ
struct ImageAdjustments: Codable, Equatable {
    var brightness: Float = 0       // -1.0 ～ 1.0
    var contrast: Float = 1         // 0.0 ～ 3.0
    var saturation: Float = 1       // 0.0 ～ 3.0
    var temperature: Float = 0      // -1.0 ～ 1.0（寒色↔暖色）
    var sharpness: Float = 0        // 0.0 ～ 1.0
    var gamma: Float = 1            // 0.1 ～ 3.0
    var exposure: Float = 0         // -3.0 ～ 3.0

    static let `default` = ImageAdjustments()

    /// デフォルト値かどうか
    var isDefault: Bool {
        self == .default
    }

    /// フィルタープリセットの調整値をマージ（プリセット値 + 手動調整の差分）
    func merged(with manual: ImageAdjustments) -> ImageAdjustments {
        var result = self
        result.brightness = clamp(brightness + manual.brightness, min: -1, max: 1)
        result.contrast = clamp(contrast * manual.contrast, min: 0, max: 3)
        result.saturation = clamp(saturation * manual.saturation, min: 0, max: 3)
        result.temperature = clamp(temperature + manual.temperature, min: -1, max: 1)
        result.sharpness = clamp(sharpness + manual.sharpness, min: 0, max: 1)
        result.gamma = clamp(gamma * manual.gamma, min: 0.1, max: 3)
        result.exposure = clamp(exposure + manual.exposure, min: -3, max: 3)
        return result
    }

    /// 値をクランプ
    private func clamp(_ value: Float, min: Float, max: Float) -> Float {
        Swift.min(Swift.max(value, min), max)
    }
}

// MARK: - フィルタープリセット

/// ワンタッチフィルタープリセット
enum FilterPreset: Int, CaseIterable, Codable {
    case none = 0         // なし
    case sepia = 1        // セピア
    case monochrome = 2   // モノクロ
    case neon = 3         // ネオン
    case cinematic = 4    // シネマティック
    case vintage = 5      // ヴィンテージ
    case cool = 6         // クール
    case warm = 7         // ウォーム
    case dramatic = 8     // ドラマティック

    var displayName: String {
        switch self {
        case .none: return "なし"
        case .sepia: return "セピア"
        case .monochrome: return "モノクロ"
        case .neon: return "ネオン"
        case .cinematic: return "シネマティック"
        case .vintage: return "ヴィンテージ"
        case .cool: return "クール"
        case .warm: return "ウォーム"
        case .dramatic: return "ドラマティック"
        }
    }

    var icon: String {
        switch self {
        case .none: return "circle.slash"
        case .sepia: return "photo.artframe"
        case .monochrome: return "circle.lefthalf.filled"
        case .neon: return "lightbulb.fill"
        case .cinematic: return "film"
        case .vintage: return "camera.filters"
        case .cool: return "snowflake"
        case .warm: return "sun.max.fill"
        case .dramatic: return "theatermasks"
        }
    }

    /// プリセットの画像調整パラメータ
    var adjustments: ImageAdjustments {
        switch self {
        case .none:
            return .default

        case .sepia:
            return ImageAdjustments(
                brightness: 0.05,
                contrast: 1.1,
                saturation: 0.3,
                temperature: 0.4,
                sharpness: 0,
                gamma: 1.1,
                exposure: 0.1
            )

        case .monochrome:
            return ImageAdjustments(
                brightness: 0,
                contrast: 1.2,
                saturation: 0,
                temperature: 0,
                sharpness: 0.1,
                gamma: 1.0,
                exposure: 0
            )

        case .neon:
            return ImageAdjustments(
                brightness: 0.1,
                contrast: 1.5,
                saturation: 2.0,
                temperature: -0.2,
                sharpness: 0.3,
                gamma: 0.8,
                exposure: 0.3
            )

        case .cinematic:
            return ImageAdjustments(
                brightness: -0.05,
                contrast: 1.3,
                saturation: 0.8,
                temperature: -0.1,
                sharpness: 0.1,
                gamma: 1.1,
                exposure: -0.1
            )

        case .vintage:
            return ImageAdjustments(
                brightness: 0.05,
                contrast: 0.9,
                saturation: 0.6,
                temperature: 0.2,
                sharpness: 0,
                gamma: 1.2,
                exposure: 0.1
            )

        case .cool:
            return ImageAdjustments(
                brightness: 0,
                contrast: 1.1,
                saturation: 0.9,
                temperature: -0.5,
                sharpness: 0.05,
                gamma: 1.0,
                exposure: 0
            )

        case .warm:
            return ImageAdjustments(
                brightness: 0.05,
                contrast: 1.05,
                saturation: 1.1,
                temperature: 0.5,
                sharpness: 0,
                gamma: 1.0,
                exposure: 0.05
            )

        case .dramatic:
            return ImageAdjustments(
                brightness: -0.1,
                contrast: 1.6,
                saturation: 0.7,
                temperature: -0.05,
                sharpness: 0.2,
                gamma: 0.9,
                exposure: -0.2
            )
        }
    }
}

// MARK: - 調整パラメータの範囲定義

/// 各調整パラメータの範囲とメタデータ
enum AdjustmentParameter: CaseIterable {
    case brightness, contrast, saturation, temperature, sharpness, gamma, exposure

    var displayName: String {
        switch self {
        case .brightness: return "明るさ"
        case .contrast: return "コントラスト"
        case .saturation: return "彩度"
        case .temperature: return "色温度"
        case .sharpness: return "シャープネス"
        case .gamma: return "ガンマ"
        case .exposure: return "露出"
        }
    }

    var icon: String {
        switch self {
        case .brightness: return "sun.max"
        case .contrast: return "circle.lefthalf.filled"
        case .saturation: return "drop.fill"
        case .temperature: return "thermometer"
        case .sharpness: return "triangle"
        case .gamma: return "waveform"
        case .exposure: return "camera.aperture"
        }
    }

    var range: ClosedRange<Float> {
        switch self {
        case .brightness: return -1...1
        case .contrast: return 0...3
        case .saturation: return 0...3
        case .temperature: return -1...1
        case .sharpness: return 0...1
        case .gamma: return 0.1...3
        case .exposure: return -3...3
        }
    }

    var defaultValue: Float {
        switch self {
        case .brightness: return 0
        case .contrast: return 1
        case .saturation: return 1
        case .temperature: return 0
        case .sharpness: return 0
        case .gamma: return 1
        case .exposure: return 0
        }
    }

    /// ImageAdjustmentsから値を取得するKeyPath
    var keyPath: WritableKeyPath<ImageAdjustments, Float> {
        switch self {
        case .brightness: return \.brightness
        case .contrast: return \.contrast
        case .saturation: return \.saturation
        case .temperature: return \.temperature
        case .sharpness: return \.sharpness
        case .gamma: return \.gamma
        case .exposure: return \.exposure
        }
    }
}
