// Firebase Storage REST クライアント。
// Why: Firebase SDK を排し、`firebasestorage.googleapis.com` の REST API を直接叩いて
//      アップロード／ダウンロード／削除／メタデータ取得を行う。

use crate::auth::AuthClient;
use crate::cache::Cache;
use crate::config::FirebaseConfig;
use crate::error::{FirebaseError, Result};
use crate::http::HttpClient;
use serde::Deserialize;

/// Firebase Storage 上のオブジェクトを表す簡易メタデータ。
#[derive(Debug, Clone, Deserialize)]
pub struct StorageObject {
    /// バケット名 (例: `artia-app.appspot.com`)
    pub bucket: String,
    /// オブジェクト名 (パス。例: `users/uid/foo.png`)
    pub name: String,
    /// MIME タイプ
    #[serde(rename = "contentType", default)]
    pub content_type: Option<String>,
    /// バイトサイズ (REST API は文字列で返すので String のまま保持)
    #[serde(default)]
    pub size: Option<String>,
    /// ETag
    #[serde(default)]
    pub etag: Option<String>,
    /// ダウンロードトークン (`firebaseStorageDownloadTokens`)
    #[serde(rename = "downloadTokens", default)]
    pub download_tokens: Option<String>,
}

/// Firebase Storage REST クライアント。
///
/// 認証は `AuthClient::current_session()` から取得した `id_token` を Bearer 認証で付与する。
#[derive(Debug, Clone)]
pub struct StorageClient {
    config: FirebaseConfig,
    http: HttpClient,
    auth: AuthClient,
    cache: Option<Cache>,
}

impl StorageClient {
    /// 新しい StorageClient を構築する (キャッシュなし)。
    pub fn new(config: FirebaseConfig, http: HttpClient, auth: AuthClient) -> Self {
        Self {
            config,
            http,
            auth,
            cache: None,
        }
    }

    /// オフラインキャッシュを取り付ける。
    /// Why: ネットワーク失敗時に直近成功した download バイト列を返せるよう、
    ///      download / delete の経路でフォールバック・無効化する。
    pub fn with_cache(mut self, cache: Cache) -> Self {
        self.cache = Some(cache);
        self
    }

    /// 取り付けてあるキャッシュへの参照。
    pub fn cache(&self) -> Option<&Cache> {
        self.cache.as_ref()
    }

    /// バイト列をアップロードする。`path` は `users/uid/foo.png` のような論理パス。
    pub async fn upload(
        &self,
        path: &str,
        bytes: Vec<u8>,
        content_type: &str,
    ) -> Result<StorageObject> {
        let url = format!(
            "{}/v0/b/{}/o?name={}&uploadType=media",
            self.config.storage_base,
            self.config.storage_bucket,
            urlencoding::encode(path)
        );
        let token = self.auth.current_session().await?.id_token;
        let response = self
            .http
            .inner()
            .post(&url)
            .bearer_auth(&token)
            .header("Content-Type", content_type)
            .body(bytes)
            .send()
            .await
            .map_err(FirebaseError::from)?;
        let response = HttpClient::ensure_ok(response).await?;
        let object: StorageObject = response.json().await?;
        Ok(object)
    }

    /// オブジェクトのバイト列をダウンロードする。
    /// `with_cache` 設定済みなら成功時に書き戻し、ネットワーク失敗時は cache をフォールバックとして返す。
    pub async fn download(&self, path: &str) -> Result<Vec<u8>> {
        match self.fetch_bytes_remote(path).await {
            Ok(bytes) => {
                if let Some(cache) = &self.cache {
                    cache.put_storage_cached(path, &bytes);
                }
                Ok(bytes)
            }
            Err(err) => {
                if let Some(cache) = &self.cache {
                    if let Some(cached) = cache.get_storage_cached(path) {
                        log::warn!("Storage download 失敗→キャッシュにフォールバック: {err}");
                        return Ok(cached);
                    }
                }
                Err(err)
            }
        }
    }

