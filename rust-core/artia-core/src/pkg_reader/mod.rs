// PKGファイルリーダー + DDSデコーダー

mod dds;

use std::path::Path;
use thiserror::Error;

pub use dds::DdsDecoder;

#[derive(Error, Debug)]
pub enum PkgError {
    #[error("PKGファイルが小さすぎます")]
    TooSmall,
    #[error("PKGファイルではありません")]
    InvalidMagic,
    #[error("PKGファイルが大きすぎます（{0}MB）。上限は512MBです")]
    TooLarge(u64),
    #[error("'{0}' はPKG内に見つかりません")]
    EntryNotFound(String),
    #[error("バッファ境界外: offset={0}, size={1}")]
    OutOfBounds(usize, usize),
    #[error("IO エラー: {0}")]
    Io(#[from] std::io::Error),
    #[error("画像デコードエラー: {0}")]
    ImageDecode(String),
    #[error("サポートされていないテクスチャフォーマット: {0}")]
    UnsupportedFormat(String),
}

/// PKGファイル内のエントリ
#[derive(Debug, Clone)]
pub struct PkgEntry {
    pub name: String,
    pub offset: usize,
    pub size: usize,
}

/// PKGファイルリーダー
pub struct PkgReader {
    data: Vec<u8>,
    entries: Vec<PkgEntry>,
    data_start: usize,
}

const PKG_MAGIC: &[u8; 4] = b"PKGV";
const MAX_PKG_SIZE: u64 = 512 * 1024 * 1024; // 512MB

impl PkgReader {
    /// PKGファイルを読み込んでパースする
    pub fn open(path: &str) -> Result<Self, PkgError> {
        let file_path = Path::new(path);
        let metadata = std::fs::metadata(file_path)?;
        let file_size = metadata.len();

        if file_size > MAX_PKG_SIZE {
            return Err(PkgError::TooLarge(file_size / 1024 / 1024));
        }

        let data = std::fs::read(file_path)?;
        let mut reader = Self {
            data,
            entries: Vec::new(),
            data_start: 0,
        };
        reader.parse_toc()?;
        Ok(reader)
    }

    /// TOC（目次）を解析する
    fn parse_toc(&mut self) -> Result<(), PkgError> {
        if self.data.len() < 16 {
            return Err(PkgError::TooSmall);
        }

        // マジックバイトはオフセット4〜8
        if &self.data[4..8] != PKG_MAGIC {
            return Err(PkgError::InvalidMagic);
        }

        let mut pos = 16;
        while pos + 4 <= self.data.len() {
            let name_len = u32::from_le_bytes([
                self.data[pos],
                self.data[pos + 1],
                self.data[pos + 2],
                self.data[pos + 3],
            ]) as usize;

            if name_len == 0 || name_len > 4096 {
                break;
            }
            pos += 4;

            // 境界チェック
            let required = name_len + 8;
            if pos + required > self.data.len() {
                log::warn!("TOC解析中に境界外アクセスを検出。解析を終了します");
                break;
            }

            let name = String::from_utf8_lossy(&self.data[pos..pos + name_len]).to_string();
            pos += name_len;

            let offset = u32::from_le_bytes([
                self.data[pos],
                self.data[pos + 1],
                self.data[pos + 2],
                self.data[pos + 3],
            ]) as usize;
            let size = u32::from_le_bytes([
                self.data[pos + 4],
                self.data[pos + 5],
                self.data[pos + 6],
                self.data[pos + 7],
            ]) as usize;
            pos += 8;

            self.entries.push(PkgEntry { name, offset, size });
        }

        self.data_start = pos;
        Ok(())
    }

    /// テクスチャエントリ一覧を返す
    pub fn list_textures(&self) -> Vec<&PkgEntry> {
        self.entries.iter().filter(|e| e.name.ends_with(".tex")).collect()
    }

    /// 指定名のファイルデータを読み出す
    pub fn read_file(&self, name: &str) -> Result<&[u8], PkgError> {
        let entry = self
            .entries
            .iter()
            .find(|e| e.name == name)
            .ok_or_else(|| PkgError::EntryNotFound(name.to_string()))?;

        let start = self.data_start + entry.offset;
        let end = start + entry.size;

        if start > self.data.len() || end > self.data.len() || start > end {
            return Err(PkgError::OutOfBounds(entry.offset, entry.size));
        }

        Ok(&self.data[start..end])
    }

