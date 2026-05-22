import Foundation
import Combine

// MARK: - ブラシプリセットライブラリ
// Why: プリセットの一覧管理・永続化・組み込み配布を1ヶ所に集約。
// 永続化は App Group コンテナ配下にプリセット 1 件 1 ファイル(JSON)で保存し、
// 将来のウィジェット連携 / iCloud 同期に拡張しやすい構造とする。

/// ブラシプリセットの作成・読み込み・保存を担うシングルトン
@MainActor
final class BrushPresetLibrary: ObservableObject {
    static let shared = BrushPresetLibrary()

    /// 表示順にソート済みのプリセット一覧
    @Published private(set) var presets: [BrushPreset] = []

    /// 現在選択中のプリセット ID（未選択時 nil）
    @Published var activePresetID: UUID? {
        didSet {
            UserDefaults.standard.set(activePresetID?.uuidString, forKey: Self.activeIDKey)
        }
    }

    private static let appGroup = "group.com.artia.shared"
    private static let activeIDKey = "artia.brushPresets.activeID.v1"

    /// 永続化先ディレクトリ（App Group が無い場合は ~/Library/Application Support/WallBlank/BrushPresets）
    private let storageDirectory: URL

    private convenience init() {
        self.init(directoryURL: nil)
    }

    /// 任意の保存先ディレクトリを差し込めるテスト用イニシャライザ。
    /// - Parameter directoryURL: nil の場合は App Group / Application Support にフォールバック。
    /// - Note: production の `shared` は引数なし `init()` 経由でデフォルト挙動のまま。
    init(directoryURL: URL?) {
        if let directoryURL {
            storageDirectory = directoryURL
        } else if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup) {
            storageDirectory = groupURL.appendingPathComponent("BrushPresets", isDirectory: true)
        } else {
            // フォールバック: App Group が利用できない環境（テスト等）
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            storageDirectory = appSupport
                .appendingPathComponent("WallBlank", isDirectory: true)
                .appendingPathComponent("BrushPresets", isDirectory: true)
        }

