import Foundation

/// Phase 8.2: Corsair iCUE SDK 連携。
/// Corsair の CUESDK は macOS 公式バイナリが提供されていないため、
/// 本実装では検出ロジックと no-op スタブのみを用意する。
/// LED 連動が要求された場合は `isAvailable == false` を理由にスキップする。
@MainActor
final class CorsairCueClient: ObservableObject {

    /// SDK が macOS で利用可能か。常に false (UI から readonly で参照される)
    @Published private(set) var isAvailable: Bool

    /// UI 表示用のロケール済みステータス文字列
    @Published private(set) var statusMessage: String

    init() {
        // Corsair iCUE SDK の dynamic library (libCUESDK.dylib) を /Library/Application Support/iCUE 等から探す
        // 現状 macOS 版は提供されていないが、将来 SDK が来た場合に備えて検出ロジックを残す
        let candidatePaths = [
            "/Library/Application Support/Corsair/CUE/CUESDK.dylib",
            "/Library/Frameworks/CUESDK.framework/CUESDK"
        ]
        let detected = candidatePaths.contains { FileManager.default.fileExists(atPath: $0) }
        self.isAvailable = detected
        self.statusMessage = detected
            ? "Corsair iCUE 検出済み (実装は未対応)"
            : "Corsair iCUE は macOS 非対応"
    }

    /// no-op: 単色を Corsair デバイスへ送る (本実装では何もしない)
    /// - Parameters:
    ///   - red, green, blue: 0..255
    func sendSolidColor(red: Int, green: Int, blue: Int) {
        // 何もしない (SDK 不在のため)
        _ = (red, green, blue)
    }
}