    /// テクスチャデータからRGBAピクセルにデコードする
    /// 戻り値: (width, height, rgba_pixels)
    pub fn decode_texture(&self, name: &str) -> Result<(u32, u32, Vec<u8>), PkgError> {
        let raw = self.read_file(name)?;
        decode_texture_data(raw)
    }

    /// テクスチャをPNGファイルとして書き出す
    pub fn extract_texture_as_png(
        &self,
        name: &str,
        output_path: &str,
    ) -> Result<(), PkgError> {
        let (width, height, pixels) = self.decode_texture(name)?;
        save_rgba_as_png(&pixels, width, height, output_path)
    }

    /// 全テクスチャを指定ディレクトリに展開する
    pub fn extract_all_textures(&self, output_dir: &str) -> Result<Vec<String>, PkgError> {
        std::fs::create_dir_all(output_dir)?;
        let mut extracted = Vec::new();

        for entry in self.list_textures() {
            let tex_name = &entry.name;
            // .tex → .png に変換
            let png_name = tex_name.replace(".tex", ".png");
            let output_path = format!("{}/{}", output_dir, png_name);

            match self.extract_texture_as_png(tex_name, &output_path) {
                Ok(()) => {
                    extracted.push(output_path);
                }
                Err(e) => {
                    log::warn!("テクスチャ '{}' の展開に失敗: {}", tex_name, e);
                }
            }
        }

        Ok(extracted)
    }
}

/// テクスチャ生データからRGBAピクセルにデコード
fn decode_texture_data(raw: &[u8]) -> Result<(u32, u32, Vec<u8>), PkgError> {
    // DDSシグネチャ検索
    if let Some(pos) = find_signature(raw, &[0x44, 0x44, 0x53, 0x20]) {
        let dds_data = &raw[pos..];
        return DdsDecoder::decode(dds_data)
            .map_err(|e| PkgError::ImageDecode(format!("DDS: {}", e)));
    }

    // PNGシグネチャ検索
    if let Some(pos) = find_signature(raw, &[0x89, 0x50, 0x4E, 0x47]) {
        return decode_standard_image(&raw[pos..]);
    }

    // JPEGシグネチャ検索
    if let Some(pos) = find_signature(raw, &[0xFF, 0xD8, 0xFF]) {
        return decode_standard_image(&raw[pos..]);
    }

    // BMPシグネチャ検索
    if let Some(pos) = find_signature(raw, &[0x42, 0x4D]) {
        return decode_standard_image(&raw[pos..]);
    }

    // GIFシグネチャ検索
    if let Some(pos) = find_signature(raw, &[0x47, 0x49, 0x46, 0x38]) {
        return decode_standard_image(&raw[pos..]);
    }

    // フォーマットを特定してエラーメッセージに含める
    let header = if raw.len() >= 16 {
        raw[..16]
            .iter()
            .map(|b| format!("{:02X}", b))
            .collect::<Vec<_>>()
            .join(" ")
    } else {
        "データが短すぎます".to_string()
    };
    Err(PkgError::UnsupportedFormat(format!("ヘッダー: {}", header)))
}

/// imageクレートで標準画像フォーマットをデコード
fn decode_standard_image(data: &[u8]) -> Result<(u32, u32, Vec<u8>), PkgError> {
    let img = image::load_from_memory(data)
        .map_err(|e| PkgError::ImageDecode(e.to_string()))?;
    let rgba = img.to_rgba8();
    let (w, h) = rgba.dimensions();
    Ok((w, h, rgba.into_raw()))
}

/// バイト列中からシグネチャを検索
fn find_signature(data: &[u8], signature: &[u8]) -> Option<usize> {
    data.windows(signature.len())
        .position(|window| window == signature)
}

/// RGBAピクセルをPNGファイルとして保存
fn save_rgba_as_png(pixels: &[u8], width: u32, height: u32, path: &str) -> Result<(), PkgError> {
    image::save_buffer(
        path,
        pixels,
        width,
        height,
        image::ColorType::Rgba8,
    )
    .map_err(|e| PkgError::ImageDecode(format!("PNG保存失敗: {}", e)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_find_signature() {
        let data = [0x00, 0x00, 0x44, 0x44, 0x53, 0x20, 0xFF];
        assert_eq!(find_signature(&data, &[0x44, 0x44, 0x53, 0x20]), Some(2));
        assert_eq!(find_signature(&data, &[0xAA, 0xBB]), None);
    }
}
