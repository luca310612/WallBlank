import XCTest
import Foundation

@testable import WallBlank

/// Phase 10E: PkgWriterBridge → Rust pkg_writer 経由で .wallpaper を書き出し、
///            ZIP として読み戻して同一性を検証する。
/// 既存 PkgReaderSimple は Wallpaper Engine 形式 (PKGV magic) 専用のため、
/// WallBlank 独自 .wallpaper の読み戻しには Foundation の処理を使わず Process unzip で確認する。
final class PkgWriterBridgeTests: XCTestCase {

    func test_writeSimple_producesValidZipWithExpectedEntries() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("artia-pkgwriter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let assetURL = tmp.appendingPathComponent("preview.png")
        // 適当な PNG ヘッダ風のバイナリ
        let assetBytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF, 0xAB, 0xCD]
        try Data(assetBytes).write(to: assetURL)

        let outURL = tmp.appendingPathComponent("out.wallpaper")

        try PkgWriterBridge.writeSimple(
            outputPath: outURL.path,
            title: "テスト壁紙",
            description: "PkgWriter ラウンドトリップ",
            tags: ["aurora", "夜"],
            typeName: "scene",
            assets: [.init(name: "preview.png", path: assetURL.path)]
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))

        // unzip で中身を一覧 → manifest.json / project.json / scene.json / assets/preview.png が揃っていること
        let extractDir = tmp.appendingPathComponent("extract", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", outURL.path, "-d", extractDir.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "unzip 成功")

        let listed = try FileManager.default.contentsOfDirectory(atPath: extractDir.path)
        XCTAssertTrue(listed.contains("manifest.json"))
        XCTAssertTrue(listed.contains("project.json"))
        XCTAssertTrue(listed.contains("scene.json"))

        // assets ディレクトリに preview.png が同一で復元できる
        let restoredAsset = extractDir.appendingPathComponent("assets/preview.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredAsset.path))
        let restored = try Data(contentsOf: restoredAsset)
        XCTAssertEqual(restored, Data(assetBytes))

        // project.json に title / tags が反映されている
        let project = try Data(contentsOf: extractDir.appendingPathComponent("project.json"))
        let dict = try JSONSerialization.jsonObject(with: project) as? [String: Any]
        XCTAssertEqual(dict?["title"] as? String, "テスト壁紙")
        XCTAssertEqual(dict?["type"] as? String, "scene")
        XCTAssertEqual((dict?["tags"] as? [String]).map(Set.init), Set(["aurora", "夜"]))

        // manifest.json に WallBlank 独自 magic と version が入っている
        let manifest = try Data(contentsOf: extractDir.appendingPathComponent("manifest.json"))
        let manifestDict = try JSONSerialization.jsonObject(with: manifest) as? [String: Any]
        XCTAssertEqual(manifestDict?["magic"] as? String, "ArtiaPkg")
        XCTAssertEqual(manifestDict?["version"] as? Int, 1)
    }

    func test_write_failsWhenAssetMissing() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("artia-pkgwriter-missing-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let outURL = tmp.appendingPathComponent("out.wallpaper")
        do {
            try PkgWriterBridge.writeSimple(
                outputPath: outURL.path,
                title: "missing", description: "", tags: [],
                typeName: "image",
                assets: [.init(name: "x.png", path: tmp.appendingPathComponent("does-not-exist.png").path)]
            )
            XCTFail("欠落アセットでエラーが期待される")
        } catch let error as PkgWriterBridge.WriteError {
            // Rust 側は false を返す → rustReturnedFalse
            XCTAssertEqual(error.localizedDescription, PkgWriterBridge.WriteError.rustReturnedFalse.localizedDescription)
        } catch {
            XCTFail("想定外のエラー: \(error)")
        }
    }
}
