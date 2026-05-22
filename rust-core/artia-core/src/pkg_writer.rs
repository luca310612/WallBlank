// Phase 10D: WallBlank 公開用 .wallpaper パッケージ書き出し
//
// PkgReader / Wallpaper Engine の .pkg は独自バイナリ TOC 形式だが、
// WallBlank 独自フォーマット (.wallpaper) は ZIP コンテナとして以下を持つ:
//   - project.json   (WallBlank のプロジェクト情報: title / description / type など)
//   - scene.json     (シーンツリー / レイヤー定義)
//   - assets/<name>  (画像 / 動画 / Web 等のバイナリ)
//   - manifest.json  (WallBlank フォーマットバージョン情報)
//
// Why: .pkg と完全な互換性は難しいので、まずは WallBlank 独自形式として安定させる。
//      manifest.json に version を持たせて将来の互換ロジックを差し込める余地を残す。

use std::fs::File;
use std::io::{Read, Write};
use std::path::PathBuf;
use thiserror::Error;
use zip::write::SimpleFileOptions;
use zip::CompressionMethod;
use zip::ZipWriter;

#[derive(Error, Debug)]
pub enum PkgWriteError {
    #[error("出力先ファイルの作成に失敗: {0}")]
    Create(String),
    #[error("ZIP 書き込みに失敗: {0}")]
    Zip(#[from] zip::result::ZipError),
    #[error("IO エラー: {0}")]
    Io(#[from] std::io::Error),
    #[error("アセットファイルが見つかりません: {0}")]
    AssetNotFound(String),
    #[error("JSON シリアライズに失敗: {0}")]
    Serialize(String),
}

/// 公開用パッケージのフォーマットバージョン。
/// Why: 将来仕様が変わった際に PkgReader 側で互換ロジックを分岐させるため。
pub const ARTIA_PKG_VERSION: u32 = 1;

/// WallBlank 独自フォーマット (.wallpaper) のマジック識別子。
pub const ARTIA_PKG_MAGIC: &str = "ArtiaPkg";

/// 書き込みに使うアセット情報。
#[derive(Debug, Clone)]
pub struct AssetInput {
    /// パッケージ内での名前 (例: "thumbnail.png")
    pub name: String,
    /// 元ファイルへの絶対 / 相対パス
    pub path: PathBuf,
}

/// 書き込み入力。project / scene は JSON 文字列のまま受け取る。
#[derive(Debug, Clone)]
pub struct PkgWriteInput {
    pub output_path: PathBuf,
    pub project_json: String,
    pub scene_json: String,
    pub assets: Vec<AssetInput>,
}

/// WallBlank 独自 .wallpaper パッケージを ZIP コンテナとして書き出す。
pub struct PkgWriter;

impl PkgWriter {
    /// 公開用パッケージを書き出す。
    pub fn write(input: &PkgWriteInput) -> Result<(), PkgWriteError> {
        if let Some(parent) = input.output_path.parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent).map_err(|e| {
                    PkgWriteError::Create(format!("親ディレクトリ作成失敗: {e}"))
                })?;
            }
        }

        let file = File::create(&input.output_path)
            .map_err(|e| PkgWriteError::Create(e.to_string()))?;
        let mut zip = ZipWriter::new(file);

        // テキストは Deflate、バイナリは Stored の方が小さい場合もあるが、
        // シンプルさのため一律 Deflate にする。
        let options: SimpleFileOptions = SimpleFileOptions::default()
            .compression_method(CompressionMethod::Deflated)
            .unix_permissions(0o644);

        // 1) manifest.json
        let manifest = serde_json::json!({
            "magic": ARTIA_PKG_MAGIC,
            "version": ARTIA_PKG_VERSION,
            "asset_count": input.assets.len(),
        });
        let manifest_str = serde_json::to_string_pretty(&manifest)
            .map_err(|e| PkgWriteError::Serialize(e.to_string()))?;
        zip.start_file("manifest.json", options)?;
        zip.write_all(manifest_str.as_bytes())?;

