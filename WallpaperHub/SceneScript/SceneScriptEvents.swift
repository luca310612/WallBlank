import Foundation
import JavaScriptCore

/// Phase 5: SceneScript の公開イベント。
/// Why: Wallpaper Engine 互換のイベント名 (init / update / applyUserProperties / cursor.* / media.*) を
///      Swift enum で型安全に表現し、dispatch ルートを 1 箇所に集約する。
public enum SceneScriptEvent {
    /// 壁紙ロード時 1 回。
    case initLifecycle
    /// 毎フレーム呼ばれる。deltaTime は秒。
    case update(deltaTime: Double)
    /// User Properties 値変更時。
    case applyUserProperties(values: [String: Any])
    /// マウス移動 (キャンバス座標)。
    case cursorMove(x: Double, y: Double)
    /// マウスダウン。
    case cursorDown(x: Double, y: Double)
    /// マウスアップ。
    case cursorUp(x: Double, y: Double)
    /// クリック (down → up を伴う)。
    case cursorClick(x: Double, y: Double)
    /// メディア再生開始。
    case mediaPlaying(payload: [String: Any])
    /// メディア一時停止。
    case mediaPaused(payload: [String: Any])
    /// メディアタイトル変更。
    case mediaTitle(value: String)
    /// メディアアーティスト変更。
    case mediaArtist(value: String)

    /// JS 側で呼ばれる関数名 (Wallpaper Engine 互換)。
    public var jsFunctionName: String {
        switch self {
        case .initLifecycle: return "init"
        case .update: return "update"
        case .applyUserProperties: return "applyUserProperties"
        case .cursorMove: return "cursorMove"
        case .cursorDown: return "cursorDown"
        case .cursorUp: return "cursorUp"
        case .cursorClick: return "cursorClick"
        case .mediaPlaying: return "mediaPlaying"
        case .mediaPaused: return "mediaPaused"
        case .mediaTitle: return "mediaTitle"
        case .mediaArtist: return "mediaArtist"
        }
    }

    /// JS 関数に渡す引数列。
    public var jsArguments: [Any] {
        switch self {
        case .initLifecycle:
            return []
        case .update(let dt):
            return [dt]
        case .applyUserProperties(let values):
            return [values]
        case .cursorMove(let x, let y),
             .cursorDown(let x, let y),
             .cursorUp(let x, let y),
             .cursorClick(let x, let y):
            return [x, y]
        case .mediaPlaying(let payload), .mediaPaused(let payload):
            return [payload]
        case .mediaTitle(let v), .mediaArtist(let v):
            return [v]
        }
    }
}

/// JS の global function を呼ぶ薄いディスパッチャ。
/// Why: SceneScriptRuntime から実装を切り出し、テスト時は context のみで検証できるようにする。
public final class SceneScriptEventDispatcher {

    private let context: JSContext

    public init(context: JSContext) {
        self.context = context
    }

    /// 直近に dispatch したイベント名 (テスト用)。
    public private(set) var lastDispatchedFunction: String?

    /// `event.jsFunctionName` のグローバル関数を呼び出す。未定義の場合は no-op。
    public func dispatch(_ event: SceneScriptEvent) {
        let name = event.jsFunctionName
        lastDispatchedFunction = name
        guard let global = context.globalObject,
              let fn = global.objectForKeyedSubscript(name),
              !fn.isUndefined,
              !fn.isNull else {
            return
        }
        // JS 側で関数として定義されていない (例: 文字列など) ケースは安全側で skip。
        if !fn.isObject { return }
        fn.call(withArguments: event.jsArguments)
    }
}
