// Firebase Cloud Messaging (FCM) REST クライアント。
// Why: WallBlank は受信側 (APNs 経由) が主用途だが、サーバー連携やテスト用途として
//      "送信" と "トピック購読管理" を Rust から扱える最小実装を提供する。
//      正規の HTTP v1 API は Service Account の OAuth2 アクセストークンを要求するが、
//      本フェーズでは AuthClient の id_token を Bearer に流用する簡易実装とする
//      (本番運用では Service Account JWT 署名 + access token 取得を後続フェーズで追加)。

use crate::auth::AuthClient;
use crate::config::FirebaseConfig;
use crate::error::{FirebaseError, Result};
use crate::http::HttpClient;
use serde::Serialize;
use std::collections::HashMap;

/// 送信通知ペイロード。
#[derive(Debug, Clone, Default)]
pub struct NotificationPayload {
    /// 通知タイトル
    pub title: String,
    /// 通知本文
    pub body: String,
    /// 任意の data フィールド (FCM の data メッセージとして送信)
    pub data: HashMap<String, String>,
}

impl NotificationPayload {
    /// タイトル + 本文だけの最小ペイロードを作る糖衣。
    pub fn simple(title: impl Into<String>, body: impl Into<String>) -> Self {
        Self {
            title: title.into(),
            body: body.into(),
            data: HashMap::new(),
        }
    }
}

/// FCM REST クライアント。
#[derive(Debug, Clone)]
pub struct MessagingClient {
    config: FirebaseConfig,
    http: HttpClient,
    auth: AuthClient,
}

impl MessagingClient {
    /// 新しい MessagingClient を構築する。
    pub fn new(config: FirebaseConfig, http: HttpClient, auth: AuthClient) -> Self {
        Self { config, http, auth }
    }

    /// 端末トークンを指定トピックにサブスクライブする (Instance ID API)。
    pub async fn subscribe_topic(&self, token: &str, topic: &str) -> Result<()> {
        let url = format!(
            "{}/iid/v1/{}/rel/topics/{}",
            self.config.iid_base,
            urlencoding::encode(token),
            urlencoding::encode(topic)
        );
        let bearer = self.auth.current_session().await?.id_token;
        let response = self
            .http
            .inner()
            .post(&url)
            .bearer_auth(&bearer)
            .header("Content-Length", "0")
            .send()
            .await
            .map_err(FirebaseError::from)?;
        HttpClient::ensure_ok(response).await?;
        Ok(())
    }

    /// 端末トークンを指定トピックからアンサブスクライブする。
    pub async fn unsubscribe_topic(&self, token: &str, topic: &str) -> Result<()> {
        let url = format!(
            "{}/iid/v1/{}/rel/topics/{}",
            self.config.iid_base,
            urlencoding::encode(token),
            urlencoding::encode(topic)
        );
        let bearer = self.auth.current_session().await?.id_token;
        let response = self
            .http
            .inner()
            .delete(&url)
            .bearer_auth(&bearer)
            .send()
            .await
            .map_err(FirebaseError::from)?;
        HttpClient::ensure_ok(response).await?;
        Ok(())
    }

    /// 単一端末トークン宛に通知を送信する (FCM HTTP v1)。
    pub async fn send_to_token(&self, token: &str, payload: NotificationPayload) -> Result<()> {
        let url = format!(
            "{}/v1/projects/{}/messages:send",
            self.config.fcm_base, self.config.project_id
        );
        let bearer = self.auth.current_session().await?.id_token;
        let body = SendRequest {
            message: SendMessage {
                token,
                notification: SendNotification {
                    title: &payload.title,
                    body: &payload.body,
                },
                data: &payload.data,
            },
        };
        let response = self
            .http
            .inner()
            .post(&url)
            .bearer_auth(&bearer)
            .json(&body)
            .send()
            .await
            .map_err(FirebaseError::from)?;
        HttpClient::ensure_ok(response).await?;
        Ok(())
    }
}

#[derive(Serialize)]
struct SendRequest<'a> {
    message: SendMessage<'a>,
}

#[derive(Serialize)]
struct SendMessage<'a> {
    token: &'a str,
    notification: SendNotification<'a>,
    #[serde(skip_serializing_if = "HashMap::is_empty")]
    data: &'a HashMap<String, String>,
}

#[derive(Serialize)]
struct SendNotification<'a> {
    title: &'a str,
    body: &'a str,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::AuthSession;
    use mockito::Server;
    use std::time::{Duration, SystemTime};

    fn config_for(server: &Server) -> FirebaseConfig {
        FirebaseConfig::new("artia-test", "fake-api-key", "artia-test.appspot.com")
            .unwrap()
            .with_endpoints_for_test(server.url())
    }

    async fn make_client(server: &Server) -> MessagingClient {
        let http = HttpClient::new().unwrap();
        let cfg = config_for(server);
        let auth = AuthClient::new(cfg.clone(), http.clone());
        auth.set_session(AuthSession {
            id_token: "tok-1".into(),
            refresh_token: "refresh-1".into(),
            local_id: "uid-1".into(),
            expires_at: SystemTime::now() + Duration::from_secs(3600),
        })
        .await;
        MessagingClient::new(cfg, http, auth)
    }

    #[tokio::test]
    async fn subscribe_topic_posts_to_iid() {
        let mut server = Server::new_async().await;
        let mock = server
            .mock("POST", "/iid/v1/dev-token/rel/topics/news")
            .match_header("authorization", "Bearer tok-1")
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body("{}")
            .create_async()
            .await;
        let client = make_client(&server).await;
        client.subscribe_topic("dev-token", "news").await.unwrap();
        mock.assert_async().await;
    }

    #[tokio::test]
    async fn unsubscribe_topic_deletes_iid() {
        let mut server = Server::new_async().await;
        let mock = server
            .mock("DELETE", "/iid/v1/dev-token/rel/topics/news")
            .match_header("authorization", "Bearer tok-1")
            .with_status(200)
            .with_body("{}")
            .create_async()
            .await;
        let client = make_client(&server).await;
        client.unsubscribe_topic("dev-token", "news").await.unwrap();
        mock.assert_async().await;
    }

    #[tokio::test]
    async fn send_to_token_posts_v1_messages_send() {
        let mut server = Server::new_async().await;
        let mock = server
            .mock("POST", "/v1/projects/artia-test/messages:send")
            .match_header("authorization", "Bearer tok-1")
            .match_body(mockito::Matcher::PartialJsonString(
                r#"{"message":{"token":"dev-token","notification":{"title":"Hi","body":"There"}}}"#
                    .into(),
            ))
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(r#"{"name":"projects/artia-test/messages/abc"}"#)
            .create_async()
            .await;
        let client = make_client(&server).await;
        client
            .send_to_token("dev-token", NotificationPayload::simple("Hi", "There"))
            .await
            .unwrap();
        mock.assert_async().await;
    }

    #[tokio::test]
    async fn send_to_token_surfaces_api_error() {
        let mut server = Server::new_async().await;
        let _mock = server
            .mock("POST", "/v1/projects/artia-test/messages:send")
            .with_status(404)
            .with_header("content-type", "application/json")
            .with_body(r#"{"error":{"code":404,"message":"NOT_FOUND"}}"#)
            .create_async()
            .await;
        let client = make_client(&server).await;
        let err = client
            .send_to_token("missing-token", NotificationPayload::simple("a", "b"))
            .await
            .unwrap_err();
        match err {
            FirebaseError::Api { status, message } => {
                assert_eq!(status, 404);
                assert!(message.contains("NOT_FOUND"));
            }
            other => panic!("想定外: {other:?}"),
        }
    }
}
