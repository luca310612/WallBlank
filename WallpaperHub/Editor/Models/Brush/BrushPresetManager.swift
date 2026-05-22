import Foundation
import Combine

// MARK: - ブラシプリセットマネージャ (Phase 1.1)
// Why: ロードマップ Phase 1.1 で要求された「単一 JSON ファイルでのブラシプリセット永続化」を、
// 既存の BrushPresetLibrary(App Group + ファイル分散保存) と並列に提供する。
// - 保存先は ~/Library/Application Support/Artia/brush_presets.json に統一
// - 既存の per-file 永続化(BrushPresetLibrary) を破壊せずに「後付け」で導入し、
//   初回起動時のみ既存 per-file プリセットを単一ファイルへ自動マイグレートする。

/// 単一 JSON ファイルにブラシプリセット一覧を保存する Singleton + ObservableObject。
@MainActor
final class BrushPresetManager: ObservableObject {
    static let shared = BrushPresetManager()

    /// 表示順にソート済みのプリセット一覧
    @Published private(set) var presets: [BrushPreset] = []

    /// 永続化先ファイル (~/Library/Application Support/Artia/brush_presets.json)
    private let storageURL: URL

    /// 既存 BrushPresetLibrary の per-file 保存ディレクトリ (App Group が無い場合のみ存在)
    private let legacyStorageDirectory: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let artiaDir = appSupport.appendingPathComponent("Artia", isDirectory: true)
        storageURL = artiaDir.appendingPathComponent("brush_presets.json")
        legacyStorageDirectory = artiaDir.appendingPathComponent("BrushPresets", isDirectory: true)

        ensureParentDirectoryExists()
        load()
    }

    // MARK: - 読み込み

    /// ディスクから単一ファイルを読み込む。未存在なら legacy per-file 保存からマイグレートを試行。
    func load() {
        var loaded: [BrushPreset] = []

        if FileManager.default.fileExists(atPath: storageURL.path) {
            if let data = try? Data(contentsOf: storageURL) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let decoded = try? decoder.decode([BrushPreset].self, from: data) {
                    loaded = decoded
                }
            }
        } else {
            // 単一ファイル未生成 → 既存 per-file プリセットから 1 度だけマイグレート
            loaded = migrateFromLegacyPerFileStorage()
        }

        // 組み込みプリセットを ID ベースでマージ (BrushPresetLibrary と整合)
        let existingIDs = Set(loaded.map(\.id))
        for builtIn in BrushPresetLibrary.builtInPresets {
            if !existingIDs.contains(builtIn.id) {
                loaded.append(builtIn)
            }
        }

        presets = sorted(loaded)

        // マイグレート結果や組み込み補完を即座に永続化
        try? writeToDisk()
    }

    // MARK: - 書き込み

    /// プリセットを保存 (既存があれば上書き、無ければ追加)。組み込みは複製して保存。
    @discardableResult
    func save(_ preset: BrushPreset) throws -> BrushPreset {
        var stored = preset
        if stored.isBuiltIn {
            stored = BrushPreset(
                name: preset.name + " のコピー",
                iconSystemName: preset.iconSystemName,
                stroke: preset.stroke,
                maskPost: preset.maskPost,
                gradient: preset.gradient,
                isBuiltIn: false,
                sortOrder: nextSortOrder()
            )
        } else {
            stored.updatedAt = Date()
        }

        if let idx = presets.firstIndex(where: { $0.id == stored.id }) {
            presets[idx] = stored
        } else {
            presets.append(stored)
        }
        presets = sorted(presets)
        try writeToDisk()
        return stored
    }

    /// プリセットを削除 (組み込みは無視)。
    func delete(_ id: UUID) throws {
        guard let preset = presets.first(where: { $0.id == id }), !preset.isBuiltIn else { return }
        presets.removeAll { $0.id == preset.id }
        try writeToDisk()
    }

    /// 現在のツール設定からプリセットを生成して保存。
    @discardableResult
    func captureAndSave(from settings: EditorToolSettings, name: String, icon: String = "paintbrush.pointed") throws -> BrushPreset {
        var preset = BrushPreset.capture(from: settings, name: name, icon: icon)
        preset.sortOrder = nextSortOrder()
        return try save(preset)
    }

    // MARK: - 内部

    private func ensureParentDirectoryExists() {
        let parent = storageURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
    }

    private func writeToDisk() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(presets)
        try data.write(to: storageURL, options: .atomic)
    }

    /// 既存 BrushPresetLibrary が書き出した per-file JSON を読み込んで単一ファイルへ統合。
    private func migrateFromLegacyPerFileStorage() -> [BrushPreset] {
        guard FileManager.default.fileExists(atPath: legacyStorageDirectory.path),
              let files = try? FileManager.default.contentsOfDirectory(
                at: legacyStorageDirectory,
                includingPropertiesForKeys: nil
              ) else {
            return []
        }
        var migrated: [BrushPreset] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for url in files where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let preset = try? decoder.decode(BrushPreset.self, from: data) {
                migrated.append(preset)
            }
        }
        return migrated
    }

    private func sorted(_ list: [BrushPreset]) -> [BrushPreset] {
        list.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    private func nextSortOrder() -> Int {
        (presets.map(\.sortOrder).max() ?? 100) + 1
    }
}
