import Foundation
@testable import Artia

/// SettingsRepositoryProtocol の Dictionary バックエンド実装。
/// Why: テストごとにクリーンな永続層を使うため、UserDefaults を介さないインメモリ実装を提供する。
final class InMemorySettingsRepository: SettingsRepositoryProtocol {
    private(set) var storage: [String: Any] = [:]
    private var registeredDefaults: [String: Any] = [:]

    // MARK: - Read

    func integer(forKey key: String) -> Int {
        if let value = storage[key] as? Int { return value }
        if let value = storage[key] as? NSNumber { return value.intValue }
        if let value = registeredDefaults[key] as? Int { return value }
        return 0
    }

    func float(forKey key: String) -> Float {
        if let value = storage[key] as? Float { return value }
        if let value = storage[key] as? Double { return Float(value) }
        if let value = storage[key] as? NSNumber { return value.floatValue }
        if let value = registeredDefaults[key] as? Float { return value }
        return 0
    }

    func double(forKey key: String) -> Double {
        if let value = storage[key] as? Double { return value }
        if let value = storage[key] as? Float { return Double(value) }
        if let value = storage[key] as? NSNumber { return value.doubleValue }
        if let value = registeredDefaults[key] as? Double { return value }
        return 0
    }

    func bool(forKey key: String) -> Bool {
        if let value = storage[key] as? Bool { return value }
        if let value = storage[key] as? NSNumber { return value.boolValue }
        if let value = registeredDefaults[key] as? Bool { return value }
        return false
    }

    func string(forKey key: String) -> String? {
        storage[key] as? String ?? registeredDefaults[key] as? String
    }

    func stringArray(forKey key: String) -> [String]? {
        storage[key] as? [String] ?? registeredDefaults[key] as? [String]
    }

    func data(forKey key: String) -> Data? {
        storage[key] as? Data ?? registeredDefaults[key] as? Data
    }

    func object(forKey key: String) -> Any? {
        storage[key] ?? registeredDefaults[key]
    }

    // MARK: - Write

    func set(_ value: Int, forKey key: String) { storage[key] = value }
    func set(_ value: Float, forKey key: String) { storage[key] = value }
    func set(_ value: Double, forKey key: String) { storage[key] = value }
    func set(_ value: Bool, forKey key: String) { storage[key] = value }
    func set(_ value: String?, forKey key: String) {
        if let value = value { storage[key] = value } else { storage.removeValue(forKey: key) }
    }
    func set(_ value: [String]?, forKey key: String) {
        if let value = value { storage[key] = value } else { storage.removeValue(forKey: key) }
    }
    func set(_ value: Data?, forKey key: String) {
        if let value = value { storage[key] = value } else { storage.removeValue(forKey: key) }
    }
    func set(_ value: Any?, forKey key: String) {
        if let value = value { storage[key] = value } else { storage.removeValue(forKey: key) }
    }

    func removeObject(forKey key: String) {
        storage.removeValue(forKey: key)
    }

    func register(defaults: [String: Any]) {
        for (k, v) in defaults where registeredDefaults[k] == nil {
            registeredDefaults[k] = v
        }
    }
}
