// cbindgen でCヘッダーを自動生成する

fn main() {
    let crate_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let output_dir = std::path::Path::new(&crate_dir).join("generated");

    // generated/ ディレクトリがなければ作成
    std::fs::create_dir_all(&output_dir).expect("generatedディレクトリの作成に失敗");

    let config = cbindgen::Config {
        language: cbindgen::Language::C,
        include_guard: Some("ARTIA_FFI_H".to_string()),
        no_includes: true,
        sys_includes: vec![
            "stdarg.h".to_string(),
            "stdbool.h".to_string(),
            "stdint.h".to_string(),
            "stdlib.h".to_string(),
        ],
        autogen_warning: Some(
            "// このファイルはcbindgenにより自動生成されています。手動で編集しないでください。"
                .to_string(),
        ),
        ..Default::default()
    };

    cbindgen::Builder::new()
        .with_crate(crate_dir)
        .with_config(config)
        .generate()
        .expect("cbindgenによるヘッダー生成に失敗")
        .write_to_file(output_dir.join("artia_ffi.h"));
}
