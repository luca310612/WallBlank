// Artia macOS プラットフォーム固有の実装
// NSWorkspace / desktopImageURL API経由で壁紙を設定する
// 注意: 実際の壁紙設定はSwift側（AppKit）で行い、ここはFFI経由で呼び出す

use artia_core::platform::{PlatformError, WallpaperFitMode, WallpaperProvider};
use std::path::Path;
use std::process::Command;

pub struct MacOSWallpaperProvider;

impl MacOSWallpaperProvider {
    pub fn new() -> Self {
        Self
    }
}

#[cfg(target_os = "macos")]
impl WallpaperProvider for MacOSWallpaperProvider {
    fn set_wallpaper(&self, path: &Path, mode: WallpaperFitMode) -> Result<(), PlatformError> {
        if !path.exists() {
            return Err(PlatformError::FileNotFound(path.display().to_string()));
        }

        let path_str = path.to_str().ok_or_else(|| {
            PlatformError::SetWallpaperFailed("パスをUTF-8に変換できません".to_string())
        })?;

        let fitting = match mode {
            WallpaperFitMode::Fill => "fill",
            WallpaperFitMode::Fit => "fit",
            WallpaperFitMode::Stretch => "stretch",
            WallpaperFitMode::Center => "center",
            WallpaperFitMode::Tile => "fill", // macOSにはタイル非対応、fillで代替
        };

        // osascriptでデスクトップ壁紙を設定
        let script = format!(
            r#"tell application "System Events" to tell every desktop to set picture to POSIX file "{}""#,
            path_str
        );

        let output = Command::new("osascript")
            .args(["-e", &script])
            .output()
            .map_err(|e| PlatformError::CommandFailed(format!("osascript実行失敗: {}", e)))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(PlatformError::SetWallpaperFailed(
                format!("壁紙設定スクリプトがエラー: {} (フィット: {})", stderr, fitting),
            ));
        }

        log::info!("macOS壁紙を設定: {} (モード: {})", path_str, fitting);
        Ok(())
    }

    fn get_current_wallpaper(&self) -> Result<String, PlatformError> {
        let script = r#"tell application "System Events" to get picture of desktop 1"#;

        let output = Command::new("osascript")
            .args(["-e", script])
            .output()
            .map_err(|e| PlatformError::CommandFailed(format!("osascript実行失敗: {}", e)))?;

        if !output.status.success() {
            return Err(PlatformError::GetWallpaperFailed(
                "現在の壁紙パスを取得できませんでした".to_string(),
            ));
        }

        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    }

    fn display_count(&self) -> Result<usize, PlatformError> {
        let script = r#"tell application "System Events" to count of desktops"#;

        let output = Command::new("osascript")
            .args(["-e", script])
            .output()
            .map_err(|e| PlatformError::CommandFailed(format!("osascript実行失敗: {}", e)))?;

        let count_str = String::from_utf8_lossy(&output.stdout).trim().to_string();
        count_str
            .parse::<usize>()
            .map_err(|_| PlatformError::GetWallpaperFailed("ディスプレイ数の解析に失敗".to_string()))
    }

    fn set_wallpaper_for_display(
        &self,
        display_index: usize,
        path: &Path,
        _mode: WallpaperFitMode,
    ) -> Result<(), PlatformError> {
        if !path.exists() {
            return Err(PlatformError::FileNotFound(path.display().to_string()));
        }

        let path_str = path.to_str().ok_or_else(|| {
            PlatformError::SetWallpaperFailed("パスをUTF-8に変換できません".to_string())
        })?;

        // AppleScriptのdesktopは1始まり
        let script = format!(
            r#"tell application "System Events" to set picture of desktop {} to POSIX file "{}""#,
            display_index + 1,
            path_str
        );

        let output = Command::new("osascript")
            .args(["-e", &script])
            .output()
            .map_err(|e| PlatformError::CommandFailed(format!("osascript実行失敗: {}", e)))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(PlatformError::SetWallpaperFailed(
                format!("ディスプレイ{}の壁紙設定に失敗: {}", display_index, stderr),
            ));
        }

        log::info!("macOSディスプレイ{}の壁紙を設定: {}", display_index, path_str);
        Ok(())
    }
}

// macOS以外のOS向けスタブ
#[cfg(not(target_os = "macos"))]
impl WallpaperProvider for MacOSWallpaperProvider {
    fn set_wallpaper(&self, _path: &Path, _mode: WallpaperFitMode) -> Result<(), PlatformError> {
        Err(PlatformError::UnsupportedOs("macOSプロバイダはmacOS上でのみ動作します".to_string()))
    }

    fn get_current_wallpaper(&self) -> Result<String, PlatformError> {
        Err(PlatformError::UnsupportedOs("macOSプロバイダはmacOS上でのみ動作します".to_string()))
    }

    fn display_count(&self) -> Result<usize, PlatformError> {
        Err(PlatformError::UnsupportedOs("macOSプロバイダはmacOS上でのみ動作します".to_string()))
    }

    fn set_wallpaper_for_display(
        &self,
        _display_index: usize,
        _path: &Path,
        _mode: WallpaperFitMode,
    ) -> Result<(), PlatformError> {
        Err(PlatformError::UnsupportedOs("macOSプロバイダはmacOS上でのみ動作します".to_string()))
    }
}
