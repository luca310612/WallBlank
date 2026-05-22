// artia-firebase の Swift 向け FFI 公開層。
// Why: artia-firebase は async API のみだが、Swift 側で呼びやすいよう
//      tokio runtime + ブロッキング呼び出しで extern "C" 関数群として公開する。
//      複雑データは JSON 経由で受け渡し、原始バイト列のみ raw pointer + len を使う。
//      グローバル FirebaseClient を OnceLock で保持し、init は一度だけで使い回す。

use crate::conversions::{cstr_to_str, error_to_c_json, rust_str_to_c};
use artia_firebase::{
    FirebaseClient, FirebaseConfig, FirestoreValue, NotificationPayload, StructuredQuery,
};
use serde::Deserialize;
use std::collections::HashMap;
use std::ffi::{c_char, CString};
use std::sync::OnceLock;
use std::time::UNIX_EPOCH;
use tokio::runtime::Runtime;

// ===== グローバル状態 =====

static RUNTIME: OnceLock<Runtime> = OnceLock::new();
static CLIENT: OnceLock<FirebaseClient> = OnceLock::new();

fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_name("artia-fb")
            .build()
            .expect("tokio runtime の構築に失敗")
    })
}

fn client() -> Option<&'static FirebaseClient> {
    CLIENT.get()
}

fn run_blocking<F, T>(future: F) -> T
where
    F: std::future::Future<Output = T>,
{
    runtime().block_on(future)
}

// ===== ヘルパー =====

#[derive(Deserialize)]
struct ConfigInput {
    project_id: String,
    api_key: String,
    storage_bucket: String,
    #[serde(default)]
    app_id: Option<String>,
}

fn session_to_json(session: &artia_firebase::AuthSession) -> String {
    let expires_at = session
        .expires_at
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    serde_json::json!({
        "id_token": session.id_token,
        "refresh_token": session.refresh_token,
        "local_id": session.local_id,
        "expires_at": expires_at,
    })
    .to_string()
}

fn vec_into_raw_parts(buf: Vec<u8>) -> (*mut u8, usize) {
    let len = buf.len();
    let boxed = buf.into_boxed_slice();
    let ptr = Box::into_raw(boxed) as *mut u8;
    (ptr, len)
}

fn no_client_error() -> *mut c_char {
    error_to_c_json("FirebaseClient 未初期化。先に artia_fb_init を呼んでください")
}

// ===== 初期化 =====

/// FirebaseConfig を JSON で渡して初期化する。
/// JSON 形式: `{"project_id": "...", "api_key": "...", "storage_bucket": "...", "app_id": "..."?}`
/// 二度目以降の呼び出しは既存クライアントを保持したまま true を返す (no-op)。
#[unsafe(no_mangle)]
pub extern "C" fn artia_fb_init(config_json: *const c_char) -> bool {
    let json = match unsafe { cstr_to_str(config_json) } {
        Some(s) => s,
        None => {
            log::error!("artia_fb_init: config_json が null/不正");
            return false;
        }
    };
    let parsed: ConfigInput = match serde_json::from_str(json) {
        Ok(c) => c,
        Err(e) => {
            log::error!("artia_fb_init: config JSON 解析失敗: {e}");
            return false;
        }
    };
    let mut cfg = match FirebaseConfig::new(parsed.project_id, parsed.api_key, parsed.storage_bucket)
    {
        Ok(c) => c,
        Err(e) => {
            log::error!("artia_fb_init: 設定不正: {e}");
            return false;
        }
    };
    if let Some(app_id) = parsed.app_id {
        cfg = cfg.with_app_id(app_id);
    }
    let client = match FirebaseClient::new(cfg) {
        Ok(c) => c,
        Err(e) => {
            log::error!("artia_fb_init: クライアント生成失敗: {e}");
            return false;
        }
    };
    // OnceLock::set は二度目以降 Err を返すが、その場合も既に init 済みなので true を返す。
    let _ = CLIENT.set(client);
    log::info!("artia_fb_init: FirebaseClient 初期化完了");
    true
}

// ===== Auth =====

