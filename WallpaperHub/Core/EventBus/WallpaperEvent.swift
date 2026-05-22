import Foundation

/// エンジンステータス（型安全なEquatable対応）
struct EngineStatus: Equatable, Codable {
    var isRunning: Bool = false
    var activeDisplayCount: Int = 0
    var currentShader: Int = 0
    var isPaused: Bool = false
}

/// 型安全なイベント定義
/// 文字列ベースのDistributedNotificationCenterを置き換える
enum WallpaperEvent: Equatable {
    // MARK: - Settings Events
    case shaderChanged(shader: Int)
    /// displayIDがnilの場合は全ディスプレイに適用
    case backgroundImageChanged(path: String, displayID: String?)
    case intensityChanged(intensity: Float)
    case pauseStateChanged(paused: Bool)
    case settingsChanged

    // MARK: - Display Events
    case displaysChanged(displays: [String])
    case displayRemoved(displayID: String)

    // MARK: - Performance Events
    case performanceSettingsChanged
    case performancePresetChanged(preset: PerformancePreset)

    // MARK: - Effect Events
    case effectConfigurationChanged(config: EffectConfiguration?)

    // MARK: - Collection Events
    case collectionChanged(collectionID: String)

    // MARK: - Engine Events
    case engineStatusRequest
    case engineStatusResponse(status: EngineStatus)

    /// イベントの名前（ログ用）
    var name: String {
        switch self {
        case .shaderChanged: return "shaderChanged"
        case .backgroundImageChanged: return "backgroundImageChanged"
        case .intensityChanged: return "intensityChanged"
        case .pauseStateChanged: return "pauseStateChanged"
        case .settingsChanged: return "settingsChanged"
        case .displaysChanged: return "displaysChanged"
        case .displayRemoved: return "displayRemoved"
        case .performanceSettingsChanged: return "performanceSettingsChanged"
        case .performancePresetChanged: return "performancePresetChanged"
        case .effectConfigurationChanged: return "effectConfigurationChanged"
        case .collectionChanged: return "collectionChanged"
        case .engineStatusRequest: return "engineStatusRequest"
        case .engineStatusResponse: return "engineStatusResponse"
        }
    }

    // MARK: - Equatable
    static func == (lhs: WallpaperEvent, rhs: WallpaperEvent) -> Bool {
        switch (lhs, rhs) {
        case (.shaderChanged(let l), .shaderChanged(let r)):
            return l == r
        case (.backgroundImageChanged(let lPath, let lDisplay), .backgroundImageChanged(let rPath, let rDisplay)):
            return lPath == rPath && lDisplay == rDisplay
        case (.intensityChanged(let l), .intensityChanged(let r)):
            return l == r
        case (.pauseStateChanged(let l), .pauseStateChanged(let r)):
            return l == r
        case (.settingsChanged, .settingsChanged):
            return true
        case (.displaysChanged(let l), .displaysChanged(let r)):
            return l == r
        case (.displayRemoved(let l), .displayRemoved(let r)):
            return l == r
        case (.performanceSettingsChanged, .performanceSettingsChanged):
            return true
        case (.performancePresetChanged(let l), .performancePresetChanged(let r)):
            return l.rawValue == r.rawValue
        case (.effectConfigurationChanged(let l), .effectConfigurationChanged(let r)):
            return l == r
        case (.collectionChanged(let l), .collectionChanged(let r)):
            return l == r
        case (.engineStatusRequest, .engineStatusRequest):
            return true
        case (.engineStatusResponse(let l), .engineStatusResponse(let r)):
            return l == r
        default:
            return false
        }
    }
}
