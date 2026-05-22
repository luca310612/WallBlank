// オフラインキャッシュ。
// Why: ネットワーク不通時に直近の Firestore ドキュメント / Storage バイト列を返せるよう、
//      ファイルシステム上に簡易的なキャッシュを置く。SQLite などは持ち込まず、
//      ディレクトリと JSON / バイナリで愚直に保持する。
//
// レイアウト:
//   <root>/firestore/<collection>/<doc_id>.json    (Document を JSON シリアライズ)
//   <root>/storage/<sha256(path)>.bin              (生バイト列)

use crate::error::{FirebaseError, Result};
use crate::firestore::Document;
use sha2::{Digest, Sha256};
use std::fmt::Write as _;
use std::path::{Path, PathBuf};

/// オフラインキャッシュ。
#[derive(Debug, Clone)]
pub struct Cache {
    root: PathBuf,
}

impl Cache {
    /// 指定ディレクトリ配下にキャッシュを構築する。存在しなければ作る。
    pub fn new(root: PathBuf) -> Result<Self> {
        std::fs::create_dir_all(&root)
            .map_err(|e| FirebaseError::Internal(format!("cache root 作成失敗: {e}")))?;
        Ok(Self { root })
    }

    /// 既定ルート (`~/Library/Caches/WallBlank/firebase/`) に構築する。
    /// Why: macOS の標準キャッシュディレクトリを使うことで、OS の自動掃除に任せられる。
    pub fn default_for_artia() -> Result<Self> {
        let root = Self::default_root()?;
        Self::new(root)
    }

    /// 既定ルートのパスを返す (作成はしない)。
    pub fn default_root() -> Result<PathBuf> {
        let base = dirs::cache_dir()
            .ok_or_else(|| FirebaseError::Internal("cache_dir が解決できません".to_string()))?;
        Ok(base.join("WallBlank").join("firebase"))
    }

    /// ルートパスを参照する (主にテスト用)。
    pub fn root(&self) -> &Path {
        &self.root
    }

    fn document_path(&self, collection: &str, doc_id: &str) -> PathBuf {
        self.root
            .join("firestore")
            .join(sanitize_segment(collection))
            .join(format!("{}.json", sanitize_segment(doc_id)))
    }

    fn storage_path(&self, path: &str) -> PathBuf {
        let hash = sha256_hex(path.as_bytes());
        self.root.join("storage").join(format!("{hash}.bin"))
    }

    /// キャッシュ済みドキュメントを返す。存在しない／読めない場合は None。
    pub fn get_document_cached(&self, collection: &str, doc_id: &str) -> Option<Document> {
        let path = self.document_path(collection, doc_id);
        let bytes = std::fs::read(path).ok()?;
        serde_json::from_slice::<Document>(&bytes).ok()
    }

    /// ドキュメントをキャッシュに書き込む。失敗は無視する (キャッシュなので fatal ではない)。
    pub fn put_document_cached(&self, collection: &str, doc_id: &str, doc: &Document) {
        let path = self.document_path(collection, doc_id);
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(bytes) = serde_json::to_vec(doc) {
            let _ = std::fs::write(path, bytes);
        }
    }

    /// 指定ドキュメントのキャッシュを削除する。存在しなくても OK。
    pub fn invalidate_document(&self, collection: &str, doc_id: &str) {
        let _ = std::fs::remove_file(self.document_path(collection, doc_id));
    }

    /// Storage パスに対応するバイト列を返す。存在しなければ None。
    pub fn get_storage_cached(&self, path: &str) -> Option<Vec<u8>> {
        std::fs::read(self.storage_path(path)).ok()
    }

    /// Storage パスに対応するバイト列を書き込む。
    pub fn put_storage_cached(&self, path: &str, bytes: &[u8]) {
        let target = self.storage_path(path);
        if let Some(parent) = target.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(target, bytes);
    }