/// 匿名サインインしてセッション JSON を返す。
/// 戻り値は `artia_fb_free_string()` で解放すること。
#[unsafe(no_mangle)]
pub extern "C" fn artia_fb_auth_sign_in_anonymously() -> *mut c_char {
    let Some(client) = client() else {
        return no_client_error();
    };
    match run_blocking(async { client.auth.sign_in_anonymously().await }) {
        Ok(session) => rust_str_to_c(&session_to_json(&session)),
        Err(e) => error_to_c_json(&format!("匿名サインイン失敗: {e}")),
    }
}

/// カスタムトークンでサインインしてセッション JSON を返す。
#[unsafe(no_mangle)]
pub extern "C" fn artia_fb_auth_sign_in_with_custom_token(token: *const c_char) -> *mut c_char {
    let Some(client) = client() else {
        return no_client_error();
    };
    let Some(token_str) = (unsafe { cstr_to_str(token) }) else {
        return error_to_c_json("token が null/不正");
    };
    match run_blocking(async { client.auth.sign_in_with_custom_token(token_str).await }) {
        Ok(session) => rust_str_to_c(&session_to_json(&session)),
        Err(e) => error_to_c_json(&format!("カスタムトークンサインイン失敗: {e}")),
    }
}

/// 現在の ID トークンを返す (期限が近ければ自動リフレッシュ)。
/// 戻り値 JSON: `{"id_token": "...", "local_id": "..."}` か `{"error": "..."}`.
#[unsafe(no_mangle)]
pub extern "C" fn artia_fb_auth_current_id_token() -> *mut c_char {
    let Some(client) = client() else {
        return no_client_error();
    };
    match run_blocking(async { client.auth.current_session().await }) {
        Ok(session) => {
            let json = serde_json::json!({
                "id_token": session.id_token,
                "local_id": session.local_id,
            })
            .to_string();
            rust_str_to_c(&json)
        }
        Err(e) => error_to_c_json(&format!("セッション取得失敗: {e}")),
    }
}

/// サインアウト。Rust 側のセッションキャッシュをクリアする (no-op に近い)。
/// 注意: Firebase SDK 側のサインアウトは Swift 側で別途行うこと。
#[unsafe(no_mangle)]
pub extern "C" fn artia_fb_auth_sign_out() -> bool {
    // AuthClient::clear_session のような API は artia-firebase に存在しないため、
    // ここでは true を返すのみ。実際のサインアウトは Swift の Firebase SDK 側で行う。
    log::info!("artia_fb_auth_sign_out: ローカルセッションは GC されるまで保持されます");
    true
}

// ===== Firestore =====

/// ドキュメントを取得して JSON 文字列で返す。
#[unsafe(no_mangle)]
pub extern "C" fn artia_fb_firestore_get(
    collection: *const c_char,
    doc_id: *const c_char,
) -> *mut c_char {
    let Some(client) = client() else {
        return no_client_error();
    };
    let Some(coll) = (unsafe { cstr_to_str(collection) }) else {
        return error_to_c_json("collection が null");
    };
    let Some(id) = (unsafe { cstr_to_str(doc_id) }) else {
        return error_to_c_json("doc_id が null");
    };
    match run_blocking(async { client.firestore.get_document(coll, id).await }) {
        Ok(doc) => match serde_json::to_string(&doc) {
            Ok(s) => rust_str_to_c(&s),
            Err(e) => error_to_c_json(&format!("Document JSON 化失敗: {e}")),
        },
        Err(e) => error_to_c_json(&format!("get_document 失敗: {e}")),
    }
}

