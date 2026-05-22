import Foundation

/// Steam / Steam Workshop 用の設定。
/// Steam 側の準備ができたら App ID を設定し、Steamworks 機能を有効化する。
enum SteamConfig {

    /// Steam アプリ ID。Steamworks Partner でアプリ登録後に取得する。
    /// 0 の場合は Steam API を無効化する（未設定）。
    static let appID: UInt32 = 0

    /// Steam Workshop 機能を利用可能とするか（App ID が 0 でない場合に true にできる）
    static var isWorkshopEnabled: Bool {
        appID != 0
    }
}