        // 2) project.json
        zip.start_file("project.json", options)?;
        zip.write_all(input.project_json.as_bytes())?;

        // 3) scene.json
        zip.start_file("scene.json", options)?;
        zip.write_all(input.scene_json.as_bytes())?;

        // 4) assets/*
        for asset in &input.assets {
            if !asset.path.exists() {
                return Err(PkgWriteError::AssetNotFound(asset.path.display().to_string()));
            }
            let entry_name = format!("assets/{}", sanitize_entry_name(&asset.name));
            zip.start_file(entry_name, options)?;
            let mut f = File::open(&asset.path)?;
            let mut buf = Vec::new();
            f.read_to_end(&mut buf)?;
            zip.write_all(&buf)?;
        }

        zip.finish()?;
        log::info!(
            "[pkg_writer] {} を書き出しました ({} assets)",
            input.output_path.display(),
            input.assets.len()
        );
        Ok(())
    }
}

/// ZIP エントリ名に使えないパス区切りや上位移動を無効化する。
/// Why: ユーザー指定の name に "/" や ".." が混じると展開時に予期せぬ場所に落ちうる。
fn sanitize_entry_name(name: &str) -> String {
    name.replace('\\', "_")
        .replace('/', "_")
        .replace("..", "_")
}

/// FFI 経由で受け取る JSON 構造の型表現。
///
/// 例:
/// ```json
/// {
///   "output_path": "/tmp/out.wallpaper",
///   "project_json": "{...}",
///   "scene_json": "{...}",
///   "assets": [{"name": "a.png", "path": "/tmp/a.png"}]
/// }
/// ```
#[derive(serde::Deserialize)]
pub struct PkgWriteDescriptor {
    pub output_path: String,
    pub project_json: String,
    pub scene_json: String,
    #[serde(default)]
    pub assets: Vec<PkgWriteAssetDescriptor>,
}

#[derive(serde::Deserialize)]
pub struct PkgWriteAssetDescriptor {
    pub name: String,
    pub path: String,
}

