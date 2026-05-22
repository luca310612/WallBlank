// WallBlank Linux プラットフォーム固有の実装
// GNOME (gsettings), KDE (plasma-apply-wallpaperimage), その他DE対応

use artia_core::platform::{PlatformError, WallpaperFitMode, WallpaperProvider};
use std::path::Path;
use std::process::Command;

/// Linuxのデスクトップ環境を検出する
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DesktopEnvironment {
    Gnome,
    Kde,
    Xfce,
    Unknown(String),
}

impl DesktopEnvironment {
    /// 環境変数からデスクトップ環境を検出する
    pub fn detect() -> Self {
        let desktop = std::env::var("XDG_CURRENT_DESKTOP").unwrap_or_default().to_lowercase();
        if desktop.contains("gnome") || desktop.contains("unity") {
            DesktopEnvironment::Gnome
        } else if desktop.contains("kde") {
            DesktopEnvironment::Kde
        } else if desktop.contains("xfce") {
            DesktopEnvironment::Xfce
        } else {
            DesktopEnvironment::Unknown(desktop)
        }
    }
}

pub struct LinuxWallpaperProvider {
    desktop: DesktopEnvironment,
}

impl LinuxWallpaperProvider {
    pub fn new() -> Self {
        Self {
            desktop: DesktopEnvironment::detect(),
        }
    }
}

impl WallpaperProvider for LinuxWallpaperProvider {
    fn set_wallpaper(&self, path: &Path, mode: WallpaperFitMode) -> Result<(), PlatformError> {
        if !path.exists() {
            return Err(PlatformError::FileNotFound(path.display().to_string()));
        }

        let path_str = path.to_str().ok_or_else(|| {
            PlatformError::SetWallpaperFailed("パスをUTF-8に変換できません".to_string())
        })?;

        match &self.desktop {
            DesktopEnvironment::Gnome => {
                let option = match mode {
                    WallpaperFitMode::Fill => "zoom",
                    WallpaperFitMode::Fit => "scaled",
                    WallpaperFitMode::Stretch => "stretched",
                    WallpaperFitMode::Center => "centered",
                    WallpaperFitMode::Tile => "wallpaper",
                };

                // フィットモードを設定
                run_command("gsettings", &[
                    "set", "org.gnome.desktop.background", "picture-options", option,
                ])?;

                // 壁紙パスを設定
                let uri = format!("file://{}", path_str);
                run_command("gsettings", &[
                    "set", "org.gnome.desktop.background", "picture-uri", &uri,
                ])?;
                // ダークモード用も設定
                run_command("gsettings", &[
                    "set", "org.gnome.desktop.background", "picture-uri-dark", &uri,
                ])?;

                log::info!("GNOME壁紙を設定: {}", path_str);
                Ok(())
            }
            DesktopEnvironment::Kde => {
                // KDE Plasma 5.24以降
                run_command("plasma-apply-wallpaperimage", &[path_str])?;
                log::info!("KDE壁紙を設定: {}", path_str);
                Ok(())
            }
            DesktopEnvironment::Xfce => {
                run_command("xfconf-query", &[
                    "-c", "xfce4-desktop",
                    "-p", "/backdrop/screen0/monitor0/workspace0/last-image",
                    "-s", path_str,
                ])?;
                log::info!("XFCE壁紙を設定: {}", path_str);
                Ok(())
            }
            DesktopEnvironment::Unknown(de) => {
                Err(PlatformError::UnsupportedOs(
                    format!("未対応のデスクトップ環境: {}", de),
                ))
            }
        }
    }

    fn get_current_wallpaper(&self) -> Result<String, PlatformError> {
        match &self.desktop {
            DesktopEnvironment::Gnome => {
                let output = Command::new("gsettings")
                    .args(["get", "org.gnome.desktop.background", "picture-uri"])
                    .output()
                    .map_err(|e| PlatformError::GetWallpaperFailed(e.to_string()))?;

                let uri = String::from_utf8_lossy(&output.stdout)
                    .trim()
                    .trim_matches('\'')
                    .to_string();

                // file:// プレフィックスを除去
                Ok(uri.strip_prefix("file://").unwrap_or(&uri).to_string())
            }
            DesktopEnvironment::Kde => {
                Err(PlatformError::GetWallpaperFailed(
                    "KDEでの壁紙パス取得は未実装です".to_string(),
                ))
            }
            DesktopEnvironment::Xfce => {
                let output = Command::new("xfconf-query")
                    .args([
                        "-c", "xfce4-desktop",
                        "-p", "/backdrop/screen0/monitor0/workspace0/last-image",
                    ])
                    .output()
                    .map_err(|e| PlatformError::GetWallpaperFailed(e.to_string()))?;

                Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
            }
            DesktopEnvironment::Unknown(de) => {
                Err(PlatformError::UnsupportedOs(
                    format!("未対応のデスクトップ環境: {}", de),
                ))
            }
        }
    }

    fn display_count(&self) -> Result<usize, PlatformError> {
        // TODO: xrandr等で実装
        Ok(1)
    }

    fn set_wallpaper_for_display(
        &self,
        _display_index: usize,
        path: &Path,
        mode: WallpaperFitMode,
    ) -> Result<(), PlatformError> {
        // 現時点では全ディスプレイに同じ壁紙を設定
        self.set_wallpaper(path, mode)
    }
}

/// 外部コマンドを実行するヘルパー
fn run_command(cmd: &str, args: &[&str]) -> Result<(), PlatformError> {
    let output = Command::new(cmd)
        .args(args)
        .output()
        .map_err(|e| PlatformError::CommandFailed(format!("{} の実行に失敗: {}", cmd, e)))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(PlatformError::CommandFailed(
            format!("{} がエラーで終了: {}", cmd, stderr),
        ));
    }

    Ok(())
}