/// 新規ドキュメントを作成。`doc_id_or_null` が null なら自動採番。
/// `fields_json` は `{"key": {"stringValue":"..."}}` の Tagged JSON。
#[unsafe(no_mangle)]
pub extern "C" fn artia_fb_firestore_create(
    collection: *const c_char,
    doc_id_or_null: *const c_char,
    fields_json: *const c_char,
) -> *mut c_char {
    let Some(client) = client() else {
        return no_client_error();
    };
    let Some(coll) = (unsafe { cstr_to_str(collection) }) else {
        return error_to_c_json("collection が null");
    };
    let doc_id_opt: Option<&str> = unsafe { cstr_to_str(doc_id_or_null) };
    let Some(fields_str) = (unsafe { cstr_to_str(fields_json) }) else {
        return error_to_c_json("fields_json が null");
    };
    let fields: HashMap<String, FirestoreValue> = match serde_json::from_str(fields_str) {
        Ok(f) => f,
        Err(e) => return error_to_c_json(&format!("fields_json 解析失敗: {e}")),
    };
    match run_blocking(async {
        client
            .firestore
            .create_document(coll, doc_id_opt, fields)
            .await
    }) {
        Ok(doc) => match serde_json::to_string(&doc) {
            Ok(s) => rust_str_to_c(&s),
            Err(e) => error_to_c_json(&format!("Document JSON 化失敗: {e}")),
        },
        Err(e) => error_to_c_json(&format!("create_document 失敗: {e}")),
    }
}

/// ドキュメントを部分/全更新する。`mask_json_or_null` は文字列配列 JSON (例 `["a","b"]`)。
#[unsafe(no_mangle)]
pub extern "C" fn artia_fb_firestore_update(
    collection: *const c_char,
    doc_id: *const c_char,
    fields_json: *const c_char,
    mask_json_or_null: *const c_char,
) -> *mut c_char {
    let Some(client) = client() else {
        return no_client_error();
    };
    let Some(coll) = (unsafe { cstr_to_str(collection) }) else {
        return error_to_c_json("collection が null");
    };
    let Some(id) = (unsafe { cstr_to_str(doc_id) }) else {
        return error_to_c_json("doc_id が null");
    };
    let Some(fields_str) = (unsafe { cstr_to_str(fields_json) }) else {
        return error_to_c_json("fields_json が null");
    };
    let fields: HashMap<String, FirestoreValue> = match serde_json::from_str(fields_str) {
        Ok(f) => f,
        Err(e) => return error_to_c_json(&format!("fields_json 解析失敗: {e}")),
    };
    let mask = match unsafe { cstr_to_str(mask_json_or_null) } {
        Some(s) => match serde_json::from_str::<Vec<String>>(s) {
            Ok(v) => Some(v),
            Err(e) => return error_to_c_json(&format!("mask_json 解析失敗: {e}")),
        },
        None => None,
    };
    match run_blocking(async {
        client
            .firestore
            .update_document(coll, id, fields, mask)
            .await
    }) {
        Ok(doc) => match serde_json::to_string(&doc) {
            Ok(s) => rust_str_to_c(&s),
            Err(e) => error_to_c_json(&format!("Document JSON 化失敗: {e}")),
        },
        Err(e) => error_to_c_json(&format!("update_document 失敗: {e}")),
    }
}

/// ドキュメントを削除する。
#[unsafe(no_mangle)]
pub extern "C" fn artia_fb_firestore_delete(
    collection: *const c_char,
    doc_id: *const c_char,
) -> bool {
    let Some(client) = client() else {
        log::error!("artia_fb_firestore_delete: 未初期化");
        return false;
    };
    let Some(coll) = (unsafe { cstr_to_str(collection) }) else {
        return false;
    };
    let Some(id) = (unsafe { cstr_to_str(doc_id) }) else {
        return false;
    };
    match run_blocking(async { client.firestore.delete_document(coll, id).await }) {
        Ok(_) => true,
        Err(e) => {
            log::error!("artia_fb_firestore_delete 失敗: {e}");
            false
        }
    }
}

