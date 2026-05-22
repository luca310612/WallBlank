// Firebase Auth REST クライアント。
// Why: SDK を使わずに Identity Toolkit / Secure Token API を直接叩くことで、Rust 側だけで
//      ID トークンの取得・更新を完結させ、Swift 側の依存を Firebase SDK から減らす。

use crate::config::FirebaseConfig;
use crate::error::{FirebaseError, Result};
use crate::http::HttpClient;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::time::{Duration, SystemTime};
use tokio::sync::Mutex;

/// 認証セッション。ID トークンとリフレッシュトークン、有効期限を保持する。
#[derive(Debug, Clone)]
pub struct AuthSession {
    /// Firebase ID トークン (JWT)
    pub id_token: String,
    /// リフレッシュトークン
    pub refresh_token: String,
    /// Firebase ローカル ID (uid)
    pub local_id: String,
    /// ID トークンの有効期限 (絶対時刻)
    pub expires_at: SystemTime,
}

impl AuthSession {
    /// expires_at までの残り時間が閾値より少ないか。
    pub fn expires_within(&self, threshold: Duration) -> bool {
        match self.expires_at.duration_since(SystemTime::now()) {
            Ok(remaining) => remaining <= threshold,
            Err(_) => true, // 既に期限切れ
        }
    }
}

/// Firebase Auth REST クライアント。
///
/// 内部で最新の `AuthSession` を保持し、`current_session()` 取得時に
/// 期限が 5 分以内なら自動で `refresh_id_token` を呼び出す。
#[derive(Debug, Clone)]
pub struct AuthClient {
    config: FirebaseConfig,
    http: HttpClient,
    session: Arc<Mutex<Option<AuthSession>>>,
}

impl AuthClient {
    /// 新しい AuthClient を構築する。セッションは未設定。
    pub fn new(config: FirebaseConfig, http: HttpClient) -> Self {
        Self {
            config,
            http,
            session: Arc::new(Mutex::new(None)),
        }
    }

    /// カスタムトークンでサインインし、セッションを保存して返す。
    pub async fn sign_in_with_custom_token(&self, custom_token: &str) -> Result<AuthSession> {
        let url = format!(
            "{}/v1/accounts:signInWithCustomToken?key={}",
            self.config.identity_toolkit_base, self.config.api_key
        );
        let body = SignInWithCustomTokenRequest {
            token: custom_token,
            return_secure_token: true,
        };
        let response = self
            .http
            .inner()
            .post(&url)
            .json(&body)
            .send()
            .await
            .map_err(FirebaseError::from)?;
        let response = HttpClient::ensure_ok(response).await?;
        let parsed: SignInWithCustomTokenResponse = response.json().await?;
        let session = parsed.into_session()?;
        self.store_session(session.clone()).await;
        Ok(session)
    }

    /// 匿名サインインでセッションを取得する。
    pub async fn sign_in_anonymously(&self) -> Result<AuthSession> {
        let url = format!(
            "{}/v1/accounts:signUp?key={}",
            self.config.identity_toolkit_base, self.config.api_key
        );
        let body = SignUpAnonymousRequest {
            return_secure_token: true,
        };
        let response = self
            .http
            .inner()
            .post(&url)
            .json(&body)
            .send()
            .await
            .map_err(FirebaseError::from)?;
        let response = HttpClient::ensure_ok(response).await?;
        let parsed: SignInWithCustomTokenResponse = response.json().await?;
        let session = parsed.into_session()?;
        self.store_session(session.clone()).await;
        Ok(session)
    }

