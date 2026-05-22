import Foundation

/// 設定の永続化層を抽象化するプロトコル
/// UserDefaults以外の実装（メモリ保存、テスト用モック）に簡単に切り替え可能
protocol SettingsRepositoryProtocol {
    // MARK: - Basic Operations
    func integer(forKey key: String) -> Int
    func float(forKey key: String) -> Float
    func double(forKey key: String) -> Double
    func bool(forKey key: String) -> Bool
    func string(forKey key: String) -> String?
    func stringArray(forKey key: String) -> [String]?
    func data(forKey key: String) -> Data?
    func object(forKey key: String) -> Any?

    func set(_ value: Int, forKey key: String)
    func set(_ value: Float, forKey key: String)
    func set(_ value: Double, forKey key: String)
    func set(_ value: Bool, forKey key: String)
    func set(_ value: String?, forKey key: String)
    func set(_ value: [String]?, forKey key: String)
    func set(_ value: Data?, forKey key: String)
    func set(_ value: Any?, forKey key: String)

    func removeObject(forKey key: String)
    func register(defaults: [String: Any])
}
