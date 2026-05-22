// WallBlank コアロジッククレート
// プラットフォーム非依存のビジネスロジックを提供する

pub mod models;
pub mod event_bus;
pub mod pkg_reader;
pub mod pkg_writer;
pub mod platform;
pub mod brush_mask;
pub mod mask_paint;
pub mod magnetic_select;

/// WallBlankのバージョン情報を返す
pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_version() {
        assert_eq!(version(), "0.1.0");
    }
}
