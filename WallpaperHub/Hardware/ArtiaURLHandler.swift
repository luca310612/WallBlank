import Foundation
import AppKit

/// Phase 8.5: artia:// URL Scheme のディスパッチャ。
/// 受信した URL をパースして対応する Manager を呼び出す。
/// 形式 (artia-cli から送られる):
///   artia://wallpaper/set/<id-or-path>
///   artia://wallpaper/next | prev | random
///   artia://playlist/switch/<id>
///   artia://profile/switch/<id>      ※id は low/balanced/high/ultra のいずれか
///   artia://property/set/<key>/<value>
enum ArtiaURLHandler {

    /// 解析結果。テストから直接生成して dispatch を回せるよう Equatable にしておく。
    enum ParsedCommand: Equatable {
        case wallpaperSet(target: String)
        case wallpaperNext
        case wallpaperPrev
        case wallpaperRandom
        case playlistSwitch(id: String)
        case profileSwitch(id: String)
        case propertySet(key: String, value: String)
        case unknown(reason: String)
    }

    /// `artia://...` を ParsedCommand に変換する純粋関数。
    /// scheme が違う場合や path が足りない場合は `.unknown` を返す。
    static func parse(_ url: URL) -> ParsedCommand {
        guard url.scheme?.lowercased() == "artia" else {
            return .unknown(reason: "scheme is not artia")
        }
        // host (最初のセグメント) と pathComponents を統合する
        var segments: [String] = []
        if let host = url.host, !host.isEmpty {
            segments.append(host)
        }
        for component in url.pathComponents where component != "/" {
            segments.append(component)
        }
        // URL の path はパーセントデコード済みなのでそのまま使える
        guard let category = segments.first else {
            return .unknown(reason: "empty url")
        }
        switch category {
        case "wallpaper":
            guard segments.count >= 2 else { return .unknown(reason: "wallpaper subcommand 不足") }
            switch segments[1] {
            case "set":
                guard segments.count >= 3, !segments[2].isEmpty else {
                    return .unknown(reason: "wallpaper set: target がありません")
                }
                let target = segments[2..<segments.count].joined(separator: "/")
                return .wallpaperSet(target: target)
            case "next":   return .wallpaperNext
            case "prev":   return .wallpaperPrev
            case "random": return .wallpaperRandom
            default:       return .unknown(reason: "wallpaper の未知サブコマンド")
            }
        case "playlist":
            guard segments.count >= 3, segments[1] == "switch" else {
                return .unknown(reason: "playlist switch <id> 形式ではありません")
            }
            return .playlistSwitch(id: segments[2])
        case "profile":
            guard segments.count >= 3, segments[1] == "switch" else {
                return .unknown(reason: "profile switch <id> 形式ではありません")
            }
            return .profileSwitch(id: segments[2])
        case "property":
            guard segments.count >= 4, segments[1] == "set" else {
                return .unknown(reason: "property set <key> <value> 形式ではありません")
            }
            return .propertySet(key: segments[2], value: segments[3])
        default:
            return .unknown(reason: "未知のカテゴリ: \(category)")
        }
    }

    /// プロファイル文字列 (low/balanced/high/ultra) を PerformancePreset に変換する純粋関数。
    /// 数字 (0..3) も許容する。
    static func resolveProfile(id: String) -> PerformancePreset? {
        switch id.lowercased() {
        case "low", "0":      return .low
        case "balanced", "1": return .balanced
        case "high", "2":     return .high
        case "ultra", "3":    return .ultra
        default:              return nil
        }
    }
}