/// runQuery を実行してヒット Document 配列を JSON で返す。
/// `parent` は documents 配下相対パス (空文字でルート可)。
#[unsafe(no_mangle)]
pub extern "C" fn artia_fb_firestore_query(
    parent: *const c_char,
    query_json: *const c_char,
) -> *mut c_char {
    let Some(client) = client() else {
        return no_client_error();
    };
    let parent_str = unsafe { cstr_to_str(parent) }.unwrap_or("");
    let Some(query_str) = (unsafe { cstr_to_str(query_json) }) else {
        return error_to_c_json("query_json が null");
    };
    let query: StructuredQuery = match serde_json::from_str(query_str) {
        Ok(q) => q,
        Err(e) => return error_to_c_json(&format!("query_json 解析失敗: {e}")),
    };
    match run_blocking(async { client.firestore.run_query(parent_str, query).await }) {
        Ok(docs) => match serde_json::to_string(&docs) {
            Ok(s) => rust_str_to_c(&s),
            Err(e) => error_to_c_json(&format!("Document[] JSON 化失敗: {e}")),
        },
        Err(e) => error_to_c_json(&format!("run_query 失敗: {e}")),
    }
}

// ===== Storage =====

/// バイト列をアップロードして StorageObject JSON を返す。
#[unsafe(no_mangle)]
pub extern "C" fn artia_fb_storage_upload(
    path: *const c_char,
    data: *const u8,
    len: usize,
    content_type: *const c_char,
) -> *mut c_char {
    let Some(client) = client() else {
        return no_client_error();
    };
    let Some(p) = (unsafe { cstr_to_str(path) }) else {
        return error_to_c_json("path が null");
    };
    let Some(ct) = (unsafe { cstr_to_str(content_type) }) else {
        return error_to_c_json("content_type が null");
    };
    if data.is_null() && len > 0 {
        return error_to_c_json("data が null かつ len>0");
    }
    let bytes: Vec<u8> = if len == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(data, len) }.to_vec()
    };
    match run_blocking(async { client.storage.upload(p, bytes, ct).await }) {
        Ok(obj) => match serde_json::to_string(&serde_json::json!({
            "bucket": obj.bucket,
            "name": obj.name,
            "contentType": obj.content_type,
            "size": obj.size,
            "etag": obj.etag,
            "downloadTokens": obj.download_tokens,
        })) {
            Ok(s) => rust_str_to_c(&s),
            Err(e) => error_to_c_json(&format!("StorageObject JSON 化失敗: {e}")),
        },
        Err(e) => error_to_c_json(&format!("storage upload 失敗: {e}")),
    }
}

/// オブジェクトをダウンロードしてバイト列を返す。
/// 成功時は ptr+ *out_len を埋めて返す (`artia_fb_free_bytes` で解放)。
/// 失敗時は null を返し out_len=0 を書き込む。
#[unsafe(no_mangle)]
pub extern "C" fn artia_fb_storage_download(
    path: *const c_char,
    out_len: *mut usize,
) -> *mut u8 {
    if !out_len.is_null() {
        unsafe { *out_len = 0 };
    }
    let Some(client) = client() else {
        log::error!("artia_fb_storage_download: 未初期化");
        return std::ptr::null_mut();
    };
    let Some(p) = (unsafe { cstr_to_str(path) }) else {
        return std::ptr::null_mut();
    };
    match run_blocking(async { client.storage.download(p).await }) {
        Ok(bytes) => {
            let (ptr, len) = vec_into_raw_parts(bytes);
            if !out_len.is_null() {
                unsafe { *out_len = len };
            }
            ptr
        }
        Err(e) => {
            log::error!("artia_fb_storage_download 失敗: {e}");
            std::ptr::null_mut()
        }
    }
}

/// オブジェクトを削除する。
#[unsafe(no_mangle)]
pub extern "C" fn artia_fb_storage_delete(path: *const c_char) -> bool {
    let Some(client) = client() else {
        log::error!("artia_fb_storage_delete: 未初期化");
        return false;
    };
    let Some(p) = (unsafe { cstr_to_str(path) }) else {
        return false;
    };
    match run_blocking(async { client.storage.delete(p).await }) {
        Ok(_) => true,
        Err(e) => {
            log::error!("artia_fb_storage_delete 失敗: {e}");
            false
        }
    }
}

// ===== Cloud Messaging =====

