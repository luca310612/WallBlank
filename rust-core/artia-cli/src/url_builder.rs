//! artia-cli の subcommand → artia:// URL 変換。
//! Swift 側 AppDelegate.handleArtiaURL とフォーマットを揃えている。

/// 内部表現: ユーザの入力を構造化したもの
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CliCommand {
    WallpaperSet(String),
    WallpaperNext,
    WallpaperPrev,
    WallpaperRandom,
    PlaylistSwitch(String),
    ProfileSwitch(String),
    PropertySet(String, String),
}

/// CliCommand を artia:// URL にエンコードする純粋関数。
/// URL の path セグメントごとに `urlencoding` で per-component エンコードを行う。
pub fn build_url(command: &CliCommand) -> String {
    match command {
        CliCommand::WallpaperSet(target) => {
            format!("artia://wallpaper/set/{}", encode(target))
        }
        CliCommand::WallpaperNext => "artia://wallpaper/next".to_string(),
        CliCommand::WallpaperPrev => "artia://wallpaper/prev".to_string(),
        CliCommand::WallpaperRandom => "artia://wallpaper/random".to_string(),
        CliCommand::PlaylistSwitch(id) => {
            format!("artia://playlist/switch/{}", encode(id))
        }
        CliCommand::ProfileSwitch(id) => {
            format!("artia://profile/switch/{}", encode(id))
        }
        CliCommand::PropertySet(key, value) => {
            format!(
                "artia://property/set/{}/{}",
                encode(key),
                encode(value)
            )
        }
    }
}

fn encode(input: &str) -> String {
    urlencoding::encode(input).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wallpaper_set_simple_id() {
        let url = build_url(&CliCommand::WallpaperSet("abc123".to_string()));
        assert_eq!(url, "artia://wallpaper/set/abc123");
    }

    #[test]
    fn wallpaper_set_path_with_spaces_is_encoded() {
        let url = build_url(&CliCommand::WallpaperSet("/Users/me/Wall Paper.png".to_string()));
        assert_eq!(url, "artia://wallpaper/set/%2FUsers%2Fme%2FWall%20Paper.png");
    }

    #[test]
    fn navigation_commands() {
        assert_eq!(build_url(&CliCommand::WallpaperNext), "artia://wallpaper/next");
        assert_eq!(build_url(&CliCommand::WallpaperPrev), "artia://wallpaper/prev");
        assert_eq!(build_url(&CliCommand::WallpaperRandom), "artia://wallpaper/random");
    }

    #[test]
    fn playlist_switch_url() {
        let url = build_url(&CliCommand::PlaylistSwitch("morning".to_string()));
        assert_eq!(url, "artia://playlist/switch/morning");
    }

    #[test]
    fn profile_switch_url() {
        let url = build_url(&CliCommand::ProfileSwitch("balanced".to_string()));
        assert_eq!(url, "artia://profile/switch/balanced");
    }

    #[test]
    fn property_set_encodes_key_and_value() {
        let url = build_url(&CliCommand::PropertySet(
            "effect intensity".to_string(),
            "0.8".to_string(),
        ));
        assert_eq!(url, "artia://property/set/effect%20intensity/0.8");
    }
}
