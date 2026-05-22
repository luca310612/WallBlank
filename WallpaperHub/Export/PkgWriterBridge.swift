import Foundation

/// Phase 10D: Artia 独自 .wallpaper パッケージ書き出しの Swift エントリ。
///
/// Rust 側 `artia_pkg_write` を呼び出し、project.json + scene.json + assets/* を
/// ZIP コンテナに格納した Artia 独自フォーマット (.wallpaper) を生成する。
/// Wallpaper Engine の .pkg バイナリとは互換性 100% にはしない方針 (CLAUDE.md 設計判断)。
enum PkgWriterBridge {

    /// 書き込みエラー。
    enum WriteError: LocalizedError {
        /// JSON シリアライズに失敗
        case encoding(String)
        /// Rust 側が false を返した (詳細は標準ログ参照)
        case rustReturnedFalse

        var errorDescription: String? {
            switch self {
            case .encoding(let detail): return "PkgWriter ペイロード生成に失敗: \(detail)"
            case .rustReturnedFalse: return "PkgWriter (Rust) 側で書き込みが失敗しました"
            }
        }
    }

    /// 公開用パッケージのアセット情報。
    struct AssetEntry: Codable {
        /// ZIP 内エントリ名 (例: "preview.png")
        let name: String
        /// 実ファイルへの絶対パス
        let path: String
    }

    /// 書き込み入力。Rust 側 `PkgWriteDescriptor` と JSON 互換。
    struct WriteInput: Codable {
        let output_path: String
        let project_json: String
        let scene_json: String
        let assets: [AssetEntry]
    }

    /// 公開用パッケージを書き出す。
    /// - Parameters:
    ///   - outputPath: 書き出し先 (.wallpaper)
    ///   - projectJSON: project.json として埋め込む文字列
    ///   - sceneJSON: scene.json として埋め込む文字列
    ///   - assets: 同梱するアセット (name + path)
    /// - Throws: 失敗時は `WriteError`
    static func write(
        outputPath: String,
        projectJSON: String,
        sceneJSON: String,
        assets: [AssetEntry]
    ) throws {
        let input = WriteInput(
            output_path: outputPath,
            project_json: projectJSON,
            scene_json: sceneJSON,
            assets: assets
        )
        let data: Data
        do {
            data = try JSONEncoder().encode(input)
        } catch {
            throw WriteError.encoding(String(describing: error))
        }
        guard let json = String(data: data, encoding: .utf8) else {
            throw WriteError.encoding("UTF-8 変換失敗")
        }
        let ok: Bool = json.withCString { artia_pkg_write($0) }
        if !ok {
            throw WriteError.rustReturnedFalse
        }
    }

    /// 既存の `WallpaperItem` から書き出す簡易ヘルパー。
    /// project.json と scene.json は最低限の Artia メタデータで埋める。
    /// - Parameters:
    ///   - outputPath: 出力先 (.wallpaper)
    ///   - title: 作品タイトル
    ///   - description: 説明文
    ///   - tags: タグ
    ///   - typeName: "scene" / "video" / "image" / "web" / "app"
    ///   - assets: 同梱するアセット (name + path)
    static func writeSimple(
        outputPath: String,
        title: String,
        description: String,
        tags: [String],
        typeName: String,
        assets: [AssetEntry]
    ) throws {
        let project: [String: Any] = [
            "title": title,
            "description": description,
            "type": typeName,
            "tags": tags,
            "format": "artia.wallpaper",
            "version": 1,
        ]
        let scene: [String: Any] = [
            "version": 1,
            "layers": [],
        ]
        let projectData = try JSONSerialization.data(withJSONObject: project, options: [.sortedKeys])
        let sceneData = try JSONSerialization.data(withJSONObject: scene, options: [.sortedKeys])
        guard let projectStr = String(data: projectData, encoding: .utf8),
              let sceneStr = String(data: sceneData, encoding: .utf8) else {
            throw WriteError.encoding("JSON UTF-8 変換失敗")
        }
        try write(
            outputPath: outputPath,
            projectJSON: projectStr,
            sceneJSON: sceneStr,
            assets: assets
        )
    }
}
