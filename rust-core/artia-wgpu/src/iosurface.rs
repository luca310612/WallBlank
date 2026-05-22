// IOSurface管理
// WGPUレンダリング結果をIOSurfaceに書き込み、Swift側でMTLTextureとして利用可能にする

use std::ffi::c_void;

// IOSurface.frameworkの関数バインディング
#[link(name = "IOSurface", kind = "framework")]
extern "C" {
    fn IOSurfaceCreate(properties: core_foundation_sys::dictionary::CFDictionaryRef) -> *mut c_void;
    fn IOSurfaceLock(surface: *mut c_void, options: u32, seed: *mut u32) -> i32;
    fn IOSurfaceUnlock(surface: *mut c_void, options: u32, seed: *mut u32) -> i32;
    fn IOSurfaceGetBaseAddress(surface: *mut c_void) -> *mut c_void;
    fn IOSurfaceGetBytesPerRow(surface: *mut c_void) -> usize;
}

// IOSurfaceプロパティキー
#[link(name = "IOSurface", kind = "framework")]
extern "C" {
    static kIOSurfaceWidth: core_foundation_sys::string::CFStringRef;
    static kIOSurfaceHeight: core_foundation_sys::string::CFStringRef;
    static kIOSurfaceBytesPerElement: core_foundation_sys::string::CFStringRef;
    static kIOSurfaceBytesPerRow: core_foundation_sys::string::CFStringRef;
    static kIOSurfacePixelFormat: core_foundation_sys::string::CFStringRef;
}

/// IOSurfaceのラッパー
pub struct IOSurfaceHandle {
    surface: *mut c_void,
    width: u32,
    height: u32,
}

// IOSurfaceはOS管理のリソースでスレッドセーフ
unsafe impl Send for IOSurfaceHandle {}
unsafe impl Sync for IOSurfaceHandle {}

impl IOSurfaceHandle {
    /// 指定サイズのBGRA8 IOSurfaceを作成する
    pub fn new(width: u32, height: u32) -> Result<Self, String> {
        use core_foundation::base::TCFType;
        use core_foundation::dictionary::CFDictionary;
        use core_foundation::number::CFNumber;
        use core_foundation::string::CFString;

        let bytes_per_element: i64 = 4;
        // MetalのIOSurfaceテクスチャはstrideアラインメントが必要（256バイト境界）
        let bytes_per_row: i64 = ((width as i64 * bytes_per_element + 255) / 256) * 256;
        // 'BGRA' = 0x42475241
        let pixel_format: i64 = 0x42475241;

        unsafe {
            let keys = vec![
                CFString::wrap_under_get_rule(kIOSurfaceWidth),
                CFString::wrap_under_get_rule(kIOSurfaceHeight),
                CFString::wrap_under_get_rule(kIOSurfaceBytesPerElement),
                CFString::wrap_under_get_rule(kIOSurfaceBytesPerRow),
                CFString::wrap_under_get_rule(kIOSurfacePixelFormat),
            ];
            let values = vec![
                CFNumber::from(width as i64),
                CFNumber::from(height as i64),
                CFNumber::from(bytes_per_element),
                CFNumber::from(bytes_per_row),
                CFNumber::from(pixel_format),
            ];

            let dict = CFDictionary::from_CFType_pairs(&keys.iter().zip(values.iter()).map(|(k, v)| (k.clone(), v.clone())).collect::<Vec<_>>());

            let surface = IOSurfaceCreate(dict.as_concrete_TypeRef());
            if surface.is_null() {
                return Err("IOSurface作成失敗".to_string());
            }

            log::info!("IOSurface作成成功 ({}x{}, BGRA8)", width, height);
            Ok(Self { surface, width, height })
        }
    }

    /// IOSurfaceの生ポインタを取得（Swift側でIOSurfaceRefとして使用）
    pub fn as_ptr(&self) -> *mut c_void {
        self.surface
    }

