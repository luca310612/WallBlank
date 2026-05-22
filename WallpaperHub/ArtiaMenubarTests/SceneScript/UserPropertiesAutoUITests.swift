import Foundation
import JavaScriptCore
import XCTest

@testable import Artia

/// Phase 5: project.json パース / Codable / Store / SceneScript+Web 連携の検証。
final class UserPropertiesAutoUITests: XCTestCase {

    // MARK: - Project parser

    func test_projectParser_parsesAllSupportedTypes() throws {
        let json = """
        {
          "general": {
            "properties": {
              "color1": { "type": "color", "value": "1 0 0", "label": "Color 1", "order": 0 },
              "speed":  { "type": "slider", "value": 1.5, "min": 0, "max": 5, "label": "Speed", "order": 1 },
              "enabled": { "type": "bool", "value": true, "label": "Enabled", "order": 2 },
              "title":   { "type": "text", "value": "hi", "label": "Title", "order": 3 },
              "mode":    { "type": "combo", "value": "a",
                           "options": [{"value":"a","label":"A"},{"value":"b","label":"B"}],
                           "label": "Mode", "order": 4 }
            }
          }
        }
        """
        let defs = UserPropertiesProjectParser.parse(jsonData: Data(json.utf8))
        XCTAssertEqual(defs.count, 5)
        let byKey = Dictionary(uniqueKeysWithValues: defs.map { ($0.key, $0.kind) })

        if case let .color(c) = byKey["color1"] {
            XCTAssertEqual(c.r, 1.0, accuracy: 1e-6)
            XCTAssertEqual(c.g, 0.0, accuracy: 1e-6)
            XCTAssertEqual(c.b, 0.0, accuracy: 1e-6)
        } else {
            XCTFail("color1 が color にならなかった")
        }

        if case let .slider(v, mn, mx) = byKey["speed"] {
            XCTAssertEqual(v, 1.5, accuracy: 1e-6)
            XCTAssertEqual(mn, 0.0, accuracy: 1e-6)
            XCTAssertEqual(mx, 5.0, accuracy: 1e-6)
        } else {
            XCTFail("speed が slider にならなかった")
        }

        if case let .bool(b) = byKey["enabled"] {
            XCTAssertTrue(b)
        } else {
            XCTFail("enabled が bool にならなかった")
        }

        if case let .text(s) = byKey["title"] {
            XCTAssertEqual(s, "hi")
        } else {
            XCTFail("title が text にならなかった")
        }

        if case let .combo(v, opts) = byKey["mode"] {
            XCTAssertEqual(v, "a")
            XCTAssertEqual(opts.map { $0.value }, ["a", "b"])
        } else {
            XCTFail("mode が combo にならなかった")
        }
    }

    func test_projectParser_returnsEmptyForMalformedInput() {
        let defs = UserPropertiesProjectParser.parse(jsonData: Data("not json".utf8))
        XCTAssertTrue(defs.isEmpty)
    }

    func test_projectParser_sortsByOrderThenKey() {
        let json = """
        {"general":{"properties":{
          "b":{"type":"slider","value":0,"order":1},
          "a":{"type":"slider","value":0,"order":1},
          "c":{"type":"slider","value":0,"order":0}
        }}}
        """
        let defs = UserPropertiesProjectParser.parse(jsonData: Data(json.utf8))
        XCTAssertEqual(defs.map { $0.key }, ["c", "a", "b"])
    }

    // MARK: - UserPropertyValue codable

    func test_userPropertyValue_codableRoundTrip_number() throws {
        let v: UserPropertyValue = .number(3.14)
        let data = try JSONEncoder().encode(["k": v])
        let back = try JSONDecoder().decode([String: UserPropertyValue].self, from: data)
        XCTAssertEqual(back["k"], .number(3.14))
    }

    func test_userPropertyValue_codableRoundTrip_color() throws {
        let v: UserPropertyValue = .color(.init(r: 0.1, g: 0.2, b: 0.3))
        let data = try JSONEncoder().encode(["k": v])
        let back = try JSONDecoder().decode([String: UserPropertyValue].self, from: data)
        if case let .color(c) = back["k"] {
            XCTAssertEqual(c.r, 0.1, accuracy: 1e-6)
            XCTAssertEqual(c.g, 0.2, accuracy: 1e-6)
            XCTAssertEqual(c.b, 0.3, accuracy: 1e-6)
        } else {
            XCTFail("color round trip 失敗")
        }
    }

    func test_userPropertyValue_codableRoundTrip_boolAndText() throws {
        let payload: [String: UserPropertyValue] = ["b": .bool(true), "t": .text("hello")]
        let data = try JSONEncoder().encode(payload)
        let back = try JSONDecoder().decode([String: UserPropertyValue].self, from: data)
        XCTAssertEqual(back["b"], .bool(true))
        XCTAssertEqual(back["t"], .text("hello"))
    }

    // MARK: - Store

    func test_store_subscribe_firesOnSet() {
        let store = UserPropertiesStore()
        var received: [[String: UserPropertyValue]] = []
        store.subscribe { received.append($0) }
        store.set("speed", value: .number(2.0))
        store.set("speed", value: .number(3.0))
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received.last?["speed"], .number(3.0))
    }

    func test_store_replaceAll_overwritesAll() {
        let store = UserPropertiesStore()
        store.set("a", value: .number(1))
        store.replaceAll(["b": .text("z")])
        XCTAssertNil(store.values["a"])
        XCTAssertEqual(store.values["b"], .text("z"))
    }

    func test_store_asPlainDictionary_convertsToAny() {
        let store = UserPropertiesStore()
        store.set("speed", value: .number(2.0))
        store.set("on", value: .bool(true))
        store.set("color1", value: .color(.init(r: 1, g: 0, b: 0)))
        let plain = store.asPlainDictionary()
        XCTAssertEqual(plain["speed"] as? Double, 2.0)
        XCTAssertEqual(plain["on"] as? Bool, true)
        XCTAssertEqual(plain["color1"] as? String, "1.0 0.0 0.0")
    }

    // MARK: - Bindings

    func test_bindings_dispatchesToBothSceneScriptAndWeb() {
        let store = UserPropertiesStore()
        let runtime = SceneScriptRuntime()
        runtime.evaluate("var lastFromJS = null; function applyUserProperties(v) { lastFromJS = v; }")

        var webPayloads: [[String: Any]] = []
        UserPropertiesBindings.bind(store: store, runtime: runtime) { payload in
            webPayloads.append(payload)
        }

        store.set("speed", value: .number(3.0))

        XCTAssertEqual(webPayloads.count, 1)
        XCTAssertEqual(webPayloads.first?["speed"] as? Double, 3.0)
        let jsValue = runtime.context
            .objectForKeyedSubscript("lastFromJS")?
            .objectForKeyedSubscript("speed")?
            .toDouble() ?? 0
        XCTAssertEqual(jsValue, 3.0, accuracy: 1e-6)
    }
}
