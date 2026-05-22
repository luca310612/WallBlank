import Foundation

/// バッテリー駆動時のパフォーマンス制御戦略 (Phase 7A)
///
/// Why: 単純な「停止/継続」では MacBook ユーザの体験を細かく調整できないため、
///      4 種類の段階的な戦略を用意する。値は `SharedSettings.batteryStrategy` に永続化される。
enum BatteryStrategy: String, Codable, CaseIterable, Identifiable, Equatable {
    /// バッテリー検知を無視し、AC 電源と同じ挙動を維持する。
    case ignore
    /// FPS を 30 へ抑える（解像度・品質はそのまま）。
    case reduceFps
    /// PerformancePreset を一段階下げる（high → balanced, balanced → low など）。
    case lowQuality
    /// 全壁紙を一時停止する。
    case pauseAll

    var id: String { rawValue }

    /// 設定 UI 表示用（日本語）
    var displayName: String {
        switch self {
        case .ignore:    return "そのまま継続"
        case .reduceFps: return "FPS を 30 に抑える"
        case .lowQuality: return "プリセットを下げる"
        case .pauseAll:  return "全ディスプレイを停止"
        }
    }

    /// バッテリー駆動時に強制したい FPS 上限 (`nil` の場合は制限なし)
    /// Why: PerformanceMonitor がレンダラに反映する際に、戦略の代わりにこの値だけ参照すれば済む。
    var enforcedFrameRate: Int? {
        switch self {
        case .reduceFps: return 30
        default:         return nil
        }
    }

    /// 戦略を適用したあとの effective preset
    /// Why: `lowQuality` は AC 時のプリセットを 1 段階下げるため、純粋関数として表現する。
    func apply(to preset: PerformancePreset) -> PerformancePreset {
        switch self {
        case .ignore, .reduceFps, .pauseAll:
            return preset
        case .lowQuality:
            switch preset {
            case .ultra:    return .high
            case .high:     return .balanced
            case .balanced: return .low
            case .low:      return .low
            }
        }
    }

    /// この戦略の下で「全ディスプレイを停止すべきか」
    /// Why: per-display pause flag を組み立てる側で複雑な条件分岐を書かずに済むよう、
    ///      enum 自身に責務を持たせる。
    var shouldPauseAll: Bool {
        self == .pauseAll
    }
}