    /// 指定 Storage パスのキャッシュを破棄する。
    pub fn invalidate_storage(&self, path: &str) {
        let _ = std::fs::remove_file(self.storage_path(path));
    }

    /// キャッシュ全体を消去して再作成する。
    pub fn clear_all(&self) -> Result<()> {
        if self.root.exists() {
            std::fs::remove_dir_all(&self.root)
                .map_err(|e| FirebaseError::Internal(format!("cache 削除失敗: {e}")))?;
        }
        std::fs::create_dir_all(&self.root)
            .map_err(|e| FirebaseError::Internal(format!("cache 再作成失敗: {e}")))?;
        Ok(())
    }
}

/// パス区切りや NUL 文字をディレクトリ名として安全な形に置換する。
fn sanitize_segment(input: &str) -> String {
    input
        .chars()
        .map(|c| match c {
            '/' | '\\' | '\0' => '_',
            c => c,
        })
        .collect()
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    let digest = hasher.finalize();
    let mut s = String::with_capacity(digest.len() * 2);
    for b in digest.iter() {
        let _ = write!(&mut s, "{b:02x}");
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::firestore::FirestoreValue;
    use std::collections::HashMap;

    fn sample_doc() -> Document {
        let mut fields: HashMap<String, FirestoreValue> = HashMap::new();
        fields.insert("displayName".into(), FirestoreValue::string("Alice"));
        fields.insert("age".into(), FirestoreValue::integer(30));
        Document {
            name: "projects/x/databases/(default)/documents/users/uid".into(),
            fields,
            create_time: None,
            update_time: Some("2026-05-01T00:00:00Z".into()),
        }
    }

    #[test]
    fn document_put_get_roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        let cache = Cache::new(dir.path().to_path_buf()).unwrap();
        assert!(cache.get_document_cached("users", "uid").is_none());
        cache.put_document_cached("users", "uid", &sample_doc());
        let restored = cache.get_document_cached("users", "uid").unwrap();
        assert_eq!(restored.name, sample_doc().name);
        assert_eq!(restored.fields.len(), 2);
    }

    #[test]
    fn invalidate_document_removes_file() {
        let dir = tempfile::tempdir().unwrap();
        let cache = Cache::new(dir.path().to_path_buf()).unwrap();
        cache.put_document_cached("c", "id", &sample_doc());
        assert!(cache.get_document_cached("c", "id").is_some());
        cache.invalidate_document("c", "id");
        assert!(cache.get_document_cached("c", "id").is_none());
    }

    #[test]
    fn storage_put_get_roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        let cache = Cache::new(dir.path().to_path_buf()).unwrap();
        let payload = vec![0xDE, 0xAD, 0xBE, 0xEF];
        assert!(cache.get_storage_cached("users/uid/foo.png").is_none());
        cache.put_storage_cached("users/uid/foo.png", &payload);
        let got = cache.get_storage_cached("users/uid/foo.png").unwrap();
        assert_eq!(got, payload);
    }

    #[test]
    fn storage_path_is_hashed() {
        let dir = tempfile::tempdir().unwrap();
        let cache = Cache::new(dir.path().to_path_buf()).unwrap();
        let p = cache.storage_path("users/uid/foo.png");
        let file = p.file_name().unwrap().to_string_lossy().into_owned();
        // 64 文字 hex + ".bin"
        assert!(file.ends_with(".bin"));
        assert_eq!(file.len(), 64 + ".bin".len());
    }

    #[test]
    fn clear_all_removes_everything() {
        let dir = tempfile::tempdir().unwrap();
        let cache = Cache::new(dir.path().to_path_buf()).unwrap();
        cache.put_storage_cached("a", &[1, 2, 3]);
        cache.put_document_cached("c", "id", &sample_doc());
        cache.clear_all().unwrap();
        assert!(cache.get_storage_cached("a").is_none());
        assert!(cache.get_document_cached("c", "id").is_none());
    }
}
