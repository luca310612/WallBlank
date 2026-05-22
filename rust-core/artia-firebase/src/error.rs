// Artia Firebase REST クライアントの共通エラー型。
// Why: reqwest / serde_json / 認証エラーなど性質の違うエラーを単一の `FirebaseError` に集約し、
//      呼び出し側がパターンマッチで扱えるようにするため。

use thiserror::Error;

/// Firebase REST クライアントが返すエラー。
#[derive(Debug, Error)]
pub enum FirebaseError {
    /// HTTP 通信エラー（接続失敗・タイムアウトなど）
    #[error("HTTP 通信エラー: {0}")]
    Http(#[from] reqwest::Error),

    /// JSON のシリアライズ／デシリアライズ失敗
    #[error("JSON エラー: {0}")]
    Json(#[from] serde_json::Error),

    /// Firebase API がエラーレスポンスを返した
    #[error("Firebase API エラー (status={status}): {message}")]
    Api {
        /// HTTP ステータスコード
        status: u16,
        /// サーバーが返したエラーメッセージ
        message: String,
    },

    /// 認証関連エラー（ID トークン未取得、リフレッシュ失敗など）
    #[error("認証エラー: {0}")]
    Auth(String),

    /// 設定不備（API キー欠落、project_id 欠落など）
    #[error("設定エラー: {0}")]
    Config(String),

    /// その他予期しないエラー
    #[error("内部エラー: {0}")]
    Internal(String),
}

/// Firebase クレート内で使う Result エイリアス。
pub type Result<T> = std::result::Result<T, FirebaseError>;
