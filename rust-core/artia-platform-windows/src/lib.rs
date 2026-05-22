// WallBlank Windows プラットフォーム固有の実装
// Windows壁紙設定API（SystemParametersInfoW）を使用する

use artia_core::platform::{PlatformError, WallpaperFitMode, WallpaperProvider};
use std::path::Path;

pub struct WindowsWallpaperProvider;

impl WindowsWallpaperProvider {
    pub fn new() -> Self {
        Self
    }
}

#[cfg(windows)]
mod windows_impl {
    use super::*;
    use std::ffi::OsStr;
    use std::os::windows::ffi::OsStrExt;
    use winapi::um::winuser::{
        SystemParametersInfoW, SPI_GETDESKWALLPAPER, SPI_SETDESKWALLPAPER,
        SPIF_SENDCHANGE, SPIF_UPDATEINIFILE,
    };

    impl WallpaperProvider for WindowsWallpaperProvider {
        fn set_wallpaper(&self, path: &Path, _mode: WallpaperFitMode) -> Result<(), PlatformError> {
            if !path.exists() {
                return Err(PlatformError::FileNotFound(
                    path.display().to_string(),
                ));
            }

            let path_wide: Vec<u16> = OsStr::new(path.to_str().unwrap_or_default())
                .encode_wide()
                .chain(std::iter::once(0))
                .collect();

            let result = unsafe {
                SystemParametersInfoW(
                    SPI_SETDESKWALLPAPER,
                    0,
                    path_wide.as_ptr() as *mut _,
                    SPIF_UPDATEINIFILE | SPIF_SENDCHANGE,
                )
            };

            if result == 0 {
                Err(PlatformError::SetWallpaperFailed(
                    "SystemParametersInfoWの呼び出しに失敗".to_string(),
                ))
            } else {
                log::info!("壁紙を設定: {}", path.display());
                Ok(())
            }
        }

        fn get_current_wallpaper(&self) -> Result<String, PlatformError> {
            let mut path_buf: [u16; 260] = [0; 260];
            let result = unsafe {
                SystemParametersInfoW(
                    SPI_GETDESKWALLPAPER,
                    path_buf.len() as u32,
                    path_buf.as_mut_ptr() as *mut _,
                    0,
                )
            };

            if result == 0 {
                return Err(PlatformError::GetWallpaperFailed(
                    "現在の壁紙パスを取得できませんでした".to_string(),
                ));
            }

            let len = path_buf.iter().position(|&c| c == 0).unwrap_or(path_buf.len());
            Ok(String::from_utf16_lossy(&path_buf[..len]))
        }

        fn display_count(&self) -> Result<usize, PlatformError> {
            // TODO: EnumDisplayMonitors で実装する
            Ok(1)
        }

        fn set_wallpaper_for_display(
            &self,
            _display_index: usize,
            path: &Path,
            mode: WallpaperFitMode,
        ) -> Result<(), PlatformError> {
            // Windows 8以降のIDesktopWallpaper APIで個別ディスプレイ対応可能
            // 現時点では全ディスプレイに同じ壁紙を設定する
            self.set_wallpaper(path, mode)
        }
    }
}

// Windows以外のOS向けのスタブ実装（コンパイルを通すため）
#[cfg(not(windows))]
impl WallpaperProvider for WindowsWallpaperProvider {
    fn set_wallpaper(&self, _path: &Path, _mode: WallpaperFitMode) -> Result<(), PlatformError> {
        Err(PlatformError::UnsupportedOs("WindowsプロバイダはWindows上でのみ動作します".to_string()))
    }

    fn get_current_wallpaper(&self) -> Result<String, PlatformError> {
        Err(PlatformError::UnsupportedOs("WindowsプロバイダはWindows上でのみ動作します".to_string()))
    }

    fn display_count(&self) -> Result<usize, PlatformError> {
        Err(PlatformError::UnsupportedOs("WindowsプロバイダはWindows上でのみ動作します".to_string()))
    }

    fn set_wallpaper_for_display(
        &self,
        _display_index: usize,
        _path: &Path,
        _mode: WallpaperFitMode,
    ) -> Result<(), PlatformError> {
        Err(PlatformError::UnsupportedOs("WindowsプロバイダはWindows上でのみ動作します".to_string()))
    }
}
