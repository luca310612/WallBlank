// Firestore REST クライアント。
// Why: Firestore SDK 不使用で `firestore.googleapis.com` の REST API を直接叩く。
//      gRPC ベースの Listen は REST だけでは扱いづらいため、polling-based listener で代替する。

use crate::auth::AuthClient;
use crate::cache::Cache;
use crate::config::FirebaseConfig;
use crate::error::{FirebaseError, Result};
use crate::http::HttpClient;
use async_stream::stream;
use futures_util::Stream;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::time::Duration;

// ===== 値型 =====

/// Firestore のフィールド値 (Tagged JSON 形式)。
/// Why: Firestore REST は `{"stringValue": "..."}` のような Tagged Union で値を表現するため、
///      serde の internally tagged ではなく externally tagged なバリアント表現で対応する。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum FirestoreValue {
    /// `null`
    #[serde(rename = "nullValue")]
    Null(NullMarker),
    /// `bool`
    #[serde(rename = "booleanValue")]
    Boolean(bool),
    /// 整数 (REST 上は文字列として送受信される)
    #[serde(rename = "integerValue")]
    Integer(String),
    /// 浮動小数
    #[serde(rename = "doubleValue")]
    Double(f64),
    /// 文字列
    #[serde(rename = "stringValue")]
    String(String),
    /// RFC3339 形式のタイムスタンプ
    #[serde(rename = "timestampValue")]
    Timestamp(String),
    /// Base64 エンコードされたバイト列
    #[serde(rename = "bytesValue")]
    Bytes(String),
    /// 配列
    #[serde(rename = "arrayValue")]
    Array(ArrayValue),
    /// マップ
    #[serde(rename = "mapValue")]
    Map(MapValue),
    /// ドキュメント参照 (フルパス)
    #[serde(rename = "referenceValue")]
    Reference(String),
    /// 緯度経度
    #[serde(rename = "geoPointValue")]
    GeoPoint(GeoPoint),
}

/// `nullValue` 用の常に null となるマーカー。
/// Why: `serde_json::Value::Null` を直接埋めると Default が空マップになるため、
///      明示的なユニット型でラップする。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NullMarker;

impl Serialize for NullMarker {
    fn serialize<S: serde::Serializer>(&self, ser: S) -> std::result::Result<S::Ok, S::Error> {
        ser.serialize_none()
    }
}