    /// リフレッシュトークンを使って ID トークンを更新する。
    pub async fn refresh_id_token(&self, refresh_token: &str) -> Result<AuthSession> {
        let url = format!(
            "{}/v1/token?key={}",
            self.config.secure_token_base, self.config.api_key
        );
        let form = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh_token),
        ];
        let response = self
            .http
            .inner()
            .post(&url)
            .form(&form)
            .send()
            .await
            .map_err(FirebaseError::from)?;
        let response = HttpClient::ensure_ok(response).await?;
        let parsed: RefreshTokenResponse = response.json().await?;
        let session = parsed.into_session()?;
        self.store_session(session.clone()).await;
        Ok(session)
    }

    /// 現在のセッションを返す。期限が 5 分以内なら自動的にリフレッシュする。
    pub async fn current_session(&self) -> Result<AuthSession> {
        let snapshot = self.session.lock().await.clone();
        let Some(session) = snapshot else {
            return Err(FirebaseError::Auth(
                "セッション未確立。先に sign_in_* を呼び出してください".to_string(),
            ));
        };
        if session.expires_within(Duration::from_secs(5 * 60)) {
            self.refresh_id_token(&session.refresh_token).await
        } else {
            Ok(session)
        }
    }

    /// 外部で取得済みのセッションを直接設定する (テスト・復元用)。
    pub async fn set_session(&self, session: AuthSession) {
        self.store_session(session).await;
    }

    async fn store_session(&self, session: AuthSession) {
        let mut guard = self.session.lock().await;
        *guard = Some(session);
    }
}

#[derive(Serialize)]
struct SignInWithCustomTokenRequest<'a> {
    token: &'a str,
    #[serde(rename = "returnSecureToken")]
    return_secure_token: bool,
}

#[derive(Serialize)]
struct SignUpAnonymousRequest {
    #[serde(rename = "returnSecureToken")]
    return_secure_token: bool,
}

#[derive(Deserialize)]
struct SignInWithCustomTokenResponse {
    #[serde(rename = "idToken")]
    id_token: String,
    #[serde(rename = "refreshToken")]
    refresh_token: String,
    #[serde(rename = "expiresIn")]
    expires_in: String,
    #[serde(rename = "localId")]
    local_id: String,
}

impl SignInWithCustomTokenResponse {
    fn into_session(self) -> Result<AuthSession> {
        let expires_in: u64 = self
            .expires_in
            .parse()
            .map_err(|e| FirebaseError::Auth(format!("expiresIn 解析失敗: {e}")))?;
        Ok(AuthSession {
            id_token: self.id_token,
            refresh_token: self.refresh_token,
            local_id: self.local_id,
            expires_at: SystemTime::now() + Duration::from_secs(expires_in),
        })
    }
}

#[derive(Deserialize)]
struct RefreshTokenResponse {
    #[serde(rename = "id_token")]
    id_token: String,
    #[serde(rename = "refresh_token")]
    refresh_token: String,
    #[serde(rename = "expires_in")]
    expires_in: String,
    #[serde(rename = "user_id")]
    user_id: String,
}

