//! Phase 8.4: artia-cli
//!
//! Artia 壁紙アプリを CLI から制御するためのフロントエンド。
//! 内部では artia:// URL Scheme を組み立て、macOS では `open -g 'artia://...'` を呼ぶ。
//! アプリが未起動の場合は macOS が自動起動する。
//!
//! 例:
//!   artia-cli wallpaper set my-wp-id
//!   artia-cli wallpaper next
//!   artia-cli playlist switch my-playlist
//!   artia-cli profile switch balanced
//!   artia-cli property set effect_intensity 0.8

use clap::{Parser, Subcommand};

mod url_builder;

use url_builder::{build_url, CliCommand};

#[derive(Parser, Debug)]
#[command(name = "artia-cli")]
#[command(about = "Artia 壁紙エンジンの CLI コントローラ", long_about = None)]
#[command(version)]
struct Cli {
    /// URL を実行せず標準出力に出すだけにする (CI/デバッグ用)
    #[arg(long)]
    dry_run: bool,

    #[command(subcommand)]
    command: TopCommand,
}

#[derive(Subcommand, Debug)]
enum TopCommand {
    /// 壁紙の操作
    Wallpaper {
        #[command(subcommand)]
        action: WallpaperAction,
    },
    /// プレイリスト操作
    Playlist {
        #[command(subcommand)]
        action: PlaylistAction,
    },
    /// プロファイル切替
    Profile {
        #[command(subcommand)]
        action: ProfileAction,
    },
    /// プロパティ設定
    Property {
        #[command(subcommand)]
        action: PropertyAction,
    },
}

#[derive(Subcommand, Debug)]
enum WallpaperAction {
    /// id またはパス指定で壁紙を設定する
    Set { target: String },
    /// 次の壁紙へ
    Next,
    /// 前の壁紙へ
    Prev,
    /// ランダム壁紙へ
    Random,
}

#[derive(Subcommand, Debug)]
enum PlaylistAction {
    /// 指定 id のプレイリストを再生する
    Switch { id: String },
}

#[derive(Subcommand, Debug)]
enum ProfileAction {
    /// プロファイル (low/balanced/high/ultra) を切替
    Switch { id: String },
}

#[derive(Subcommand, Debug)]
enum PropertyAction {
    /// 任意のプロパティ key=value を設定する
    Set { key: String, value: String },
}

fn main() {
    let cli = Cli::parse();
    let command = into_internal(&cli.command);
    let url = build_url(&command);
    if cli.dry_run {
        println!("{url}");
        return;
    }
    invoke_open(&url);
}

/// CLI の subcommand を内部表現に詰め替える。
/// テストではこの関数の代わりに直接 CliCommand を作って build_url を検証する。
fn into_internal(top: &TopCommand) -> CliCommand {
    match top {
        TopCommand::Wallpaper { action } => match action {
            WallpaperAction::Set { target } => CliCommand::WallpaperSet(target.clone()),
            WallpaperAction::Next => CliCommand::WallpaperNext,
            WallpaperAction::Prev => CliCommand::WallpaperPrev,
            WallpaperAction::Random => CliCommand::WallpaperRandom,
        },
        TopCommand::Playlist { action } => match action {
            PlaylistAction::Switch { id } => CliCommand::PlaylistSwitch(id.clone()),
        },
        TopCommand::Profile { action } => match action {
            ProfileAction::Switch { id } => CliCommand::ProfileSwitch(id.clone()),
        },
        TopCommand::Property { action } => match action {
            PropertyAction::Set { key, value } => CliCommand::PropertySet(key.clone(), value.clone()),
        },
    }
}

/// macOS の `open -g <url>` を呼び出す。
/// `-g` はフォアグラウンド遷移を抑える (バックグラウンド起動)。
/// macOS 以外では未実装メッセージを出して 1 で抜ける。
fn invoke_open(url: &str) {
    #[cfg(target_os = "macos")]
    {
        use std::process::Command;
        let status = Command::new("open").arg("-g").arg(url).status();
        match status {
            Ok(s) if s.success() => {}
            Ok(s) => {
                eprintln!("open コマンドが非ゼロ終了: {s}");
                std::process::exit(s.code().unwrap_or(1));
            }
            Err(e) => {
                eprintln!("open 実行に失敗: {e}");
                std::process::exit(1);
            }
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        eprintln!("artia-cli は現在 macOS のみで動作します (URL: {url})");
        std::process::exit(2);
    }
}
