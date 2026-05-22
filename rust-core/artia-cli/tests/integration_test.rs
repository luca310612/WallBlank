//! Phase 8.4: artia-cli 統合テスト
//!
//! `cargo test -p artia-cli` で実行され、CLI バイナリを呼び出して --dry-run の出力を検証する。
//! `--dry-run` モードは URL を組み立てて stdout に出すだけなので、open(1) 副作用なしで
//! ラウンドトリップ (subcommand → URL) を確認できる。

use std::process::Command;

fn run_dry(args: &[&str]) -> String {
    let bin = env!("CARGO_BIN_EXE_artia-cli");
    let output = Command::new(bin)
        .arg("--dry-run")
        .args(args)
        .output()
        .expect("artia-cli が実行できません");
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("stdout は UTF-8 のはず")
        .trim()
        .to_string()
}

#[test]
fn wallpaper_set_id() {
    let url = run_dry(&["wallpaper", "set", "wp123"]);
    assert_eq!(url, "artia://wallpaper/set/wp123");
}

#[test]
fn wallpaper_set_path_with_space_encodes() {
    let url = run_dry(&["wallpaper", "set", "/tmp/wall paper.png"]);
    assert_eq!(url, "artia://wallpaper/set/%2Ftmp%2Fwall%20paper.png");
}

#[test]
fn wallpaper_next() {
    assert_eq!(run_dry(&["wallpaper", "next"]), "artia://wallpaper/next");
}

#[test]
fn wallpaper_prev() {
    assert_eq!(run_dry(&["wallpaper", "prev"]), "artia://wallpaper/prev");
}

#[test]
fn wallpaper_random() {
    assert_eq!(run_dry(&["wallpaper", "random"]), "artia://wallpaper/random");
}

#[test]
fn playlist_switch() {
    assert_eq!(
        run_dry(&["playlist", "switch", "morning-mix"]),
        "artia://playlist/switch/morning-mix"
    );
}

#[test]
fn profile_switch() {
    assert_eq!(
        run_dry(&["profile", "switch", "ultra"]),
        "artia://profile/switch/ultra"
    );
}

#[test]
fn property_set() {
    assert_eq!(
        run_dry(&["property", "set", "fps", "30"]),
        "artia://property/set/fps/30"
    );
}

#[test]
fn property_set_with_special_chars() {
    let url = run_dry(&["property", "set", "audio gain", "0.75"]);
    assert_eq!(url, "artia://property/set/audio%20gain/0.75");
}