impl RefreshTokenResponse {
    fn into_session(self) -> Result<AuthSession> {
        let expires_in: u64 = self
            .expires_in
            .parse()
            .map_err(|e| FirebaseError::Auth(format!("expires_in 解析失敗: {e}")))?;
        Ok(AuthSession {
            id_token: self.id_token,
            refresh_token: self.refresh_token,
            local_id: self.user_id,
            expires_at: SystemTime::now() + Duration::from_secs(expires_in),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mockito::Server;

    fn config_for(server: &Server) -> FirebaseConfig {
        FirebaseConfig::new("artia-test", "fake-api-key", "artia-test.appspot.com")
            .unwrap()
            .with_endpoints_for_test(server.url())
    }

    #[tokio::test]
    async fn sign_in_with_custom_token_parses_session() {
        let mut server = Server::new_async().await;
        let mock = server
            .mock("POST", "/v1/accounts:signInWithCustomToken")
            .match_query(mockito::Matcher::UrlEncoded(
                "key".into(),
                "fake-api-key".into(),
            ))
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(
                r#"{
                  "idToken": "id-1",
                  "refreshToken": "refresh-1",
                  "expiresIn": "3600",
                  "localId": "uid-1"
                }"#,
            )
            .create_async()
            .await;

        let http = HttpClient::new().unwrap();
        let auth = AuthClient::new(config_for(&server), http);

        let session = auth.sign_in_with_custom_token("ct").await.unwrap();
        assert_eq!(session.id_token, "id-1");
        assert_eq!(session.refresh_token, "refresh-1");
        assert_eq!(session.local_id, "uid-1");
        assert!(!session.expires_within(Duration::from_secs(60)));
        mock.assert_async().await;

        // current_session は十分余裕があるのでリフレッシュ不要
        let again = auth.current_session().await.unwrap();
        assert_eq!(again.id_token, "id-1");
    }

    #[tokio::test]
    async fn refresh_id_token_replaces_session() {
        let mut server = Server::new_async().await;
        let mock = server
            .mock("POST", "/v1/token")
            .match_query(mockito::Matcher::UrlEncoded(
                "key".into(),
                "fake-api-key".into(),
            ))
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(
                r#"{
                  "id_token": "id-2",
                  "refresh_token": "refresh-2",
                  "expires_in": "3600",
                  "user_id": "uid-1"
                }"#,
            )
            .create_async()
            .await;

        let http = HttpClient::new().unwrap();
        let auth = AuthClient::new(config_for(&server), http);
        let session = auth.refresh_id_token("old-refresh").await.unwrap();
        assert_eq!(session.id_token, "id-2");
        assert_eq!(session.refresh_token, "refresh-2");
        mock.assert_async().await;
    }

    #[tokio::test]
    async fn current_session_auto_refreshes_when_near_expiry() {
        let mut server = Server::new_async().await;
        let refresh_mock = server
            .mock("POST", "/v1/token")
            .match_query(mockito::Matcher::UrlEncoded(
                "key".into(),
                "fake-api-key".into(),
            ))
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(
                r#"{
                  "id_token": "id-fresh",
                  "refresh_token": "refresh-fresh",
                  "expires_in": "3600",
                  "user_id": "uid-x"
                }"#,
            )
            .create_async()
            .await;

        let http = HttpClient::new().unwrap();
        let auth = AuthClient::new(config_for(&server), http);

        // 期限ギリギリ (60 秒後) の偽セッションをセット
        auth.set_session(AuthSession {
            id_token: "id-old".into(),
            refresh_token: "refresh-old".into(),
            local_id: "uid-x".into(),
            expires_at: SystemTime::now() + Duration::from_secs(60),
        })
        .await;

        let refreshed = auth.current_session().await.unwrap();
        assert_eq!(refreshed.id_token, "id-fresh");
        refresh_mock.assert_async().await;
    }

    #[tokio::test]
    async fn sign_in_anonymously_parses_session() {
        let mut server = Server::new_async().await;
        let mock = server
            .mock("POST", "/v1/accounts:signUp")
            .match_query(mockito::Matcher::UrlEncoded(
                "key".into(),
                "fake-api-key".into(),
            ))
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(
                r#"{
                  "idToken": "anon-id",
                  "refreshToken": "anon-refresh",
                  "expiresIn": "3600",
                  "localId": "anon-uid"
                }"#,
            )
            .create_async()
            .await;

        let http = HttpClient::new().unwrap();
        let auth = AuthClient::new(config_for(&server), http);
        let session = auth.sign_in_anonymously().await.unwrap();
        assert_eq!(session.local_id, "anon-uid");
        mock.assert_async().await;
    }

    #[tokio::test]
    async fn api_error_is_surfaced_with_message() {
        let mut server = Server::new_async().await;
        let _mock = server
            .mock("POST", "/v1/accounts:signInWithCustomToken")
            .match_query(mockito::Matcher::Any)
            .with_status(400)
            .with_header("content-type", "application/json")
            .with_body(r#"{"error":{"code":400,"message":"INVALID_CUSTOM_TOKEN"}}"#)
            .create_async()
            .await;

        let http = HttpClient::new().unwrap();
        let auth = AuthClient::new(config_for(&server), http);
        let err = auth.sign_in_with_custom_token("bad").await.unwrap_err();
        match err {
            FirebaseError::Api { status, message } => {
                assert_eq!(status, 400);
                assert!(message.contains("INVALID_CUSTOM_TOKEN"));
            }
            other => panic!("想定外のエラー: {other:?}"),
        }
    }
}
