import Foundation

// MARK: - ブラシプリセットの v1 → v2 移行
// Why: Phase 1.1 で導入した BrushPresetManager が単一 JSON
//      (~/Library/Application Support/Artia/brush_presets.json) に保存していた
//      ユーザー作成プリセットを、Phase 1.1+ の per-preset JSON ストレージへ
//      1 度だけ移送する。済みフラグは UserDefaults に書く。

enum BrushPresetMigration {

    /// 移行完了フラグ（UserDefaults キー）
    static let completedKey = "artia.brushPresets.legacyToPerFile.completed.v1"

    /// 単一 JSON のファイル名（BrushPresetManager 互換）
    private static let legacyFileName = "brush_presets.json"

    /// 単一 JSON 配置先（Application Support/Artia）
    /// - Note: BrushPresetManager と同じパス解決ロジックに合わせる。
    static var legacyFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport
            .appendingPathComponent("Artia", isDirectory: true)
            .appendingPathComponent(legacyFileName)
    }

    /// 1 度だけ実行する移行手順。
    /// - Parameter targetDirectory: per-preset JSON 保存ディレクトリ (BrushPresetLibrary.storageDirectory)
    /// - Parameter defaults: 履歴管理用 UserDefaults (テスト時に差し替え可能)
    /// - Returns: 移行が走った場合 true。既に済 / 旧ファイル無し / 失敗時は false。
    @discardableResult
    static func migrateIfNeeded(
        targetDirectory: URL,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) -> Bool {
        if defaults.bool(forKey: completedKey) { return false }

        let source = legacyFileURL
        guard fileManager.fileExists(atPath: source.path) else {
            // 旧ファイルが無ければ「済み」として扱い、以降の I/O を抑止する
            defaults.set(true, forKey: completedKey)
            return false
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: source),
              let presets = try? decoder.decode([BrushPreset].self, from: data) else {
            // 壊れた JSON は無視。再試行で巻き込まないようフラグだけ立てる。
            defaults.set(true, forKey: completedKey)
            return false
        }

        // 出力先ディレクトリを準備
        if !fileManager.fileExists(atPath: targetDirectory.path) {
            try? fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        var migratedCount = 0
        for preset in presets {
            // 組み込みプリセットは bundle / コードから別経路で配布されるためスキップ
            if preset.isBuiltIn { continue }
            let dest = targetDirectory.appendingPathComponent("\(preset.id.uuidString).json")
            // 既に per-file 側に同 ID があれば二重書き込みしない（duplicate 防止）
            if fileManager.fileExists(atPath: dest.path) { continue }
            if let payload = try? encoder.encode(preset) {
                try? payload.write(to: dest, options: .atomic)
                migratedCount += 1
            }
        }

        defaults.set(true, forKey: completedKey)
        return migratedCount > 0
    }
}
