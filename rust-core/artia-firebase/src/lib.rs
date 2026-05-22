// WallBlank Firebase REST API クライアント。
// Why: Firebase SDK を使わずに Auth (Identity Toolkit / Secure Token API)、
//      Storage (firebasestorage.googleapis.com)、Firestore、Cloud Messaging の
//      REST エンドポイントを Rust から直接叩く。
//      オフラインキャッシュとリトライ機構も同梱。

pub mod auth;
pub mod cache;
pub mod config;
pub mod error;
pub mod firestore;
pub mod http;
pub mod messaging;
pub mod retry;
pub mod storage;

pub use auth::{AuthClient, AuthSession};
pub use cache::Cache;
pub use config::FirebaseConfig;
pub use error::{FirebaseError, Result};
pub use firestore::{
    ArrayValue, Direction, Document, DocumentList, FieldFilter, FieldOp, FieldReference, Filter,
    FirestoreClient, FirestoreValue, GeoPoint, MapValue, NullMarker, Order, StructuredQuery,
};
pub use http::HttpClient;
pub use messaging::{MessagingClient, NotificationPayload};
pub use retry::{execute_with_retry, BackoffKind, RetryCondition, RetryPolicy};
pub use storage::{StorageClient, StorageObject};

/// Auth / Storage / Firestore / Messaging をまとめて保持するトップレベルクライアント。
///
/// Swift 側からは Phase 2D で FFI 経由でこの構造体を生成・利用する想定。
#[derive(Debug, Clone)]
pub struct FirebaseClient {
    /// 共通設定
    pub config: FirebaseConfig,
    /// 認証クライアント
    pub auth: AuthClient,
    /// Storage クライアント
    pub storage: StorageClient,
    /// Firestore クライアント
    pub firestore: FirestoreClient,
    /// Cloud Messaging クライアント
    pub messaging: MessagingClient,
}

impl FirebaseClient {
    /// 既定の HTTP クライアントで `FirebaseClient` を構築する。
    pub fn new(config: FirebaseConfig) -> Result<Self> {
        let http = HttpClient::new()?;
        Ok(Self::with_http(config, http))
    }

    /// 任意の `HttpClient` を共有して構築する (テスト時の差し替え用)。
    pub fn with_http(config: FirebaseConfig, http: HttpClient) -> Self {
        let auth = AuthClient::new(config.clone(), http.clone());
        let storage = StorageClient::new(config.clone(), http.clone(), auth.clone());
        let firestore = FirestoreClient::new(config.clone(), http.clone(), auth.clone());
        let messaging = MessagingClient::new(config.clone(), http.clone(), auth.clone());
        Self {
            config,
            auth,
            storage,
            firestore,
            messaging,
        }
    }

    /// オフラインキャッシュを Storage / Firestore に伝搬させたコピーを返す。
    pub fn with_cache(mut self, cache: Cache) -> Self {
        self.storage = self.storage.with_cache(cache.clone());
        self.firestore = self.firestore.with_cache(cache);
        self
    }
}
