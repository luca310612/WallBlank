import Foundation

/// Steam API の初期化と runCallbacks の実行を担当する。Workshop 機能は `isAvailable` が true のときのみ利用可能。
/// 実装時: steamworks-swift を SPM で追加し、Steam SDK をインストールしたうえで、SteamAPI の初期化・runCallbacks をここに実装する。
final class SteamManager: ObservableObject {

    static let shared = SteamManager()

    /// Steam API が利用可能か（初期化成功時）
    @Published private(set) var isAvailable: Bool = false

    /// 初期化結果のメッセージ（デバッグ・UI 表示用）
    @Published private(set) var statusMessage: String = ""

    private var callbackTimer: Timer?

    private init() {
        guard SteamConfig.appID != 0 else {
            statusMessage = "Steam App ID が未設定です"
            return
        }
        // steamworks-swift 導入後: SteamAPI(appID:) で初期化し、成功時は runCallbacks をタイマーで呼ぶ。
        // 現状はスタブのため常に未接続
        statusMessage = "Steam に接続していません（steamworks-swift を組み込み後に有効化）"
        debugLog("[SteamManager] スタブモード: Workshop 機能は無効です")
    }

    /// Steamworks API インスタンス（実装時は SteamAPI を返す。現状は nil）
    var api: Any? { nil }
}