        ensureStorageDirectoryExists()
        bootstrap()
        restoreActiveID()
    }

    /// アプリ起動直後に呼び出し可能な初期化エントリ。
    /// - 旧 BrushPresetManager(単一 JSON)からの移行を 1 度だけ実行
    /// - 同梱 JSON プリセット (Resources/BrushPresets) を読み込み、
    ///   コード内蔵 fallback を確実にユーザー領域へ反映
    func bootstrap() {
        BrushPresetMigration.migrateIfNeeded(targetDirectory: storageDirectory)
        load()
    }

    // MARK: - 読み込み

    func load() {
        var loaded: [BrushPreset] = []

        // ユーザー保存プリセットを先にロード
        if let files = try? FileManager.default.contentsOfDirectory(
            at: storageDirectory,
            includingPropertiesForKeys: nil
        ) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            for url in files where url.pathExtension == "json" {
                if let data = try? Data(contentsOf: url),
                   let preset = try? decoder.decode(BrushPreset.self, from: data) {
                    loaded.append(preset)
                }
            }
        }

        // 組み込みプリセットをマージ（既存 ID が無ければ追加）。
        // bundle 同梱 JSON を優先し、欠落時のみコード内蔵 fallback を使う。
        let existingIDs = Set(loaded.map(\.id))
        let bundled = Self.bundledBuiltInPresets()
        let bundledIDs = Set(bundled.map(\.id))
        for builtIn in bundled where !existingIDs.contains(builtIn.id) {
            loaded.append(builtIn)
        }
        for builtIn in Self.builtInPresets where !existingIDs.contains(builtIn.id) && !bundledIDs.contains(builtIn.id) {
            loaded.append(builtIn)
        }

        presets = loaded.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    /// `Resources/BrushPresets/*.json` を読み込んで組み込みプリセット一覧として返す。
    /// - Note: 取得できなかった場合は空配列。fallback はコード内蔵 `builtInPresets`。
    static func bundledBuiltInPresets(bundle: Bundle = .main) -> [BrushPreset] {
        let names = ["soft-round", "hard-round", "airbrush", "marker"]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var results: [BrushPreset] = []
        for name in names {
            guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "BrushPresets")
                ?? bundle.url(forResource: name, withExtension: "json") else {
                continue
            }
            if let data = try? Data(contentsOf: url),
               var preset = try? decoder.decode(BrushPreset.self, from: data) {
                // 同梱 JSON 由来は常に isBuiltIn=true を強制する (改ざん防止)
                preset.isBuiltIn = true
                results.append(preset)
            }
        }
        return results
    }

    private func restoreActiveID() {
        guard let raw = UserDefaults.standard.string(forKey: Self.activeIDKey),
              let uuid = UUID(uuidString: raw),
              presets.contains(where: { $0.id == uuid }) else {
            activePresetID = nil
            return
        }
        activePresetID = uuid
    }

    // MARK: - 書き込み

    /// プリセットを保存（既存があれば上書き、無ければ追加）。組み込みは複製されてユーザー領域に保存。
    @discardableResult
    func save(_ preset: BrushPreset) throws -> BrushPreset {
        var stored = preset
        if stored.isBuiltIn {
            // 組み込みは編集不可。複製を作成してユーザー側に保存する
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

        try writeToDisk(stored)

        if let idx = presets.firstIndex(where: { $0.id == stored.id }) {
            presets[idx] = stored
        } else {
            presets.append(stored)
        }
        sortPresetsInPlace()
        return stored
    }

    /// プリセットを削除（組み込みは無視）
    func delete(_ id: UUID) throws {
        guard let preset = presets.first(where: { $0.id == id }), !preset.isBuiltIn else { return }
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        presets.removeAll { $0.id == id }
        if activePresetID == id { activePresetID = nil }
    }

    /// プリセットを複製
    @discardableResult
    func duplicate(_ id: UUID) throws -> BrushPreset {
        guard let source = presets.first(where: { $0.id == id }) else {
            throw NSError(domain: "BrushPresetLibrary", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "複製元のプリセットが見つかりません"])
        }
        let copy = BrushPreset(
            name: source.name + " のコピー",
            iconSystemName: source.iconSystemName,
            stroke: source.stroke,
            maskPost: source.maskPost,
            gradient: source.gradient,
            isBuiltIn: false,
            sortOrder: nextSortOrder()
        )
        return try save(copy)
    }

    /// 現在のツール設定からプリセットを生成して保存
    @discardableResult
    func captureAndSave(from settings: EditorToolSettings, name: String, icon: String = "paintbrush.pointed") throws -> BrushPreset {
        var preset = BrushPreset.capture(from: settings, name: name, icon: icon)
        preset.sortOrder = nextSortOrder()
        return try save(preset)
    }

    // MARK: - 適用

    /// プリセットをツール設定に流し込み、選択状態を更新
    func apply(_ id: UUID, to settings: inout EditorToolSettings) {
        guard let preset = presets.first(where: { $0.id == id }) else { return }
        preset.apply(to: &settings)
        activePresetID = id
    }

    // MARK: - 内部

    private func ensureStorageDirectoryExists() {
        if !FileManager.default.fileExists(atPath: storageDirectory.path) {
            try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        }
    }

    private func fileURL(for id: UUID) -> URL {
        storageDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private func writeToDisk(_ preset: BrushPreset) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(preset)
        try data.write(to: fileURL(for: preset.id), options: .atomic)
    }

    private func sortPresetsInPlace() {
        presets.sort { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    private func nextSortOrder() -> Int {
        (presets.map(\.sortOrder).max() ?? 100) + 1
    }
}

// MARK: - 組み込みプリセット
// Why: 起動直後にユーザーが選べる初期セットを Swift 内蔵として配布する。
// JSON ファイル配布に切り替える拡張は後続フェーズ（Effect Registry と同タイミング）で実施。
extension BrushPresetLibrary {
    /// 組み込みプリセット ID は固定 UUID（マイグレーション時に同一性を保つため）
    private enum BuiltInID {
        static let softRound = UUID(uuidString: "B0000001-0000-4000-8000-000000000001")!
        static let hardRound = UUID(uuidString: "B0000002-0000-4000-8000-000000000002")!
        static let airbrush  = UUID(uuidString: "B0000003-0000-4000-8000-000000000003")!
        static let marker    = UUID(uuidString: "B0000004-0000-4000-8000-000000000004")!
    }

    static let builtInPresets: [BrushPreset] = [
        BrushPreset(
            id: BuiltInID.softRound,
            name: "ソフト円",
            iconSystemName: "circle.fill",
            stroke: EditorBrushStrokeSettings(
                diameterPixels: 60,
                hardness: 0.2,
                opacity: 1.0,
                flow: 1.0,
                smoothingPercent: 10,
                paintMode: .normal
            ),
            isBuiltIn: true,
            sortOrder: 10
        ),
        BrushPreset(
            id: BuiltInID.hardRound,
            name: "ハード円",
            iconSystemName: "circle.dashed.inset.filled",
            stroke: EditorBrushStrokeSettings(
                diameterPixels: 30,
                hardness: 0.95,
                opacity: 1.0,
                flow: 1.0,
                smoothingPercent: 10,
                paintMode: .normal
            ),
            isBuiltIn: true,
            sortOrder: 20
        ),
        BrushPreset(
            id: BuiltInID.airbrush,
            name: "エアブラシ",
            iconSystemName: "wind",
            stroke: EditorBrushStrokeSettings(
                diameterPixels: 80,
                hardness: 0.1,
                opacity: 0.5,
                flow: 0.2,
                smoothingPercent: 30,
                paintMode: .add
            ),
            isBuiltIn: true,
            sortOrder: 30
        ),
        BrushPreset(
            id: BuiltInID.marker,
            name: "マーカー",
            iconSystemName: "highlighter",
            stroke: EditorBrushStrokeSettings(
                diameterPixels: 24,
                hardness: 0.7,
                opacity: 0.85,
                flow: 1.0,
                smoothingPercent: 5,
                paintMode: .normal
            ),
            isBuiltIn: true,
            sortOrder: 40
        )
    ]
}
