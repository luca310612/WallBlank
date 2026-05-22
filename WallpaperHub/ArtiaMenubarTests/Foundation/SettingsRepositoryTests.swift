import XCTest
@testable import Artia

/// InMemorySettingsRepository の get/set/delete を確認する基盤テスト。
/// Why: 永続層モックの動作検証は、設定系テスト全体の前提となる。
final class SettingsRepositoryTests: XCTestCase {

    func testSetAndGetTypedValues() {
        let repo = InMemorySettingsRepository()

        repo.set(42, forKey: "intKey")
        repo.set(Float(0.5), forKey: "floatKey")
        repo.set(true, forKey: "boolKey")
        repo.set("hello", forKey: "stringKey")
        repo.set(Data([0x01, 0x02]), forKey: "dataKey")

        XCTAssertEqual(repo.integer(forKey: "intKey"), 42)
        XCTAssertEqual(repo.float(forKey: "floatKey"), 0.5)
        XCTAssertEqual(repo.bool(forKey: "boolKey"), true)
        XCTAssertEqual(repo.string(forKey: "stringKey"), "hello")
        XCTAssertEqual(repo.data(forKey: "dataKey"), Data([0x01, 0x02]))
    }

    func testRemoveObjectClearsValue() {
        let repo = InMemorySettingsRepository()
        repo.set("temp", forKey: "k")
        XCTAssertEqual(repo.string(forKey: "k"), "temp")

        repo.removeObject(forKey: "k")
        XCTAssertNil(repo.string(forKey: "k"))
        XCTAssertEqual(repo.integer(forKey: "k"), 0)
    }

    func testRegisterDefaultsFallback() {
        let repo = InMemorySettingsRepository()
        repo.register(defaults: ["fallback": 7])

        XCTAssertEqual(repo.integer(forKey: "fallback"), 7)

        // 明示的に書き込んだ値は defaults より優先される
        repo.set(99, forKey: "fallback")
        XCTAssertEqual(repo.integer(forKey: "fallback"), 99)
    }
}