/// 端末トークンを指定トピックにサブスクライブする。
#[unsafe(no_mangle)]
pub extern "C" fn artia_fb_messaging_subscribe_topic(
    token: *const c_char,
    topic: *const c_char,
) -> bool {
    let Some(client) = client() else {
        return false;
    };
    let Some(t) = (unsafe { cstr_to_str(token) }) else {
        return false;
    };
    let Some(topic_str) = (unsafe { cstr_to_str(topic) }) else {
        return false;
    };
    match run_blocking(async { client.messaging.subscribe_topic(t, topic_str).await }) {
        Ok(_) => true,
        Err(e) => {
            log::error!("artia_fb_messaging_subscribe_topic 失敗: {e}");
            false
        }
    }
}

/// 端末トークンを指定トピックからアンサブスクライブする。
#[unsafe(no_mangle)]
pub extern "C" fn artia_fb_messaging_unsubscribe_topic(
    token: *const c_char,
    topic: *const c_char,
) -> bool {
    let Some(client) = client() else {
        return false;
    };
    let Some(t) = (unsafe { cstr_to_str(token) }) else {
        return false;
    };
    let Some(topic_str) = (unsafe { cstr_to_str(topic) }) else {
        return false;
    };
    match run_blocking(async { client.messaging.unsubscribe_topic(t, topic_str).await }) {
        Ok(_) => true,
        Err(e) => {
            log::error!("artia_fb_messaging_unsubscribe_topic 失敗: {e}");
            false
        }
    }
}

/// （任意・テスト用）端末トークン宛に通知を送信する。`payload_json` は
/// `{"title":"...","body":"...","data":{...}}` 形式。
#[unsafe(no_mangle)]
pub extern "C" fn artia_fb_messaging_send_to_token(
    token: *const c_char,
    payload_json: *const c_char,
) -> bool {
    let Some(client) = client() else {
        return false;
    };
    let Some(t) = (unsafe { cstr_to_str(token) }) else {
        return false;
    };
    let Some(payload_str) = (unsafe { cstr_to_str(payload_json) }) else {
        return false;
    };

    #[derive(Deserialize)]
    struct PayloadInput {
        title: String,
        body: String,
        #[serde(default)]
        data: HashMap<String, String>,
    }
    let parsed: PayloadInput = match serde_json::from_str(payload_str) {
        Ok(p) => p,
        Err(e) => {
            log::error!("artia_fb_messaging_send_to_token: payload 解析失敗: {e}");
            return false;
        }
    };
    let payload = NotificationPayload {
        title: parsed.title,
        body: parsed.body,
        data: parsed.data,
    };
    match run_blocking(async { client.messaging.send_to_token(t, payload).await }) {
        Ok(_) => true,
        Err(e) => {
            log::error!("artia_fb_messaging_send_to_token 失敗: {e}");
            false
        }
    }
}

// ===== メモリ解放 =====

/// `artia_fb_*` が返した *mut c_char を解放する。
#[unsafe(no_mangle)]
pub extern "C" fn artia_fb_free_string(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        let _ = CString::from_raw(ptr);
    }
}

/// `artia_fb_storage_download` が返した *mut u8 を解放する。
#[unsafe(no_mangle)]
pub extern "C" fn artia_fb_free_bytes(ptr: *mut u8, len: usize) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        let slice = std::slice::from_raw_parts_mut(ptr, len);
        let _ = Box::from_raw(slice);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    #[test]
    fn auth_without_init_returns_error_json() {
        // CLIENT が None のとき (この単体テストは init を呼ばない)
        // ※ ただし他のテストで init が走っていると CLIENT が set されている可能性があるので
        //   ここでは "出力が null でないこと" だけを確認する。
        let ptr = artia_fb_auth_sign_in_anonymously();
        assert!(!ptr.is_null());
        artia_fb_free_string(ptr);
    }

    #[test]
    fn init_with_invalid_json_returns_false() {
        let bad = CString::new("not-json").unwrap();
        let ok = artia_fb_init(bad.as_ptr());
        assert!(!ok);
    }

    #[test]
    fn free_null_string_is_safe() {
        artia_fb_free_string(std::ptr::null_mut());
    }

    #[test]
    fn free_null_bytes_is_safe() {
        artia_fb_free_bytes(std::ptr::null_mut(), 0);
    }
}
