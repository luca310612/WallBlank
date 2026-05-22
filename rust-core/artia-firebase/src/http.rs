// 共通 HTTP クライアント。
// Why: reqwest::Client を直接呼ぶとタイムアウト・User-Agent などが各所で重複するため、
//      Auth/Storage 双方から使う薄いラッパに集約する。

use crate::error::{FirebaseError, Result};
use reqwest::{Client, Response, StatusCode};
use std::time::Duration;

/// Firebase REST クライアント共通の HTTP ラッパ。
#[derive(Debug, Clone)]
pub struct HttpClient {
    inner: Client,
}

impl HttpClient {
    /// 既定設定 (タイムアウト 30 秒) で新規構築する。
    pub fn new() -> Result<Self> {
        let client = Client::builder()
            .timeout(Duration::from_secs(30))
            .user_agent(concat!("artia-firebase/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(FirebaseError::from)?;
        Ok(Self { inner: client })
    }

    /// 任意の `reqwest::Client` を内包したインスタンスを返す。テストで差し替える用途。
    #[doc(hidden)]
    pub fn with_client(client: Client) -> Self {
        Self { inner: client }
    }

    /// 内包する reqwest::Client への参照。
    pub fn inner(&self) -> &Client {
        &self.inner
    }

    /// レスポンスがエラーステータスなら `FirebaseError::Api` に変換する。
    /// Why: Firebase は `{"error": {"message": "..."}}` 形式の JSON を返すため、
    ///      可能ならそのメッセージを抽出する。
    pub async fn ensure_ok(response: Response) -> Result<Response> {
        let status = response.status();
        if status.is_success() {
            return Ok(response);
        }

        let status_code = status.as_u16();
        let body = response.text().await.unwrap_or_default();
        let message = parse_error_message(&body, status);

        Err(FirebaseError::Api {
            status: status_code,
            message,
        })
    }
}

impl Default for HttpClient {
    fn default() -> Self {
        // Why: HTTP クライアントの構築は通常失敗しないため、Default で expect を許容する。
        Self::new().expect("HttpClient の構築に失敗しました")
    }
}

fn parse_error_message(body: &str, status: StatusCode) -> String {
    // Firebase REST: {"error": {"code": ..., "message": "...", "errors": [...]}}
    if let Ok(value) = serde_json::from_str::<serde_json::Value>(body) {
        if let Some(msg) = value
            .get("error")
            .and_then(|e| e.get("message"))
            .and_then(|m| m.as_str())
        {
            return msg.to_string();
        }
    }
    if body.is_empty() {
        format!("HTTP {}", status)
    } else {
        body.to_string()
    }
}