    async fn fetch_bytes_remote(&self, path: &str) -> Result<Vec<u8>> {
        let url = format!(
            "{}/v0/b/{}/o/{}?alt=media",
            self.config.storage_base,
            self.config.storage_bucket,
            urlencoding::encode(path)
        );
        let token = self.auth.current_session().await?.id_token;
        let response = self
            .http
            .inner()
            .get(&url)
            .bearer_auth(&token)
            .send()
            .await
            .map_err(FirebaseError::from)?;
        let response = HttpClient::ensure_ok(response).await?;
        let bytes = response.bytes().await.map_err(FirebaseError::from)?;
        Ok(bytes.to_vec())
    }

    /// オブジェクトを削除する。キャッシュ済みなら併せて破棄する。
    pub async fn delete(&self, path: &str) -> Result<()> {
        let url = format!(
            "{}/v0/b/{}/o/{}",
            self.config.storage_base,
            self.config.storage_bucket,
            urlencoding::encode(path)
        );
        let token = self.auth.current_session().await?.id_token;
        let response = self
            .http
            .inner()
            .delete(&url)
            .bearer_auth(&token)
            .send()
            .await
            .map_err(FirebaseError::from)?;
        HttpClient::ensure_ok(response).await?;
        if let Some(cache) = &self.cache {
            cache.invalidate_storage(path);
        }
        Ok(())
    }

    /// オブジェクトのメタデータのみを取得する (バイト列はダウンロードしない)。
    pub async fn metadata(&self, path: &str) -> Result<StorageObject> {
        let url = format!(
            "{}/v0/b/{}/o/{}",
            self.config.storage_base,
            self.config.storage_bucket,
            urlencoding::encode(path)
        );
        let token = self.auth.current_session().await?.id_token;
        let response = self
            .http
            .inner()
            .get(&url)
            .bearer_auth(&token)
            .send()
            .await
            .map_err(FirebaseError::from)?;
        let response = HttpClient::ensure_ok(response).await?;
        let object: StorageObject = response.json().await?;
        Ok(object)
    }
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

    async fn make_clients(server: &Server) -> (HttpClient, AuthClient, StorageClient) {
        let http = HttpClient::new().unwrap();
        let cfg = config_for(server);
        let auth = AuthClient::new(cfg.clone(), http.clone());
        // テスト用に有効期限十分な偽セッションをセット
        auth.set_session(AuthSession {
            id_token: "tok-1".into(),
            refresh_token: "refresh-1".into(),
            local_id: "uid-1".into(),
            expires_at: SystemTime::now() + Duration::from_secs(3600),
        })
        .await;
        let storage = StorageClient::new(cfg, http.clone(), auth.clone());
        (http, auth, storage)
    }

    #[tokio::test]
    async fn upload_sends_bearer_and_returns_object() {
        let mut server = Server::new_async().await;
        let mock = server
            .mock("POST", "/v0/b/artia-test.appspot.com/o")
            .match_query(mockito::Matcher::AllOf(vec![
                mockito::Matcher::UrlEncoded("name".into(), "users/uid-1/foo.png".into()),
                mockito::Matcher::UrlEncoded("uploadType".into(), "media".into()),
            ]))
            .match_header("authorization", "Bearer tok-1")
            .match_header("content-type", "image/png")
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(
                r#"{
                  "bucket": "artia-test.appspot.com",
                  "name": "users/uid-1/foo.png",
                  "contentType": "image/png",
                  "size": "4",
                  "downloadTokens": "tok-abc"
                }"#,
            )
            .create_async()
            .await;

