// HTTP リトライ機構。
// Why: Firebase REST 呼び出しは一時的な 5xx / 429 / ネットワーク瞬断で失敗することがあるため、
//      指数バックオフで自動再試行する共通ユーティリティを用意する。
//      reqwest::RequestBuilder は body を持つと clone できないので、再試行のたびに
//      呼び出し側がリクエストを組み直すクロージャ方式とする。

use crate::error::{FirebaseError, Result};
use crate::http::HttpClient;
use reqwest::Response;
use std::time::Duration;

/// バックオフ戦略。
#[derive(Debug, Clone, Copy)]
pub enum BackoffKind {
    /// 指数バックオフ。`base_delay * factor^(attempt-1)` を `max_delay` で頭打ち。
    Exponential {
        /// 1 回ごとに乗じる係数 (例: 2.0)。
        factor: f64,
    },
    /// 固定遅延。
    Fixed,
}

/// どんな失敗を再試行対象とするか。
#[derive(Debug, Clone, Copy)]
pub enum RetryCondition {
    /// ネットワークエラー (接続失敗・タイムアウトなど) のみ。
    Network,
    /// 5xx サーバーエラーのみ。
    Status5xx,
    /// 429 Too Many Requests のみ。
    TooManyRequests,
    /// ネットワーク + 5xx + 429 の合算 (推奨デフォルト)。
    Combined,
}

/// リトライ動作を制御するポリシー。
#[derive(Debug, Clone)]
pub struct RetryPolicy {
    /// 最大試行回数 (1 なら再試行なし)。
    pub max_attempts: u32,
    /// 初回リトライまでの基準待機時間。
    pub base_delay: Duration,
    /// 指数増加の上限。
    pub max_delay: Duration,
    /// バックオフ戦略。
    pub backoff: BackoffKind,
    /// どんな失敗を再試行対象とするか。
    pub retry_on: RetryCondition,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        // Why: Firebase の一時障害は数秒〜10 秒程度のスパイクが多く、
        //      3 回 / 200ms ベースの指数バックオフが現実的な落としどころ。
        Self {
            max_attempts: 3,
            base_delay: Duration::from_millis(200),
            max_delay: Duration::from_secs(10),
            backoff: BackoffKind::Exponential { factor: 2.0 },
            retry_on: RetryCondition::Combined,
        }
    }
}

impl RetryPolicy {
    /// テスト用や呼び出し側カスタマイズ用に固定遅延ポリシーを作る。
    pub fn fixed(max_attempts: u32, delay: Duration) -> Self {
        Self {
            max_attempts,
            base_delay: delay,
            max_delay: delay,
            backoff: BackoffKind::Fixed,
            retry_on: RetryCondition::Combined,
        }
    }

    fn should_retry_status(&self, status: u16) -> bool {
        match self.retry_on {
            RetryCondition::Network => false,
            RetryCondition::Status5xx => (500..600).contains(&status),
            RetryCondition::TooManyRequests => status == 429,
            RetryCondition::Combined => status == 429 || (500..600).contains(&status),
        }
    }

    fn should_retry_network(&self) -> bool {
        matches!(
            self.retry_on,
            RetryCondition::Network | RetryCondition::Combined
        )
    }

    fn compute_delay(&self, attempt: u32) -> Duration {
        let base_ms = self.base_delay.as_millis() as f64;
        let raw_ms = match self.backoff {
            BackoffKind::Fixed => base_ms,
            BackoffKind::Exponential { factor } => {
                let exp = attempt.saturating_sub(1) as i32;
                base_ms * factor.powi(exp)
            }
        };
        let max_ms = self.max_delay.as_millis() as f64;
        let clamped = raw_ms.clamp(0.0, max_ms);
        Duration::from_millis(clamped as u64)
    }
}

