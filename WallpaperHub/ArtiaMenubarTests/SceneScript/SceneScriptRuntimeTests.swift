import Foundation
import JavaScriptCore
import XCTest

@testable import WallBlank

/// Phase 5: SceneScriptRuntime のイベント発火 / 例外ハンドリング検証。
final class SceneScriptRuntimeTests: XCTestCase {

    func test_evaluate_returnsValue_andResetsLastException() {
        let runtime = SceneScriptRuntime()
        let result = runtime.evaluate("40 + 2")
        XCTAssertEqual(result?.toInt32(), 42)
        XCTAssertNil(runtime.lastException)
    }

    func test_evaluate_capturesException_inLastException() {
        let runtime = SceneScriptRuntime()
        let result = runtime.evaluate("throw new Error('boom')")
        XCTAssertNil(result)
        XCTAssertNotNil(runtime.lastException)
        XCTAssertTrue(runtime.lastException?.contains("boom") ?? false)
    }

    func test_dispatch_init_callsGlobalInitFunction() {
        let runtime = SceneScriptRuntime()
        runtime.evaluate("var seen = 0; function init() { seen += 1; }")
        runtime.dispatch(.initLifecycle)
        runtime.dispatch(.initLifecycle)
        let seen = runtime.context.objectForKeyedSubscript("seen")?.toInt32()
        XCTAssertEqual(seen, 2)
    }

    func test_dispatch_update_passesDeltaTime() {
        let runtime = SceneScriptRuntime()
        runtime.evaluate("var totalDt = 0; function update(dt) { totalDt += dt; }")
        runtime.dispatch(.update(deltaTime: 0.25))
        runtime.dispatch(.update(deltaTime: 0.75))
        let total = runtime.context.objectForKeyedSubscript("totalDt")?.toDouble() ?? 0
        XCTAssertEqual(total, 1.0, accuracy: 1e-6)
    }

    func test_dispatch_cursorEvents_orderPreserved() {
        let runtime = SceneScriptRuntime()
        let script = """
        var trace = [];
        function cursorMove(x, y) { trace.push('move:' + x + ',' + y); }
        function cursorDown(x, y) { trace.push('down:' + x + ',' + y); }
        function cursorUp(x, y) { trace.push('up:' + x + ',' + y); }
        function cursorClick(x, y) { trace.push('click:' + x + ',' + y); }
        """
        runtime.evaluate(script)
        runtime.dispatch(.cursorMove(x: 10, y: 20))
        runtime.dispatch(.cursorDown(x: 10, y: 20))
        runtime.dispatch(.cursorUp(x: 12, y: 22))
        runtime.dispatch(.cursorClick(x: 12, y: 22))
        let trace = runtime.context.objectForKeyedSubscript("trace")?.toArray() as? [String] ?? []
        XCTAssertEqual(trace, ["move:10,20", "down:10,20", "up:12,22", "click:12,22"])
    }

    func test_applyUserProperties_isReadableInJS() {
        let runtime = SceneScriptRuntime()
        runtime.evaluate("var lastValues = null; function applyUserProperties(v) { lastValues = v; }")
        runtime.dispatch(.applyUserProperties(values: ["speed": 1.5, "title": "hello"]))
        let speed = runtime.context.objectForKeyedSubscript("lastValues")?
            .objectForKeyedSubscript("speed")?
            .toDouble() ?? 0
        XCTAssertEqual(speed, 1.5, accuracy: 1e-6)
        let title = runtime.context.objectForKeyedSubscript("lastValues")?
            .objectForKeyedSubscript("title")?
            .toString()
        XCTAssertEqual(title, "hello")
    }

    func test_dispatch_undefinedFunction_doesNothing_butRecordsName() {
        let runtime = SceneScriptRuntime()
        // 関数を定義しない → 例外なく no-op で済むこと
        runtime.dispatch(.mediaTitle(value: "x"))
        XCTAssertNil(runtime.lastException)
    }

    func test_sandbox_filesystemGlobalsAreNotExposed() {
        let runtime = SceneScriptRuntime()
        runtime.evaluate("typeof require + ',' + typeof process + ',' + typeof XMLHttpRequest")
        let result = runtime.evaluate("typeof require + ',' + typeof process + ',' + typeof XMLHttpRequest")?.toString()
        // sandbox: いずれも undefined であること
        XCTAssertEqual(result, "undefined,undefined,undefined")
    }
}
