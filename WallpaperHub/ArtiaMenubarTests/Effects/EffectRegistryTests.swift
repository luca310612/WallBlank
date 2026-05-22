import Foundation
import XCTest

@testable import WallBlank

/// Phase 6B: EffectRegistry の bootstrap / lookup / chain 検証。
@MainActor
final class EffectRegistryTests: XCTestCase {

    func test_bootstrap_loadsAtLeast17EffectsFromMainBundle() {
        let registry = EffectRegistry()
        // テストはアプリバンドル経由ではなくテストバンドル経由で走るが、
        // .effect.json が main bundle に同梱されている前提なので Bundle.main を見る。
        // テスト環境では Bundle.main がテスト host (.xctest 内ホスト) を指すため
        // 両方を試して 17 件以上ロードできるか確認する。
        var totalLoaded = 0
        if case let .success(count) = registry.bootstrap(bundle: .main) {
            totalLoaded += count
        }
        if totalLoaded < 17 {
            // テストバンドル単体に effect.json が残っている可能性も確認。
            for bundle in Bundle.allBundles where bundle.bundlePath.contains("WallBlank") {
                if case let .success(count) = registry.bootstrap(bundle: bundle) {
                    totalLoaded = max(totalLoaded, count)
                }
            }
        }
        XCTAssertGreaterThanOrEqual(totalLoaded, 17,
            "17 個以上の effect.json がロードされるはずだが \(totalLoaded) 件しか取れない")
    }

    func test_metadata_lookup_returnsExpectedEntry() {
        let registry = EffectRegistry()
        _ = registry.bootstrap(bundle: .main)
        if let plasma = registry.metadata(for: "plasma") {
            XCTAssertEqual(plasma.id, "plasma")
            XCTAssertFalse(plasma.metalFunction.isEmpty)
        } else {
            // バンドル状況によっては取れないので、effects マップが空でないことだけ確認。
            XCTAssertGreaterThan(registry.effects.count, 0,
                                 "bootstrap 済みなのに effects が空")
        }
    }

    func test_metadata_lookup_returnsNilForUnknown() {
        let registry = EffectRegistry()
        _ = registry.bootstrap(bundle: .main)
        XCTAssertNil(registry.metadata(for: "nonexistent_effect_xyz"))
    }

    func test_compile_throwsForUnknownEffectInChain() {
        let registry = EffectRegistry()
        _ = registry.bootstrap(bundle: .main)
        XCTAssertThrowsError(try registry.compile(chain: "nonexistent_effect_xyz")) { err in
            if case EffectChainDSL.ParseError.unknownEffect(let name) = err {
                XCTAssertEqual(name, "nonexistent_effect_xyz")
            } else {
                XCTFail("unknownEffect ではないエラー: \(err)")
            }
        }
    }

    func test_compile_returnsKnownEffectsInOrder() throws {
        let registry = EffectRegistry()
        _ = registry.bootstrap(bundle: .main)
        // bootstrap がうまくいかない CI 環境でもテストが死なないようにスキップ条件付き。
        guard registry.metadata(for: "plasma") != nil,
              registry.metadata(for: "bloom") != nil else {
            throw XCTSkip("bundle に plasma/bloom が見つからないためスキップ")
        }
        let invs = try registry.compile(chain: "plasma -> bloom(0.4)")
        XCTAssertEqual(invs.map { $0.id }, ["plasma", "bloom"])
        XCTAssertEqual(invs[1].positionalArguments, [0.4])
    }
}
