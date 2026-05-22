import Foundation
import XCTest

@testable import Artia

/// Phase 6B: EffectChainDSL パーサの検証。
final class EffectChainDSLTests: XCTestCase {

    func test_parse_singleEffectWithoutArgs() throws {
        let r = try EffectChainDSL.parse("plasma")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].id, "plasma")
        XCTAssertEqual(r[0].positionalArguments, [])
    }

    func test_parse_twoEffectsWithSingleArg() throws {
        let r = try EffectChainDSL.parse("plasma -> bloom(0.4)")
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].id, "plasma")
        XCTAssertEqual(r[1].id, "bloom")
        XCTAssertEqual(r[1].positionalArguments, [0.4])
    }

    func test_parse_threeEffectsMixedArgs() throws {
        let r = try EffectChainDSL.parse("plasma -> bloom(0.4) -> vignette(0.8)")
        XCTAssertEqual(r.map { $0.id }, ["plasma", "bloom", "vignette"])
        XCTAssertEqual(r[1].positionalArguments, [0.4])
        XCTAssertEqual(r[2].positionalArguments, [0.8])
    }

    func test_parse_multipleArgs() throws {
        let r = try EffectChainDSL.parse("waterRipple(0.3, 0.5, 1.0)")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].id, "waterRipple")
        XCTAssertEqual(r[0].positionalArguments, [0.3, 0.5, 1.0])
    }

    func test_parse_extraWhitespaceIsTolerated() throws {
        let r = try EffectChainDSL.parse("  plasma   ->  bloom( 0.4 ) ")
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[1].positionalArguments, [0.4])
    }

    func test_parse_emptyInputThrows() {
        XCTAssertThrowsError(try EffectChainDSL.parse(""))
        XCTAssertThrowsError(try EffectChainDSL.parse("   "))
    }

    func test_parse_invalidIdentifierThrows() {
        XCTAssertThrowsError(try EffectChainDSL.parse("123abc"))
        XCTAssertThrowsError(try EffectChainDSL.parse("plasma-bloom")) // ハイフンは識別子に許可しない
    }

    func test_parse_unmatchedParenThrows() {
        XCTAssertThrowsError(try EffectChainDSL.parse("bloom(0.4"))
    }

    func test_parse_invalidArgThrows() {
        XCTAssertThrowsError(try EffectChainDSL.parse("bloom(abc)"))
    }

    func test_parse_trailingArrowEffectivelyOk() throws {
        // "plasma ->" は空 step を末尾に持つが、splitByArrow + 空 step skip で 1 効果として扱う。
        let r = try EffectChainDSL.parse("plasma -> ")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].id, "plasma")
    }
}
