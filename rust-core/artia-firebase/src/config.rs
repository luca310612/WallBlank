// Firebase プロジェクト設定。
// Why: GoogleService-Info.plist から抜き出した値を Rust 側に渡すための単純な値型。
//      Swift 側でファイルを読み、FFI 経由でフィールドを渡す想定。

use crate::error::{FirebaseError, Result};

/// Firebase プロジェクト設定。
///
/// Swift 側の `GoogleService-Info.plist` の以下キーに対応する想定:
/// - `PROJECT_ID`     → `project_id`
/// - `API_KEY`        → `api_key`
/// - `STORAGE_BUCKET` → `storage_bucket`
/// - `GOOGLE_APP_ID`  → `app_id`
#[derive(Debug, Clone)]
pub struct FirebaseConfig {
    /// Firebase プロジェクト ID
    pub project_id: String,
    /// Web API キー (Identity Toolkit / Secure Token API で使用)
    pub api_key: String,
    /// Cloud Storage バケット名 (例: `artia-app.appspot.com`)
    pub storage_bucket: String,
    /// Google App ID (任意。FCM などで使用)
    pub app_id: Option<String>,

    /// Identity Toolkit のベース URL。テスト時に mockito の URL に差し替えるため公開する。
    pub identity_toolkit_base: String,
    /// Secure Token API のベース URL。テスト時の差し替え用。
    pub secure_token_base: String,
    /// Firebase Storage REST API のベース URL。テスト時の差し替え用。
    pub storage_base: String,
    /// Firestore REST API のベース URL。テスト時の差し替え用。
    pub firestore_base: String,
    /// FCM HTTP v1 API のベース URL。テスト時の差し替え用。
    pub fcm_base: String,
    /// Instance ID API (トピックサブスクライブ) のベース URL。テスト時の差し替え用。
    pub iid_base: String,
}

impl FirebaseConfig {
    /// 通常用途の Firebase 既定エンドポイントで構成する。
    pub fn new(
        project_id: impl Into<String>,
        api_key: impl Into<String>,
        storage_bucket: impl Into<String>,
    ) -> Result<Self> {
        let project_id = project_id.into();
        let api_key = api_key.into();
        let storage_bucket = storage_bucket.into();

        if project_id.is_empty() {
            return Err(FirebaseError::Config("project_id が空です".to_string()));
        }
        if api_key.is_empty() {
            return Err(FirebaseError::Config("api_key が空です".to_string()));
        }
        if storage_bucket.is_empty() {
            return Err(FirebaseError::Config("storage_bucket が空です".to_string()));
        }

        Ok(Self {
            project_id,
            api_key,
            storage_bucket,
            app_id: None,
            identity_toolkit_base: "https://identitytoolkit.googleapis.com".to_string(),
            secure_token_base: "https://securetoken.googleapis.com".to_string(),
            storage_base: "https://firebasestorage.googleapis.com".to_string(),
            firestore_base: "https://firestore.googleapis.com".to_string(),
            fcm_base: "https://fcm.googleapis.com".to_string(),
            iid_base: "https://iid.googleapis.com".to_string(),
        })
    }

    /// `app_id` を設定したコピーを返す。
    pub fn with_app_id(mut self, app_id: impl Into<String>) -> Self {
        self.app_id = Some(app_id.into());
        self
    }

    /// テスト用: 全エンドポイントを同一のベース URL に上書きする。
    /// Why: mockito の単一 URL を Identity Toolkit / Secure Token / Storage 全てに割り当てるため。
    #[doc(hidden)]
    pub fn with_endpoints_for_test(mut self, base: impl Into<String>) -> Self {
        let base = base.into();
        self.identity_toolkit_base = base.clone();
        self.secure_token_base = base.clone();
        self.storage_base = base.clone();
        self.firestore_base = base.clone();
        self.fcm_base = base.clone();
        self.iid_base = base;
        self
    }
}
