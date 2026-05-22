// Rust ↔ C 型変換ヘルパー

use std::ffi::{c_char, CStr, CString};

/// C文字列ポインタからRust文字列スライスに変換する
/// nullまたは不正なUTF-8の場合はNoneを返す
///
/// # Safety
/// 呼び出し側はptrが有効なC文字列を指し、返り値の使用中にポインタが無効化されないことを保証すること
pub unsafe fn cstr_to_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    CStr::from_ptr(ptr).to_str().ok()
}

/// RustのStringをC文字列ポインタに変換する
/// 呼び出し側は artia_free_string() で解放すること
pub fn rust_str_to_c(s: &str) -> *mut c_char {
    match CString::new(s) {
        Ok(c_str) => c_str.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// エラーメッセージをJSON形式のC文字列に変換する
/// ダブルクォートとバックスラッシュをエスケープしてJSONインジェクションを防ぐ
pub fn error_to_c_json(message: &str) -> *mut c_char {
    let escaped = message.replace('\\', "\\\\").replace('"', "\\\"");
    let error_json = format!(r#"{{"error":"{}"}}"#, escaped);
    rust_str_to_c(&error_json)
}
