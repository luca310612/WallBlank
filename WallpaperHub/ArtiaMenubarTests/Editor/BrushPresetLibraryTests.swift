import Foundation
import XCTest

@testable import WallBlank

/// BrushPresetLibrary / BrushPresetMigration の単体テスト。
/// - 同梱 4 プリセット読み込み
/// - save / delete / duplicate ラウンドトリップ
/// - v1 単一 JSON → per-file 移行で重複登録が出ないこと
@MainActor
final class BrushPresetLibraryTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrushPresetLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - 同梱 4 プリセット

    func test_bundledBuiltInsResolveAllFour() {
        let bundle = Bundle(for: Self.self)
        // テストバンドルが本体の Resources/BrushPresets/ にアクセスできない場合に備え、
        // メインバンドルもフォールバック対象とする。
        let mainBundle = Bundle.main
        let fromTest = BrushPresetLibrary.bundledBuiltInPresets(bundle: bundle)
        let fromMain = BrushPresetLibrary.bundledBuiltInPresets(bundle: mainBundle)
        let resolved = !fromTest.isEmpty ? fromTest : fromMain
        XCTAssertEqual(resolved.count, 4, "soft-round / hard-round / airbrush / marker の 4 件が読み込まれるべき")
        XCTAssertTrue(resolved.allSatisfy { $0.isBuiltIn })
        XCTAssertEqual(Set(resolved.map(\.name)), Set(["ソフト円", "ハード円", "エアブラシ", "マーカー"]))
    }

    // MARK: - save / delete / duplicate ラウンドトリップ

    func test_saveDeleteDuplicateRoundTrip() throws {
        // Why: シングルトンの shared を共有すると App Group コンテナ / Application Support
        //      のサンドボックス制約で I/O がブロックする環境がある。
        //      テストはローカル temp ディレクトリを注入した別インスタンスで実行する。
        let library = BrushPresetLibrary(directoryURL: tempDir)
        let beforeCount = library.presets.count

        // 新規保存
        let newPreset = try library.captureAndSave(
            from: EditorToolSettings(),
            name: "テスト用プリセット-\(UUID().uuidString.prefix(6))"
        )
        XCTAssertEqual(library.presets.count, beforeCount + 1)
        XCTAssertTrue(library.presets.contains(where: { $0.id == newPreset.id }))

        // 複製
        let duplicated = try library.duplicate(newPreset.id)
        XCTAssertEqual(library.presets.count, beforeCount + 2)
        XCTAssertNotEqual(duplicated.id, newPreset.id)
        XCTAssertTrue(duplicated.name.contains("コピー"))

        // 削除（後始末を兼ねる）
        try library.delete(duplicated.id)
        try library.delete(newPreset.id)
        XCTAssertEqual(library.presets.count, beforeCount)
    }

    // MARK: - v1 → v2 移行

    func test_legacySingleJSONMigratesToPerFileWithoutDuplicates() throws {
        // 旧形式の JSON を生成 (BrushPresetManager 互換)
        let legacyPresets: [BrushPreset] = [
            BrushPreset(
                id: UUID(),
                name: "移行テスト A",
                stroke: EditorBrushStrokeSettings(diameterPixels: 50),
                isBuiltIn: false,
                sortOrder: 200
            ),
            BrushPreset(
                id: UUID(),
                name: "移行テスト B",
                stroke: EditorBrushStrokeSettings(diameterPixels: 70),
                isBuiltIn: false,
                sortOrder: 201
            )
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacyData = try encoder.encode(legacyPresets)

        // ダミーの「単一 JSON」ファイルを期待パスに直接置く
        let legacyParent = BrushPresetMigration.legacyFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: legacyParent, withIntermediateDirectories: true)
        try legacyData.write(to: BrushPresetMigration.legacyFileURL, options: .atomic)

        // 専用 UserDefaults を用意して migration をリセットする
        let suiteName = "BrushPresetMigration.test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("UserDefaults suite を確保できませんでした"); return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let didRun = BrushPresetMigration.migrateIfNeeded(
            targetDirectory: tempDir,
            defaults: defaults
        )
        XCTAssertTrue(didRun, "旧 JSON が存在する場合は migration が走ること")
        XCTAssertTrue(defaults.bool(forKey: BrushPresetMigration.completedKey))

        // 同じ targetDirectory に対して 2 度目を走らせても重複ファイルが作られないことを検証
        let preMigrateFiles = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(preMigrateFiles.count, legacyPresets.count, "ユーザー作成プリセット 2 件が per-file 化されること")

        let didRunAgain = BrushPresetMigration.migrateIfNeeded(
            targetDirectory: tempDir,
            defaults: defaults
        )
        XCTAssertFalse(didRunAgain, "完了フラグ後は再実行されないこと")

        let postMigrateFiles = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(postMigrateFiles.count, preMigrateFiles.count, "再実行で重複登録されないこと")

        // 後始末: 旧 JSON を消す
        try? FileManager.default.removeItem(at: BrushPresetMigration.legacyFileURL)
    }
}
