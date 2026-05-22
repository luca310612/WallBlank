import Foundation
import Combine

/// Phase 6B: 起動時に Effects/<Name>/<Name>.effect.json をスキャンしてロードするレジストリ。
/// Why: 既存の EffectManager / EffectTypes はそのまま並走させ、JSON 駆動の新経路を導入する。
@MainActor
public final class EffectRegistry: ObservableObject {
    public static let shared = EffectRegistry()

    /// id → metadata。
    @Published public private(set) var effects: [String: EffectMetadata] = [:]

    /// bootstrap 済みフラグ。複数回呼んでも 1 度しか走らない。
    @Published public private(set) var didBootstrap: Bool = false

    public init() {}

    public enum BootstrapError: Error, Equatable {
        case bundleResourceMissing
        case parseFailed(file: String, message: String)
    }

    /// Bundle.main から `<Name>.effect.json` を全件パースして effects に格納する。
    /// - Parameter customBundle: テストでバンドル差し替え用。
    @discardableResult
    public func bootstrap(bundle: Bundle = .main) -> Result<Int, BootstrapError> {
        guard let resourceURL = bundle.resourceURL else {
            return .failure(.bundleResourceMissing)
        }
        let urls = collectEffectJSONURLs(under: resourceURL)
        var loaded: [String: EffectMetadata] = [:]
        var firstFailure: BootstrapError?
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                let meta = try JSONDecoder().decode(EffectMetadata.self, from: data)
                loaded[meta.id] = meta
            } catch {
                if firstFailure == nil {
                    firstFailure = .parseFailed(file: url.lastPathComponent,
                                                message: String(describing: error))
                }
                NSLog("[EffectRegistry] パース失敗: %@ (%@)",
                      url.lastPathComponent, String(describing: error))
            }
        }
        self.effects = loaded
        self.didBootstrap = true
        if let failure = firstFailure, loaded.isEmpty {
            return .failure(failure)
        }
        return .success(loaded.count)
    }

    /// id で metadata を引く。
    public func metadata(for id: String) -> EffectMetadata? {
        effects[id]
    }

    /// DSL 文字列 (例: "plasma -> bloom(0.4) -> vignette(0.8)") を [EffectInvocation] にパースする。
    /// 未登録 id は throw。
    public func compile(chain: String) throws -> [EffectInvocation] {
        let invocations = try EffectChainDSL.parse(chain)
        for inv in invocations {
            if effects[inv.id] == nil {
                throw EffectChainDSL.ParseError.unknownEffect(inv.id)
            }
        }
        return invocations
    }

    // MARK: - 内部: バンドル探索

    /// `<root>/Effects/<Name>/<Name>.effect.json` および `<root>/<Name>.effect.json` の両方を許容する。
    /// Why: pbxproj への登録方法によっては Effects/ 階層が flatten されるケースがあるため。
    private func collectEffectJSONURLs(under resourceURL: URL) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        let enumerator = fm.enumerator(at: resourceURL,
                                       includingPropertiesForKeys: nil,
                                       options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent.hasSuffix(".effect.json") {
                results.append(url)
            }
        }
        // 同一名複数命中時の決定論性のためソート。
        results.sort { $0.lastPathComponent < $1.lastPathComponent }
        return results
    }
}