impl PkgWriteDescriptor {
    pub fn into_input(self) -> PkgWriteInput {
        PkgWriteInput {
            output_path: PathBuf::from(self.output_path),
            project_json: self.project_json,
            scene_json: self.scene_json,
            assets: self
                .assets
                .into_iter()
                .map(|a| AssetInput {
                    name: a.name,
                    path: PathBuf::from(a.path),
                })
                .collect(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pkg_reader::PkgReader;
    use tempfile::TempDir;

    fn setup_dir() -> TempDir {
        TempDir::new().expect("一時ディレクトリ作成失敗")
    }

    #[test]
    fn test_write_minimal_package() {
        let dir = setup_dir();
        let asset_path = dir.path().join("hello.txt");
        std::fs::write(&asset_path, b"hello world").unwrap();

        let out = dir.path().join("out.wallpaper");
        let input = PkgWriteInput {
            output_path: out.clone(),
            project_json: r#"{"title":"テスト","type":"image"}"#.to_string(),
            scene_json: r#"{"layers":[]}"#.to_string(),
            assets: vec![AssetInput {
                name: "hello.txt".into(),
                path: asset_path.clone(),
            }],
        };

        PkgWriter::write(&input).expect("書き込み成功");
        assert!(out.exists());

        // ZIP として開いて中身を検証
        let f = File::open(&out).unwrap();
        let mut zip = zip::ZipArchive::new(f).unwrap();
        assert!(zip.by_name("manifest.json").is_ok());
        assert!(zip.by_name("project.json").is_ok());
        assert!(zip.by_name("scene.json").is_ok());

        let mut asset_file = zip.by_name("assets/hello.txt").unwrap();
        let mut content = String::new();
        asset_file.read_to_string(&mut content).unwrap();
        assert_eq!(content, "hello world");
    }

    #[test]
    fn test_write_missing_asset_returns_error() {
        let dir = setup_dir();
        let out = dir.path().join("out.wallpaper");
        let input = PkgWriteInput {
            output_path: out,
            project_json: "{}".into(),
            scene_json: "{}".into(),
            assets: vec![AssetInput {
                name: "a.png".into(),
                path: dir.path().join("does-not-exist.png"),
            }],
        };
        let err = PkgWriter::write(&input).unwrap_err();
        assert!(matches!(err, PkgWriteError::AssetNotFound(_)));
    }

    #[test]
    fn test_sanitize_entry_name_blocks_traversal() {
        assert_eq!(sanitize_entry_name("../etc/passwd"), "_/etc/passwd".replace('/', "_"));
        assert_eq!(sanitize_entry_name("a\\b/c"), "a_b_c");
    }

    #[test]
    fn test_descriptor_into_input() {
        let json = r#"{
            "output_path": "/tmp/x.wallpaper",
            "project_json": "{}",
            "scene_json": "{}",
            "assets": [{"name": "a", "path": "/tmp/a"}]
        }"#;
        let desc: PkgWriteDescriptor = serde_json::from_str(json).unwrap();
        let input = desc.into_input();
        assert_eq!(input.output_path, PathBuf::from("/tmp/x.wallpaper"));
        assert_eq!(input.assets.len(), 1);
        assert_eq!(input.assets[0].name, "a");
    }

    /// Phase 10E: PkgWriter で書き出したファイルを ZIP リーダーで読み戻し、
    ///            project.json / scene.json / assets/ が同一であることを検証する。
    /// Note: 既存 PkgReader は Wallpaper Engine の .pkg バイナリ専用 (PKGV magic) なので、
    ///       WallBlank 独自フォーマットの読み取り検証には ZIP API を直接用いる。
    #[test]
    fn test_round_trip_via_zip_reader() {
        let dir = setup_dir();
        let asset_path = dir.path().join("preview.png");
        let bytes = vec![0x89u8, b'P', b'N', b'G', 0xFF, 0x00, 0xAB, 0xCD];
        let mut f = File::create(&asset_path).unwrap();
        f.write_all(&bytes).unwrap();

        let out = dir.path().join("rt.wallpaper");
        let project = r#"{"title":"R/T","type":"scene","tags":["aurora","夜空"]}"#;
        let scene = r#"{"version":1,"layers":[{"id":"a"}]}"#;
        PkgWriter::write(&PkgWriteInput {
            output_path: out.clone(),
            project_json: project.to_string(),
            scene_json: scene.to_string(),
            assets: vec![AssetInput {
                name: "preview.png".into(),
                path: asset_path.clone(),
            }],
        })
        .unwrap();

        let f = File::open(&out).unwrap();
        let mut zip = zip::ZipArchive::new(f).unwrap();

        let mut buf = String::new();
        zip.by_name("project.json").unwrap().read_to_string(&mut buf).unwrap();
        assert_eq!(buf, project);

        let mut buf2 = String::new();
        zip.by_name("scene.json").unwrap().read_to_string(&mut buf2).unwrap();
        assert_eq!(buf2, scene);

        let mut asset_bytes = Vec::new();
        zip.by_name("assets/preview.png")
            .unwrap()
            .read_to_end(&mut asset_bytes)
            .unwrap();
        assert_eq!(asset_bytes, bytes);

        let mut manifest_str = String::new();
        zip.by_name("manifest.json").unwrap().read_to_string(&mut manifest_str).unwrap();
        assert!(manifest_str.contains(ARTIA_PKG_MAGIC));
        assert!(manifest_str.contains(&format!("\"version\": {}", ARTIA_PKG_VERSION)));

        // 既存の Wallpaper Engine PKG リーダーは ArtiaPkg を InvalidMagic として弾くこと
        match PkgReader::open(out.to_str().unwrap()) {
            Ok(_) => panic!("WallBlank .wallpaper を旧 PkgReader が成功して開いてしまった"),
            Err(e) => assert!(matches!(
                e,
                crate::pkg_reader::PkgError::InvalidMagic | crate::pkg_reader::PkgError::TooSmall
            )),
        }
    }
}