    /// ピクセルデータをIOSurfaceに書き込む
    /// データはBGRA8形式、width * height * 4バイト
    pub fn write_pixels(&self, data: &[u8]) {
        let expected_len = (self.width as usize) * (self.height as usize) * 4;
        if data.len() < expected_len {
            log::error!(
                "IOSurface書き込みエラー: データサイズ不足 (期待: {}, 実際: {})",
                expected_len,
                data.len()
            );
            return;
        }

        // 初回数回の書き込みで非ゼロピクセルを検証（デバッグ用）
        static WRITE_COUNT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
        let count = WRITE_COUNT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        if count < 5 {
            let sample_size = data.len().min(4000);
            let non_zero = data.iter().take(sample_size).filter(|&&b| b != 0).count();
            log::info!(
                "IOSurface書き込み #{}: サイズ={}x{}, データ長={}, 先頭{}バイト中の非ゼロ={}",
                count, self.width, self.height, data.len(), sample_size, non_zero
            );
        }

        unsafe {
            IOSurfaceLock(self.surface, 0, std::ptr::null_mut());
            let base = IOSurfaceGetBaseAddress(self.surface);
            let surface_bytes_per_row = IOSurfaceGetBytesPerRow(self.surface);
            let src_bytes_per_row = (self.width as usize) * 4;

            if surface_bytes_per_row == src_bytes_per_row {
                // バイト列が一致する場合は一括コピー
                std::ptr::copy_nonoverlapping(data.as_ptr(), base as *mut u8, expected_len);
            } else {
                // 行ごとにコピー（IOSurfaceのパディング対応）
                for row in 0..self.height as usize {
                    let src_offset = row * src_bytes_per_row;
                    let dst_offset = row * surface_bytes_per_row;
                    std::ptr::copy_nonoverlapping(
                        data.as_ptr().add(src_offset),
                        (base as *mut u8).add(dst_offset),
                        src_bytes_per_row,
                    );
                }
            }

            IOSurfaceUnlock(self.surface, 0, std::ptr::null_mut());
        }
    }

    /// IOSurfaceからピクセルデータを読み取る
    /// バッファはBGRA8形式、width * height * 4バイト以上
    pub fn read_pixels(&self, buffer: &mut [u8]) {
        let expected_len = (self.width as usize) * (self.height as usize) * 4;
        if buffer.len() < expected_len {
            log::error!(
                "IOSurface読み取りエラー: バッファサイズ不足 (期待: {}, 実際: {})",
                expected_len,
                buffer.len()
            );
            return;
        }

        unsafe {
            IOSurfaceLock(self.surface, 1, std::ptr::null_mut()); // 1 = kIOSurfaceLockReadOnly
            let base = IOSurfaceGetBaseAddress(self.surface);
            let surface_bytes_per_row = IOSurfaceGetBytesPerRow(self.surface);
            let dst_bytes_per_row = (self.width as usize) * 4;

            if surface_bytes_per_row == dst_bytes_per_row {
                std::ptr::copy_nonoverlapping(base as *const u8, buffer.as_mut_ptr(), expected_len);
            } else {
                for row in 0..self.height as usize {
                    let src_offset = row * surface_bytes_per_row;
                    let dst_offset = row * dst_bytes_per_row;
                    std::ptr::copy_nonoverlapping(
                        (base as *const u8).add(src_offset),
                        buffer.as_mut_ptr().add(dst_offset),
                        dst_bytes_per_row,
                    );
                }
            }

            IOSurfaceUnlock(self.surface, 1, std::ptr::null_mut());
        }
    }

    #[allow(dead_code)]
    pub fn width(&self) -> u32 {
        self.width
    }

    #[allow(dead_code)]
    pub fn height(&self) -> u32 {
        self.height
    }
}

impl Drop for IOSurfaceHandle {
    fn drop(&mut self) {
        // IOSurfaceはCFTypeでリファレンスカウント管理
        // IOSurfaceCreateで+1されたカウントを解放
        if !self.surface.is_null() {
            unsafe {
                core_foundation_sys::base::CFRelease(self.surface);
            }
            log::info!("IOSurface解放完了");
        }
    }
}