impl<'de> Deserialize<'de> for NullMarker {
    fn deserialize<D: serde::Deserializer<'de>>(de: D) -> std::result::Result<Self, D::Error> {
        // null でも何でも受け入れる: Firestore は常に null を返す
        let _ = serde::de::IgnoredAny::deserialize(de)?;
        Ok(NullMarker)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct ArrayValue {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub values: Vec<FirestoreValue>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct MapValue {
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub fields: HashMap<String, FirestoreValue>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GeoPoint {
    pub latitude: f64,
    pub longitude: f64,
}

impl FirestoreValue {
    /// 文字列値を作る糖衣。
    pub fn string(s: impl Into<String>) -> Self {
        FirestoreValue::String(s.into())
    }
    /// 整数値 (i64) を作る糖衣。REST では文字列形式になる。
    pub fn integer(v: i64) -> Self {
        FirestoreValue::Integer(v.to_string())
    }
    /// bool 値を作る糖衣。
    pub fn boolean(v: bool) -> Self {
        FirestoreValue::Boolean(v)
    }
}

// ===== ドキュメント =====

/// Firestore ドキュメント。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Document {
    /// `projects/<id>/databases/(default)/documents/<col>/<doc_id>` 形式のフルパス
    pub name: String,
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub fields: HashMap<String, FirestoreValue>,
    #[serde(
        rename = "createTime",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub create_time: Option<String>,
    #[serde(
        rename = "updateTime",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub update_time: Option<String>,
}

/// `list_documents` のレスポンス。
#[derive(Debug, Clone, Deserialize, Default)]
pub struct DocumentList {
    #[serde(default)]
    pub documents: Vec<Document>,
    #[serde(rename = "nextPageToken", default)]
    pub next_page_token: Option<String>,
}

// ===== StructuredQuery =====

/// `runQuery` 用の最小限のクエリビルダ。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StructuredQuery {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<Vec<CollectionSelector>>,
    #[serde(
        rename = "where",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub where_filter: Option<Filter>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub order_by: Vec<Order>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CollectionSelector {
    pub collection_id: String,
    #[serde(default, skip_serializing_if = "is_false")]
    pub all_descendants: bool,
}

fn is_false(b: &bool) -> bool {
    !*b
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum Filter {
    #[serde(rename = "fieldFilter")]
    FieldFilter(FieldFilter),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FieldFilter {
    pub field: FieldReference,
    pub op: FieldOp,
    pub value: FirestoreValue,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FieldReference {
    pub field_path: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum FieldOp {
    Equal,
    NotEqual,
    LessThan,
    LessThanOrEqual,
    GreaterThan,
    GreaterThanOrEqual,
    ArrayContains,
    In,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Order {
    pub field: FieldReference,
    pub direction: Direction,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum Direction {
    Ascending,
    Descending,
}

impl StructuredQuery {
    /// 単一コレクション対象のクエリを作る。
    pub fn collection(collection_id: impl Into<String>) -> Self {
        Self {
            from: Some(vec![CollectionSelector {
                collection_id: collection_id.into(),
                all_descendants: false,
            }]),
            ..Default::default()
        }
    }

    /// 等価フィルタを 1 つ設定する。
    pub fn with_where_equal(
        mut self,
        field_path: impl Into<String>,
        value: FirestoreValue,
    ) -> Self {
        self.where_filter = Some(Filter::FieldFilter(FieldFilter {
            field: FieldReference {
                field_path: field_path.into(),
            },
            op: FieldOp::Equal,
            value,
        }));
        self
    }

    /// 並び順を 1 つ追加する。
    pub fn with_order_by(mut self, field_path: impl Into<String>, direction: Direction) -> Self {
        self.order_by.push(Order {
            field: FieldReference {
                field_path: field_path.into(),
            },
            direction,
        });
        self
    }

    /// 最大件数を設定する。
    pub fn with_limit(mut self, limit: u32) -> Self {
        self.limit = Some(limit);
        self
    }
}

// ===== クライアント =====

/// Firestore REST クライアント。
#[derive(Debug, Clone)]
pub struct FirestoreClient {
    config: FirebaseConfig,
    http: HttpClient,
    auth: AuthClient,
    cache: Option<Cache>,
}

impl FirestoreClient {
    /// 新しい FirestoreClient を構築する (キャッシュなし)。
    pub fn new(config: FirebaseConfig, http: HttpClient, auth: AuthClient) -> Self {
        Self {
            config,
            http,
            auth,
            cache: None,
        }
    }

    /// オフラインキャッシュを取り付ける。
    /// Why: ネットワーク失敗時に直近成功した値を返せるよう、
    ///      get_document の戻り経路でフォールバックさせる。
    pub fn with_cache(mut self, cache: Cache) -> Self {
        self.cache = Some(cache);
        self
    }

    /// 取り付けてあるキャッシュへの参照。
    pub fn cache(&self) -> Option<&Cache> {
        self.cache.as_ref()
    }

    fn documents_base(&self) -> String {
        format!(
            "{}/v1/projects/{}/databases/(default)/documents",
            self.config.firestore_base, self.config.project_id
        )
    }

    /// ドキュメントを取得する。
    /// `with_cache` が設定されていれば成功時に書き戻し、ネットワーク失敗時は cache をフォールバックとして返す。
    pub async fn get_document(&self, collection: &str, doc_id: &str) -> Result<Document> {
        match self.fetch_document_remote(collection, doc_id).await {
            Ok(doc) => {
                if let Some(cache) = &self.cache {
                    cache.put_document_cached(collection, doc_id, &doc);
                }
                Ok(doc)
            }
            Err(err) => {
                if let Some(cache) = &self.cache {
                    if let Some(cached) = cache.get_document_cached(collection, doc_id) {
                        log::warn!("Firestore get_document 失敗→キャッシュにフォールバック: {err}");
                        return Ok(cached);
                    }
                }
                Err(err)
            }
        }
    }

    async fn fetch_document_remote(&self, collection: &str, doc_id: &str) -> Result<Document> {
        let url = format!(
            "{}/{}/{}",
            self.documents_base(),
            urlencoding::encode(collection),
            urlencoding::encode(doc_id)
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
        let doc: Document = response.json().await?;
        Ok(doc)
    }

    /// 新規ドキュメントを作成する。`doc_id` を指定すれば任意の ID で作る。
    pub async fn create_document(
        &self,
        collection: &str,
        doc_id: Option<&str>,
        fields: HashMap<String, FirestoreValue>,
    ) -> Result<Document> {
        let mut url = format!(
            "{}/{}",
            self.documents_base(),
            urlencoding::encode(collection)
        );
        if let Some(id) = doc_id {
            url.push_str("?documentId=");
            url.push_str(&urlencoding::encode(id));
        }
        let body = DocumentBody { fields };
        let token = self.auth.current_session().await?.id_token;
        let response = self
            .http
            .inner()
            .post(&url)
            .bearer_auth(&token)
            .json(&body)
            .send()
            .await
            .map_err(FirebaseError::from)?;
        let response = HttpClient::ensure_ok(response).await?;
        let doc: Document = response.json().await?;
        Ok(doc)
    }

    /// 既存ドキュメントを部分/全更新する。`update_mask` を指定するとそのフィールドのみ更新。
    pub async fn update_document(
        &self,
        collection: &str,
        doc_id: &str,
        fields: HashMap<String, FirestoreValue>,
        update_mask: Option<Vec<String>>,
    ) -> Result<Document> {
        let mut url = format!(
            "{}/{}/{}",
            self.documents_base(),
            urlencoding::encode(collection),
            urlencoding::encode(doc_id)
        );
        if let Some(paths) = update_mask {
            // updateMask.fieldPaths=foo&updateMask.fieldPaths=bar 形式
            let parts: Vec<String> = paths
                .iter()
                .map(|p| format!("updateMask.fieldPaths={}", urlencoding::encode(p)))
                .collect();
            if !parts.is_empty() {
                url.push('?');
                url.push_str(&parts.join("&"));
            }
        }
        let body = DocumentBody { fields };
        let token = self.auth.current_session().await?.id_token;
        let response = self
            .http
            .inner()
            .patch(&url)
            .bearer_auth(&token)
            .json(&body)
            .send()
            .await
            .map_err(FirebaseError::from)?;
        let response = HttpClient::ensure_ok(response).await?;
        let doc: Document = response.json().await?;
        Ok(doc)
    }

    /// ドキュメントを削除する。キャッシュ済みであれば併せて破棄する。
    pub async fn delete_document(&self, collection: &str, doc_id: &str) -> Result<()> {
        let url = format!(
            "{}/{}/{}",
            self.documents_base(),
            urlencoding::encode(collection),
            urlencoding::encode(doc_id)
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
            cache.invalidate_document(collection, doc_id);
        }
        Ok(())
    }

    /// `runQuery` を実行し、ヒットしたドキュメント列を返す。
    /// `parent` は documents 配下の相対パス (空文字列ならルート)。
    pub async fn run_query(&self, parent: &str, query: StructuredQuery) -> Result<Vec<Document>> {
        let url = if parent.is_empty() {
            format!("{}:runQuery", self.documents_base())
        } else {
            format!("{}/{}:runQuery", self.documents_base(), parent)
        };
        let body = RunQueryRequest {
            structured_query: query,
        };
        let token = self.auth.current_session().await?.id_token;
        let response = self
            .http
            .inner()
            .post(&url)
            .bearer_auth(&token)
            .json(&body)
            .send()
            .await
            .map_err(FirebaseError::from)?;
        let response = HttpClient::ensure_ok(response).await?;
        let items: Vec<RunQueryItem> = response.json().await?;
        Ok(items.into_iter().filter_map(|i| i.document).collect())
    }

    /// コレクション内のドキュメントをページング取得する。
    pub async fn list_documents(
        &self,
        collection: &str,
        page_size: Option<u32>,
        page_token: Option<String>,
    ) -> Result<DocumentList> {
        let mut url = format!(
            "{}/{}",
            self.documents_base(),
            urlencoding::encode(collection)
        );
        let mut query: Vec<String> = Vec::new();
        if let Some(size) = page_size {
            query.push(format!("pageSize={size}"));
        }
        if let Some(token) = page_token {
            query.push(format!("pageToken={}", urlencoding::encode(&token)));
        }
        if !query.is_empty() {
            url.push('?');
            url.push_str(&query.join("&"));
        }
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
        let list: DocumentList = response.json().await?;
        Ok(list)
    }

    /// ドキュメントを `interval` ごとに polling し、`updateTime` が変化したら値を流す Stream。
    /// Why: Firestore Watch は gRPC ベースで REST 単独では扱いづらいため、
    ///      シンプルな polling で代替する。最初の取得結果は必ず 1 回流す。
    pub fn listen(
        &self,
        collection: &str,
        doc_id: &str,
        interval: Duration,
    ) -> impl Stream<Item = Result<Document>> {
        let client = self.clone();
        let collection = collection.to_string();
        let doc_id = doc_id.to_string();
        stream! {
            let mut last_update: Option<String> = None;
            loop {
                match client.get_document(&collection, &doc_id).await {
                    Ok(doc) => {
                        if doc.update_time != last_update {
                            last_update = doc.update_time.clone();
                            yield Ok(doc);
                        }
                    }
                    Err(e) => {
                        yield Err(e);
                    }
                }
                tokio::time::sleep(interval).await;
            }
        }
    }
}

// ===== 内部リクエスト/レスポンス型 =====

#[derive(Serialize)]
struct DocumentBody {
    fields: HashMap<String, FirestoreValue>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RunQueryRequest {
    structured_query: StructuredQuery,
}

#[derive(Deserialize)]
struct RunQueryItem {
    #[serde(default)]
    document: Option<Document>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::AuthSession;
    use futures_util::StreamExt;
    use mockito::Server;
    use std::time::SystemTime;

    fn config_for(server: &Server) -> FirebaseConfig {
        FirebaseConfig::new("artia-test", "fake-api-key", "artia-test.appspot.com")
            .unwrap()
            .with_endpoints_for_test(server.url())
    }

    async fn make_clients(server: &Server) -> (HttpClient, AuthClient, FirestoreClient) {
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
        let fs = FirestoreClient::new(cfg, http.clone(), auth.clone());
        (http, auth, fs)
    }

    fn sample_doc_json() -> &'static str {
        r#"{
            "name": "projects/artia-test/databases/(default)/documents/users/uid-1",
            "fields": {
                "displayName": {"stringValue": "Alice"},
                "age": {"integerValue": "30"},
                "active": {"booleanValue": true}
            },
            "createTime": "2026-01-01T00:00:00Z",
            "updateTime": "2026-05-01T12:00:00Z"
        }"#
    }

    #[tokio::test]
    async fn get_document_parses_typed_fields() {
        let mut server = Server::new_async().await;
        let mock = server
            .mock(
                "GET",
                "/v1/projects/artia-test/databases/(default)/documents/users/uid-1",
            )
            .match_header("authorization", "Bearer tok-1")
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(sample_doc_json())
            .create_async()
            .await;

        let (_h, _a, fs) = make_clients(&server).await;
        let doc = fs.get_document("users", "uid-1").await.unwrap();
        assert_eq!(
            doc.fields.get("displayName"),
            Some(&FirestoreValue::String("Alice".into()))
        );
        assert_eq!(
            doc.fields.get("age"),
            Some(&FirestoreValue::Integer("30".into()))
        );
        assert_eq!(
            doc.fields.get("active"),
            Some(&FirestoreValue::Boolean(true))
        );
        assert_eq!(doc.update_time.as_deref(), Some("2026-05-01T12:00:00Z"));
        mock.assert_async().await;
    }

    #[tokio::test]
    async fn create_document_with_doc_id_posts_with_query() {
        let mut server = Server::new_async().await;
        let mock = server
            .mock(
                "POST",
                "/v1/projects/artia-test/databases/(default)/documents/users",
            )
            .match_query(mockito::Matcher::UrlEncoded(
                "documentId".into(),
                "uid-1".into(),
            ))
            .match_header("authorization", "Bearer tok-1")
            .match_body(mockito::Matcher::PartialJsonString(
                r#"{"fields":{"displayName":{"stringValue":"Alice"}}}"#.into(),
            ))
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(sample_doc_json())
            .create_async()
            .await;

        let (_h, _a, fs) = make_clients(&server).await;
        let mut fields: HashMap<String, FirestoreValue> = HashMap::new();
        fields.insert("displayName".into(), FirestoreValue::string("Alice"));
        let doc = fs
            .create_document("users", Some("uid-1"), fields)
            .await
            .unwrap();
        assert!(doc.name.ends_with("users/uid-1"));
        mock.assert_async().await;
    }

    #[tokio::test]
    async fn update_document_with_mask_attaches_update_mask() {
        let mut server = Server::new_async().await;
        let mock = server
            .mock(
                "PATCH",
                "/v1/projects/artia-test/databases/(default)/documents/users/uid-1",
            )
            .match_query(mockito::Matcher::UrlEncoded(
                "updateMask.fieldPaths".into(),
                "displayName".into(),
            ))
            .match_header("authorization", "Bearer tok-1")
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(sample_doc_json())
            .create_async()
            .await;

        let (_h, _a, fs) = make_clients(&server).await;
        let mut fields: HashMap<String, FirestoreValue> = HashMap::new();
        fields.insert("displayName".into(), FirestoreValue::string("Bob"));
        let doc = fs
            .update_document("users", "uid-1", fields, Some(vec!["displayName".into()]))
            .await
            .unwrap();
        assert!(doc.name.contains("users/uid-1"));
        mock.assert_async().await;
    }

    #[tokio::test]
    async fn delete_document_returns_ok_on_204() {
        let mut server = Server::new_async().await;
        let mock = server
            .mock(
                "DELETE",
                "/v1/projects/artia-test/databases/(default)/documents/users/uid-1",
            )
            .match_header("authorization", "Bearer tok-1")
            .with_status(204)
            .create_async()
            .await;

        let (_h, _a, fs) = make_clients(&server).await;
        fs.delete_document("users", "uid-1").await.unwrap();
        mock.assert_async().await;
    }

    #[tokio::test]
    async fn run_query_returns_documents() {
        let mut server = Server::new_async().await;
        let body = format!(
            r#"[
                {{"document": {}, "readTime": "2026-05-01T12:00:00Z"}},
                {{"readTime": "2026-05-01T12:00:00Z"}}
            ]"#,
            sample_doc_json()
        );
        let mock = server
            .mock(
                "POST",
                "/v1/projects/artia-test/databases/(default)/documents:runQuery",
            )
            .match_header("authorization", "Bearer tok-1")
            .match_body(mockito::Matcher::PartialJsonString(
                r#"{"structuredQuery":{"from":[{"collectionId":"users"}]}}"#.into(),
            ))
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(body)
            .create_async()
            .await;

        let (_h, _a, fs) = make_clients(&server).await;
        let query = StructuredQuery::collection("users")
            .with_where_equal("active", FirestoreValue::boolean(true))
            .with_order_by("createTime", Direction::Descending)
            .with_limit(10);
        let docs = fs.run_query("", query).await.unwrap();
        assert_eq!(docs.len(), 1);
        assert!(docs[0].name.ends_with("users/uid-1"));
        mock.assert_async().await;
    }

    #[tokio::test]
    async fn list_documents_passes_pagination_params() {
        let mut server = Server::new_async().await;
        let mock = server
            .mock(
                "GET",
                "/v1/projects/artia-test/databases/(default)/documents/users",
            )
            .match_query(mockito::Matcher::AllOf(vec![
                mockito::Matcher::UrlEncoded("pageSize".into(), "20".into()),
                mockito::Matcher::UrlEncoded("pageToken".into(), "abc".into()),
            ]))
            .match_header("authorization", "Bearer tok-1")
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(format!(
                r#"{{"documents":[{}],"nextPageToken":"next"}}"#,
                sample_doc_json()
            ))
            .create_async()
            .await;

        let (_h, _a, fs) = make_clients(&server).await;
        let list = fs
            .list_documents("users", Some(20), Some("abc".into()))
            .await
            .unwrap();
        assert_eq!(list.documents.len(), 1);
        assert_eq!(list.next_page_token.as_deref(), Some("next"));
        mock.assert_async().await;
    }

    #[tokio::test]
    async fn get_document_404_is_api_error() {
        let mut server = Server::new_async().await;
        let _mock = server
            .mock(
                "GET",
                "/v1/projects/artia-test/databases/(default)/documents/users/missing",
            )
            .with_status(404)
            .with_header("content-type", "application/json")
            .with_body(r#"{"error":{"code":404,"message":"NOT_FOUND"}}"#)
            .create_async()
            .await;

        let (_h, _a, fs) = make_clients(&server).await;
        let err = fs.get_document("users", "missing").await.unwrap_err();
        match err {
            FirebaseError::Api { status, message } => {
                assert_eq!(status, 404);
                assert!(message.contains("NOT_FOUND"));
            }
            other => panic!("想定外: {other:?}"),
        }
    }

    #[tokio::test]
    async fn get_document_401_surfaces_auth_error() {
        let mut server = Server::new_async().await;
        let _mock = server
            .mock(
                "GET",
                "/v1/projects/artia-test/databases/(default)/documents/users/uid-1",
            )
            .with_status(401)
            .with_header("content-type", "application/json")
            .with_body(r#"{"error":{"code":401,"message":"UNAUTHENTICATED"}}"#)
            .create_async()
            .await;

        let (_h, _a, fs) = make_clients(&server).await;
        let err = fs.get_document("users", "uid-1").await.unwrap_err();
        match err {
            FirebaseError::Api { status, .. } => assert_eq!(status, 401),
            other => panic!("想定外: {other:?}"),
        }
    }

    #[tokio::test]
    async fn firestore_value_serde_roundtrip() {
        let mut fields: HashMap<String, FirestoreValue> = HashMap::new();
        fields.insert("s".into(), FirestoreValue::string("hi"));
        fields.insert("i".into(), FirestoreValue::integer(42));
        fields.insert("b".into(), FirestoreValue::boolean(false));
        fields.insert("d".into(), FirestoreValue::Double(1.5));
        fields.insert("n".into(), FirestoreValue::Null(NullMarker));
        fields.insert(
            "arr".into(),
            FirestoreValue::Array(ArrayValue {
                values: vec![FirestoreValue::integer(1), FirestoreValue::integer(2)],
            }),
        );
        fields.insert(
            "geo".into(),
            FirestoreValue::GeoPoint(GeoPoint {
                latitude: 35.0,
                longitude: 139.0,
            }),
        );

        let json = serde_json::to_string(&fields).unwrap();
        let restored: HashMap<String, FirestoreValue> = serde_json::from_str(&json).unwrap();
        assert_eq!(fields, restored);
    }

    #[tokio::test]
    async fn get_document_falls_back_to_cache_on_failure() {
        let mut server = Server::new_async().await;
        let path = "/v1/projects/artia-test/databases/(default)/documents/users/uid-1";
        // 1 回目: 成功 → cache に保存される
        let _m_ok = server
            .mock("GET", path)
            .expect(1)
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(sample_doc_json())
            .create_async()
            .await;
        // 2 回目以降: 503 → cache フォールバックすべき
        let _m_fail = server
            .mock("GET", path)
            .with_status(503)
            .with_header("content-type", "application/json")
            .with_body(r#"{"error":{"code":503,"message":"unavailable"}}"#)
            .create_async()
            .await;

        let dir = tempfile::tempdir().unwrap();
        let cache = crate::cache::Cache::new(dir.path().to_path_buf()).unwrap();
        let (_h, _a, fs) = make_clients(&server).await;
        let fs = fs.with_cache(cache);

        // 1 回目: ネットワークから取得 + キャッシュ書き込み
        let first = fs.get_document("users", "uid-1").await.unwrap();
        assert_eq!(first.update_time.as_deref(), Some("2026-05-01T12:00:00Z"));

        // 2 回目: ネットワークは 503 だが cache から復元される
        let second = fs.get_document("users", "uid-1").await.unwrap();
        assert_eq!(second.update_time.as_deref(), Some("2026-05-01T12:00:00Z"));
    }

    #[tokio::test]
    async fn get_document_returns_error_when_no_cache() {
        let mut server = Server::new_async().await;
        let path = "/v1/projects/artia-test/databases/(default)/documents/users/uid-1";
        let _m = server
            .mock("GET", path)
            .with_status(503)
            .with_header("content-type", "application/json")
            .with_body(r#"{"error":{"code":503,"message":"unavailable"}}"#)
            .create_async()
            .await;

        let (_h, _a, fs) = make_clients(&server).await;
        let err = fs.get_document("users", "uid-1").await.unwrap_err();
        match err {
            FirebaseError::Api { status, .. } => assert_eq!(status, 503),
            other => panic!("想定外: {other:?}"),
        }
    }

    #[tokio::test]
    async fn listen_emits_initial_then_on_change() {
        let mut server = Server::new_async().await;
        // 1 回目と 2 回目: updateTime "T1" → 同じなので 1 件のみ
        // 3 回目以降: updateTime "T2" → 追加で 1 件
        let path = "/v1/projects/artia-test/databases/(default)/documents/users/uid-1";
        let body_t1 = r#"{
            "name": "projects/artia-test/databases/(default)/documents/users/uid-1",
            "fields": {},
            "updateTime": "2026-05-01T00:00:00Z"
        }"#;
        let body_t2 = r#"{
            "name": "projects/artia-test/databases/(default)/documents/users/uid-1",
            "fields": {},
            "updateTime": "2026-05-01T01:00:00Z"
        }"#;
        let _m1 = server
            .mock("GET", path)
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(body_t1)
            .expect(2)
            .create_async()
            .await;
        let _m2 = server
            .mock("GET", path)
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(body_t2)
            .expect_at_least(1)
            .create_async()
            .await;

        let (_h, _a, fs) = make_clients(&server).await;
        let stream = fs.listen("users", "uid-1", Duration::from_millis(20));
        futures_util::pin_mut!(stream);

        let first = stream.next().await.unwrap().unwrap();
        assert_eq!(first.update_time.as_deref(), Some("2026-05-01T00:00:00Z"));

        let second = stream.next().await.unwrap().unwrap();
        assert_eq!(second.update_time.as_deref(), Some("2026-05-01T01:00:00Z"));
    }
}
