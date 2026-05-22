import Foundation
import XCTest

@testable import Artia

/// Phase 6B: effect.json スキーマと Codable ラウンドトリップの検証。
final class EffectMetadataTests: XCTestCase {

    /// バンドル内 .effect.json をすべて拾う。
    private func allEffectJSONURLs() -> [URL] {
        let bundle = Bundle(for: type(of: self))
        let appBundle = Bundle.main
        let candidates = [bundle, appBundle]
        var urls: [URL] = []
        let fm = FileManager.default
        for b in candidates {
            guard let resourceURL = b.resourceURL else { continue }
            let enumerator = fm.enumerator(at: resourceURL,
                                           includingPropertiesForKeys: nil,
                                           options: [.skipsHiddenFiles])
            while let url = enumerator?.nextObject() as? URL {
                if url.lastPathComponent.hasSuffix(".effect.json") {
                    urls.append(url)
                }
            }
        }
        // 重複除外 (両 bundle に同じファイルがあった場合)
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.lastPathComponent).inserted }
    }

    func test_allBundledEffectJSONsParseSuccessfully() throws {
        let urls = allEffectJSONURLs()
        XCTAssertGreaterThanOrEqual(urls.count, 17, "想定 17 個の .effect.json が見つからない: \(urls.count)")
        var ids: Set<String> = []
        for url in urls {
            let data = try Data(contentsOf: url)
            do {
                let meta = try JSONDecoder().decode(EffectMetadata.self, from: data)
                XCTAssertFalse(meta.id.isEmpty, "id が空: \(url.lastPathComponent)")
                XCTAssertFalse(meta.metalFunction.isEmpty, "metalFunction が空: \(url.lastPathComponent)")
                ids.insert(meta.id)
            } catch {
                XCTFail("\(url.lastPathComponent) のパース失敗: \(error)")
            }
        }
        XCTAssertEqual(ids.count, urls.count, "id が重複している (\(ids))")
    }

    func test_codableRoundTrip_simpleMetadata() throws {
        let meta = EffectMetadata(
            id: "demo",
            displayName: "Demo",
            category: "post",
            metalFunction: "demoEffect",
            params: [
                ParamMeta(key: "intensity", label: "強度", type: .float,
                          defaultValue: .number(0.5), min: 0, max: 1, step: 0.01),
                ParamMeta(key: "enabled", label: "有効", type: .bool,
                          defaultValue: .bool(true)),
                ParamMeta(key: "tint", label: "色合い", type: .color,
                          defaultValue: .color(red: 1, green: 0.5, blue: 0, alpha: 1)),
                ParamMeta(key: "blend", label: "ブレンド", type: .enum,
                          defaultValue: .string("normal"), options: ["normal", "add"])
            ],
            audio: AudioBinding(source: "fft", binding: "bass",
                                bandIndex: 4, scale: 1.0))
        let data = try JSONEncoder().encode(meta)
        let back = try JSONDecoder().decode(EffectMetadata.self, from: data)
        XCTAssertEqual(meta, back)
    }

    func test_paramValue_decodesNumberBoolStringAndColor() throws {
        let json = """
        [0.5, true, "1 0.5 0", "freeText", [1, 2, 3]]
        """
        let arr = try JSONDecoder().decode([ParamValue].self, from: Data(json.utf8))
        XCTAssertEqual(arr[0], .number(0.5))
        XCTAssertEqual(arr[1], .bool(true))
        XCTAssertEqual(arr[2], .color(red: 1, green: 0.5, blue: 0, alpha: 1))
        XCTAssertEqual(arr[3], .string("freeText"))
        XCTAssertEqual(arr[4], .vec3(1, 2, 3))
    }

    func test_visibleCondition_codableRoundTrip() throws {
        let cond = VisibleCondition(key: "useMask", equals: .bool(true))
        let data = try JSONEncoder().encode(cond)
        let back = try JSONDecoder().decode(VisibleCondition.self, from: data)
        XCTAssertEqual(cond, back)
    }
}
