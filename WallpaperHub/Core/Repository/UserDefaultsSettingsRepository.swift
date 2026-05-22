import Foundation

/// UserDefaultsを使用した設定リポジトリの実装
class UserDefaultsSettingsRepository: SettingsRepositoryProtocol {
    private let defaults: UserDefaults

    init(suiteName: String? = nil) {
        #if UNSIGNED_BUILD
        // 署名なしビルドは App Group を付けられないため、同一 bundle の標準 UserDefaults でプロセス間共有する
        self.defaults = UserDefaults.standard
        #else
        if let suiteName = suiteName,
           let groupDefaults = UserDefaults(suiteName: suiteName) {
            self.defaults = groupDefaults
        } else {
            self.defaults = UserDefaults.standard
        }
        #endif
    }

    // MARK: - Read Operations

    func integer(forKey key: String) -> Int {
        defaults.integer(forKey: key)
    }

    func float(forKey key: String) -> Float {
        defaults.float(forKey: key)
    }

    func double(forKey key: String) -> Double {
        defaults.double(forKey: key)
    }

    func bool(forKey key: String) -> Bool {
        defaults.bool(forKey: key)
    }

    func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    func stringArray(forKey key: String) -> [String]? {
        defaults.stringArray(forKey: key)
    }

    func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    func object(forKey key: String) -> Any? {
        defaults.object(forKey: key)
    }

    // MARK: - Write Operations

    func set(_ value: Int, forKey key: String) {
        defaults.set(value, forKey: key)
        // synchronize() は不要（macOS 10.12以降は自動同期）
    }

    func set(_ value: Float, forKey key: String) {
        defaults.set(value, forKey: key)
        // synchronize() は不要（macOS 10.12以降は自動同期）
    }

    func set(_ value: Double, forKey key: String) {
        defaults.set(value, forKey: key)
        // synchronize() は不要（macOS 10.12以降は自動同期）
    }

    func set(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
        // synchronize() は不要（macOS 10.12以降は自動同期）
    }

    func set(_ value: String?, forKey key: String) {
        defaults.set(value, forKey: key)
        // synchronize() は不要（macOS 10.12以降は自動同期）
    }

    func set(_ value: [String]?, forKey key: String) {
        defaults.set(value, forKey: key)
        // synchronize() は不要（macOS 10.12以降は自動同期）
    }

    func set(_ value: Data?, forKey key: String) {
        defaults.set(value, forKey: key)
        // synchronize() は不要（macOS 10.12以降は自動同期）
    }

    func set(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
        // synchronize() は不要（macOS 10.12以降は自動同期）
    }

    func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
        // synchronize() は不要（macOS 10.12以降は自動同期）
    }

    func register(defaults registrationDictionary: [String: Any]) {
        defaults.register(defaults: registrationDictionary)
    }
}