/// リクエストを `policy` に従って再試行しながら実行する。
///
/// `request_fn` は呼ばれるたびに新しい `Future<Response>` を返す必要がある。
/// 成功 (2xx) なら `ensure_ok` 経由で `Response` を返す。
/// 5xx/429 の場合は (条件に合致すれば) バックオフして再試行する。
/// ネットワークエラーも条件に合致すれば再試行する。
pub async fn execute_with_retry<F, Fut>(policy: &RetryPolicy, mut request_fn: F) -> Result<Response>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = std::result::Result<Response, reqwest::Error>>,
{
    let max_attempts = policy.max_attempts.max(1);
    let mut attempt: u32 = 0;
    loop {
        attempt += 1;
        match request_fn().await {
            Ok(response) => {
                let status = response.status().as_u16();
                if attempt >= max_attempts || !policy.should_retry_status(status) {
                    return HttpClient::ensure_ok(response).await;
                }
                // Retry-After ヘッダがあれば優先 (秒単位の整数のみサポート)。
                let retry_after = response
                    .headers()
                    .get("retry-after")
                    .and_then(|v| v.to_str().ok())
                    .and_then(|s| s.parse::<u64>().ok())
                    .map(Duration::from_secs);
                drop(response);
                let delay = retry_after.unwrap_or_else(|| policy.compute_delay(attempt));
                tokio::time::sleep(delay).await;
            }
            Err(err) => {
                if attempt >= max_attempts || !policy.should_retry_network() {
                    return Err(FirebaseError::from(err));
                }
                tokio::time::sleep(policy.compute_delay(attempt)).await;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mockito::Server;

    fn fast_policy() -> RetryPolicy {
        RetryPolicy {
            max_attempts: 3,
            base_delay: Duration::from_millis(1),
            max_delay: Duration::from_millis(5),
            backoff: BackoffKind::Fixed,
            retry_on: RetryCondition::Combined,
        }
    }

    #[tokio::test]
    async fn retries_503_then_succeeds() {
        let mut server = Server::new_async().await;
        let path = "/retry-503";
        // mockito 1.x は登録順 (FIFO) でマッチし、`expect(n)` の上限到達後は
        // 次のモックに譲る。よって 503 を 2 回返した後 200 が応答する。
        let m_fail = server
            .mock("POST", path)
            .expect(2)
            .with_status(503)
            .with_body("busy")
            .create_async()
            .await;
        let m_ok = server
            .mock("POST", path)
            .expect(1)
            .with_status(200)
            .with_body("ok")
            .create_async()
            .await;

        let client = reqwest::Client::new();
        let url = format!("{}{}", server.url(), path);
        let response =
            execute_with_retry(&fast_policy(), || async { client.post(&url).send().await })
                .await
                .unwrap();
        assert!(response.status().is_success());
        let body = response.text().await.unwrap();
        assert_eq!(body, "ok");
        m_fail.assert_async().await;
        m_ok.assert_async().await;
    }

    #[tokio::test]
    async fn does_not_retry_4xx() {
        let mut server = Server::new_async().await;
        let path = "/no-retry-4xx";
        let m = server
            .mock("GET", path)
            .expect(1)
            .with_status(400)
            .with_header("content-type", "application/json")
            .with_body(r#"{"error":{"code":400,"message":"BAD"}}"#)
            .create_async()
            .await;

        let client = reqwest::Client::new();
        let url = format!("{}{}", server.url(), path);
        let err = execute_with_retry(&fast_policy(), || async { client.get(&url).send().await })
            .await
            .unwrap_err();
        match err {
            FirebaseError::Api { status, .. } => assert_eq!(status, 400),
            other => panic!("想定外: {other:?}"),
        }
        m.assert_async().await;
    }

    #[tokio::test]
    async fn gives_up_after_max_attempts() {
        let mut server = Server::new_async().await;
        let path = "/always-503";
        let m = server
            .mock("GET", path)
            .expect(3)
            .with_status(503)
            .with_body("nope")
            .create_async()
            .await;

        let client = reqwest::Client::new();
        let url = format!("{}{}", server.url(), path);
        let err = execute_with_retry(&fast_policy(), || async { client.get(&url).send().await })
            .await
            .unwrap_err();
        match err {
            FirebaseError::Api { status, .. } => assert_eq!(status, 503),
            other => panic!("想定外: {other:?}"),
        }
        m.assert_async().await;
    }

    #[test]
    fn exponential_backoff_caps_at_max_delay() {
        let policy = RetryPolicy {
            max_attempts: 5,
            base_delay: Duration::from_millis(100),
            max_delay: Duration::from_millis(800),
            backoff: BackoffKind::Exponential { factor: 2.0 },
            retry_on: RetryCondition::Combined,
        };
        // 1 → 100ms, 2 → 200ms, 3 → 400ms, 4 → 800ms (clamp), 5 → 800ms (clamp)
        assert_eq!(policy.compute_delay(1), Duration::from_millis(100));
        assert_eq!(policy.compute_delay(2), Duration::from_millis(200));
        assert_eq!(policy.compute_delay(3), Duration::from_millis(400));
        assert_eq!(policy.compute_delay(4), Duration::from_millis(800));
        assert_eq!(policy.compute_delay(5), Duration::from_millis(800));
    }
}
