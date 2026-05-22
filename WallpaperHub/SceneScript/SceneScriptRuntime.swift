import Foundation
import JavaScriptCore

/// Phase 5: Wallpaper Engine 互換 SceneScript (ECMAScript) ランタイム。
/// Why: 壁紙が JS でロジックを記述できるようにする。JavaScriptCore (macOS 標準) を使用し、
///      file system / network / process API は JSContext へ持ち込まない (sandbox)。
public final class SceneScriptRuntime {

    /// JS 側エラーを Swift ログへ流す際の通知名。テスト/開発時の観測用。
    public static let exceptionNotification = Notification.Name("ArtiaSceneScriptException")

    /// 直近の例外メッセージ (テスト容易性のため保持)。
    public private(set) var lastException: String?

    /// 直近に評価した JS のソース (デバッグ向け)。
    public private(set) var lastScriptName: String?

    /// 内部 JS コンテキスト。
    public let context: JSContext

    /// API バインディング (engine/layer/sound/video/particles)。
    /// Why: API は SceneScriptAPI 側でまとめて構築するため、後付けで attach する。
    public private(set) var api: SceneScriptAPI?

    /// イベントディスパッチャ。dispatch(event:) のエントリポイント。
    private let dispatcher: SceneScriptEventDispatcher

    public init() {
        guard let ctx = JSContext() else {
            // JSContext は通常 nil にならない。Optional unwrap の保険として fail-fast せず空 context を諦めて crash させるしかないが
            // 実機/CI でこの分岐に入るケースは想定外。
            fatalError("SceneScriptRuntime: JSContext を生成できませんでした")
        }
        self.context = ctx
        self.dispatcher = SceneScriptEventDispatcher(context: ctx)
        configureExceptionHandler()
        installMinimalGlobals()
    }

    /// エラー時に lastException を更新し、通知を投げる。
    private func configureExceptionHandler() {
        context.exceptionHandler = { [weak self] _, value in
            let message = value?.toString() ?? "(unknown JS exception)"
            self?.lastException = message
            NSLog("[SceneScript] JS 例外: %@", message)
            NotificationCenter.default.post(
                name: SceneScriptRuntime.exceptionNotification,
                object: self,
                userInfo: ["message": message]
            )
        }
    }

    /// JS 側で利用される最低限の global を設定する。
    /// Why: sandbox 観点で setTimeout / setInterval などの実装も持ち込まないが、
    ///      壁紙作者が import 系を書いてもエラーにならないよう no-op を提供する。
    private func installMinimalGlobals() {
        let noOp: @convention(block) () -> Void = {}
        context.setObject(noOp, forKeyedSubscript: "__artiaNoOp" as NSString)
        // file / network / process は意図的に未公開 (sandbox)。
    }

    /// API バインディングを attach する。SceneScriptAPI 側から呼び出す。
    public func attachAPI(_ api: SceneScriptAPI) {
        self.api = api
        api.install(into: context)
    }

    /// JS スクリプトを評価する。エラー時は lastException に格納される。
    /// - Parameters:
    ///   - source: JS ソース。
    ///   - name: ログ用の識別子 (例: "wallpaper.js")。
    /// - Returns: 評価結果 (例外時は nil)。
    @discardableResult
    public func evaluate(_ source: String, name: String? = nil) -> JSValue? {
        lastException = nil
        lastScriptName = name
        let result = context.evaluateScript(source, withSourceURL: name.map { URL(fileURLWithPath: $0) })
        if lastException != nil {
            return nil
        }
        return result
    }

    /// 任意の Swift 値を JS グローバルに公開する。
    public func setGlobal(_ key: String, value: Any) {
        context.setObject(value, forKeyedSubscript: key as NSString)
    }

    /// イベントを JS 側へ dispatch する。
    /// JS 側で `init()` / `update(dt)` / `applyUserProperties(values)` 等のグローバル関数を定義しておく。
    public func dispatch(_ event: SceneScriptEvent) {
        dispatcher.dispatch(event)
    }
}