        let (_http, _auth, storage) = make_clients(&server).await;
        let object = storage
            .upload("users/uid-1/foo.png", vec![1, 2, 3, 4], "image/png")
            .await
            .unwrap();
        assert_eq!(object.name, "users/uid-1/foo.png");
        assert_eq!(object.bucket, "artia-test.appspot.com");
        assert_eq!(object.download_tokens.as_deref(), Some("tok-abc"));
        mock.assert_async().await;
    }

    #[tokio::test]
    async fn download_returns_bytes() {
        let mut server = Server::new_async().await;
        let mock = server
            .mock(
                "GET",
                "/v0/b/artia-test.appspot.com/o/users%2Fuid-1%2Ffoo.png",
            )
            .match_query(mockito::Matcher::UrlEncoded("alt".into(), "media".into()))
            .match_header("authorization", "Bearer tok-1")
            .with_status(200)
            .with_header("content-type", "image/png")
            .with_body(vec![0xDE, 0xAD, 0xBE, 0xEF])
            .create_async()
            .await;

        let (_http, _auth, storage) = make_clients(&server).await;
        let bytes = storage.download("users/uid-1/foo.png").await.unwrap();
        assert_eq!(bytes, vec![0xDE, 0xAD, 0xBE, 0xEF]);
        mock.assert_async().await;
    }

    #[tokio::test]
    async fn delete_returns_ok_on_204() {
        let mut server = Server::new_async().await;
        let mock = server
            .mock(
                "DELETE",
                "/v0/b/artia-test.appspot.com/o/users%2Fuid-1%2Ffoo.png",
            )
            .match_header("authorization", "Bearer tok-1")
            .with_status(204)
            .create_async()
            .await;

        let (_http, _auth, storage) = make_clients(&server).await;
        storage.delete("users/uid-1/foo.png").await.unwrap();
        mock.assert_async().await;
    }

    #[tokio::test]
    async fn metadata_parses_object() {
        let mut server = Server::new_async().await;
        let mock = server
            .mock(
                "GET",
                "/v0/b/artia-test.appspot.com/o/users%2Fuid-1%2Ffoo.png",
            )
            .match_header("authorization", "Bearer tok-1")
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(
                r#"{
                  "bucket": "artia-test.appspot.com",
                  "name": "users/uid-1/foo.png",
                  "contentType": "image/png",
                  "size": "4",
                  "etag": "abc"
                }"#,
            )
            .create_async()
            .await;

        let (_http, _auth, storage) = make_clients(&server).await;
        let meta = storage.metadata("users/uid-1/foo.png").await.unwrap();
        assert_eq!(meta.size.as_deref(), Some("4"));
        assert_eq!(meta.etag.as_deref(), Some("abc"));
        mock.assert_async().await;
    }

    #[tokio::test]
    async fn download_falls_back_to_cache_on_failure() {
        let mut server = Server::new_async().await;
        let path = "/v0/b/artia-test.appspot.com/o/users%2Fuid-1%2Ffoo.png";
        let _m_ok = server
            .mock("GET", path)
            .match_query(mockito::Matcher::UrlEncoded("alt".into(), "media".into()))
            .expect(1)
            .with_status(200)
            .with_header("content-type", "image/png")
            .with_body(vec![0xDE, 0xAD, 0xBE, 0xEF])
            .create_async()
            .await;
        let _m_fail = server
            .mock("GET", path)
            .match_query(mockito::Matcher::UrlEncoded("alt".into(), "media".into()))
            .with_status(503)
            .with_body("oops")
            .create_async()
            .await;

        let dir = tempfile::tempdir().unwrap();
        let cache = crate::cache::Cache::new(dir.path().to_path_buf()).unwrap();
        let (_h, _a, storage) = make_clients(&server).await;
        let storage = storage.with_cache(cache);

        let first = storage.download("users/uid-1/foo.png").await.unwrap();
        assert_eq!(first, vec![0xDE, 0xAD, 0xBE, 0xEF]);

        let second = storage.download("users/uid-1/foo.png").await.unwrap();
        assert_eq!(second, vec![0xDE, 0xAD, 0xBE, 0xEF]);
    }

    #[tokio::test]
    async fn upload_surfaces_api_error() {
        let mut server = Server::new_async().await;
        let _mock = server
            .mock("POST", "/v0/b/artia-test.appspot.com/o")
            .match_query(mockito::Matcher::Any)
            .with_status(403)
            .with_header("content-type", "application/json")
            .with_body(r#"{"error":{"code":403,"message":"Permission denied"}}"#)
            .create_async()
            .await;

        let (_http, _auth, storage) = make_clients(&server).await;
        let err = storage
            .upload("users/uid-1/forbidden.png", vec![1], "image/png")
            .await
            .unwrap_err();
        match err {
            FirebaseError::Api { status, message } => {
                assert_eq!(status, 403);
                assert!(message.contains("Permission denied"));
            }
            other => panic!("想定外のエラー: {other:?}"),
        }
    }
}
