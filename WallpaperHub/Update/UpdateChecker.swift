import Foundation
import AppKit
#if canImport(Sparkle)
import Sparkle
#endif

/// Phase 11D: Sparkle ベースの自動更新ラッパー。
///
/// 設計:
///   - Sparkle SPM が導入されている場合は `SPUStandardUpdaterController` をラップ
///   - 未導入時 (canImport 失敗) は no-op のスタブ実装になり、ビルドを壊さない
///   - SettingsView から呼び出せる @MainActor API:
///       - `automaticChecksEnabled` (Toggle 接続)
///       - `betaChannelEnabled`     (β feed への切替)
///       - `checkForUpdatesNow()`   (ボタン押下)
@MainActor
final class UpdateChecker: ObservableObject {

    static let shared = UpdateChecker()

    /// 自動チェック ON/OFF。Sparkle に伝播する。
    @Published var automaticChecksEnabled: Bool {
        didSet {
            UserDefaults.standard.set(automaticChecksEnabled, forKey: Self.autoCheckKey)
            applyAutomaticChecks(automaticChecksEnabled)
        }
    }

    /// β チャネル参加。ON で `SUFeedURLBeta`、OFF で `SUFeedURL` を使う。
    @Published var betaChannelEnabled: Bool {
        didSet {
            UserDefaults.standard.set(betaChannelEnabled, forKey: Self.betaKey)
            applyFeedURL(beta: betaChannelEnabled)
        }
    }

    private static let autoCheckKey = "ArtiaSparkleAutomaticChecksEnabled"
    private static let betaKey = "ArtiaBetaChannelEnabled"

    #if canImport(Sparkle)
    /// Sparkle 本体。`-startUpdater` 引数 false で初期化し、Settings 完了時に start させる。
    private let updaterController: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }()
    #endif

    private init() {
        let defaults = UserDefaults.standard
        // 既定値: 自動チェック ON / β OFF
        if defaults.object(forKey: Self.autoCheckKey) == nil {
            defaults.set(true, forKey: Self.autoCheckKey)
        }
        self.automaticChecksEnabled = defaults.bool(forKey: Self.autoCheckKey)
        self.betaChannelEnabled = defaults.bool(forKey: Self.betaKey)
        applyAutomaticChecks(automaticChecksEnabled)
        applyFeedURL(beta: betaChannelEnabled)
    }

    /// "今すぐ更新を確認" ボタンから呼ばれる。
    func checkForUpdatesNow() {
        #if canImport(Sparkle)
        updaterController.checkForUpdates(nil)
        #else
        print("[UpdateChecker] Sparkle 未導入: スタブで no-op")
        #endif
    }

    // MARK: - 内部適用

    private func applyAutomaticChecks(_ enabled: Bool) {
        #if canImport(Sparkle)
        updaterController.updater.automaticallyChecksForUpdates = enabled
        #endif
    }

    private func applyFeedURL(beta: Bool) {
        #if canImport(Sparkle)
        let key: String = beta ? "SUFeedURLBeta" : "SUFeedURL"
        if let urlStr = Bundle.main.object(forInfoDictionaryKey: key) as? String,
           let url = URL(string: urlStr) {
            updaterController.updater.setFeedURL(url)
        }
        #else
        _ = beta // 未使用警告抑制
        #endif
    }
}
