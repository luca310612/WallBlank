// プラットフォーム抽象化レイヤー
// OS検知と壁紙設定の統一インターフェースを提供する

use std::path::Path;

/// 現在のOSを表す列挙型
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OsType {
    Windows,
    MacOS,
    Linux,
    Unknown,
}

impl OsType {
    /// 現在のOSを検知する
    pub fn current() -> Self {
        match std::env::consts::OS {
            "windows" => OsType::Windows,
            "macos" => OsType::MacOS,
            "linux" => OsType::Linux,
            _ => OsType::Unknown,
        }
    }

    /// OS名を日本語で返す
    pub fn display_name(&self) -> &'static str {
        match self {
            OsType::Windows => "Windows",
            OsType::MacOS => "macOS",
            OsType::Linux => "Linux",
            OsType::Unknown => "不明なOS",
        }
    }
}

/// プラットフォーム固有のエラー
#[derive(Debug, thiserror::Error)]
pub enum PlatformError {
    #[error("壁紙の設定に失敗: {0}")]
    SetWallpaperFailed(String),

    #[error("壁紙の取得に失敗: {0}")]
    GetWallpaperFailed(String),

    #[error("未対応のOS: {0}")]
    UnsupportedOs(String),

    #[error("ファイルが見つからない: {0}")]
    FileNotFound(String),

    #[error("コマンド実行に失敗: {0}")]
    CommandFailed(String),
}

/// 壁紙フィットモード（各OSで変換する）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WallpaperFitMode {
    /// 画面に合わせて拡大縮小
    Fill,
    /// アスペクト比を維持して収める
    Fit,
    /// 引き伸ばし
    Stretch,
    /// 中央配置
    Center,
    /// タイル配置
    Tile,
}

/// 壁紙設定の統一インターフェース
/// 各プラットフォーム（macOS, Windows, Linux）が実装する
pub trait WallpaperProvider: Send + Sync {
    /// 壁紙を設定する
    fn set_wallpaper(&self, path: &Path, mode: WallpaperFitMode) -> Result<(), PlatformError>;

    /// 現在の壁紙パスを取得する
    fn get_current_wallpaper(&self) -> Result<String, PlatformError>;

    /// 利用可能なディスプレイ数を返す
    fn display_count(&self) -> Result<usize, PlatformError>;

    /// 特定のディスプレイに壁紙を設定する
    fn set_wallpaper_for_display(
        &self,
        display_index: usize,
        path: &Path,
        mode: WallpaperFitMode,
    ) -> Result<(), PlatformError>;
}

/// OS検知に基づいて適切なプラットフォーム情報を返す
pub fn platform_info() -> PlatformInfo {
    let os = OsType::current();
    PlatformInfo {
        os,
        arch: std::env::consts::ARCH.to_string(),
        os_version: String::new(), // 各プラットフォームクレートで取得可能
    }
}

/// プラットフォーム情報
#[derive(Debug, Clone)]
pub struct PlatformInfo {
    pub os: OsType,
    pub arch: String,
    pub os_version: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_os_detection() {
        let os = OsType::current();
        // macOSでテストしているはず
        assert_eq!(os, OsType::MacOS);
        assert_eq!(os.display_name(), "macOS");
    }
}
