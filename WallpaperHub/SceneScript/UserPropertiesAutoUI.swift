import Foundation
import SwiftUI
import Combine

// MARK: - User Properties モデル

/// project.json の `general.properties[*]` 1 件を表す型。
/// Why: Wallpaper Engine の type 名に合わせて enum 化することで、auto UI 側で型安全に分岐できる。
public struct UserPropertyDefinition: Equatable {
    public let key: String
    public let label: String
    public let order: Int
    public let kind: Kind

    public enum Kind: Equatable {
        case slider(value: Double, min: Double, max: Double)
        case bool(value: Bool)
        case color(value: ColorRGB)
        case text(value: String)
        case combo(value: String, options: [ComboOption])
    }

    public struct ColorRGB: Equatable {
        public var r: Double
        public var g: Double
        public var b: Double
        public init(r: Double, g: Double, b: Double) {
            self.r = r; self.g = g; self.b = b
        }
        /// "1 0.5 0" のような RGB 文字列 (各成分 0..1)。
        public static func parse(_ s: String) -> ColorRGB? {
            let parts = s.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
            guard parts.count >= 3 else { return nil }
            return ColorRGB(r: parts[0], g: parts[1], b: parts[2])
        }
        public var serialized: String { "\(r) \(g) \(b)" }
    }

    public struct ComboOption: Equatable {
        public let value: String
        public let label: String
    }

    public init(key: String, label: String, order: Int, kind: Kind) {
        self.key = key
        self.label = label
        self.order = order
        self.kind = kind
    }
}

/// project.json をパースする責務。
public enum UserPropertiesProjectParser {

    /// project.json (JSON Data) → properties 配列。
    /// - Important: JSON の object キー順は保証されないため、`order` フィールドがあれば優先し、なければ key 名でソートする。
    public static func parse(jsonData: Data) -> [UserPropertyDefinition] {
        guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let general = obj["general"] as? [String: Any],
              let props = general["properties"] as? [String: Any] else {
            return []
        }
        var out: [UserPropertyDefinition] = []
        out.reserveCapacity(props.count)
        for (key, raw) in props {
            guard let def = raw as? [String: Any] else { continue }
            if let parsed = parseSingle(key: key, def: def) {
                out.append(parsed)
            }
        }
        out.sort { ($0.order, $0.key) < ($1.order, $1.key) }
        return out
    }

    private static func parseSingle(key: String, def: [String: Any]) -> UserPropertyDefinition? {
        let label = (def["label"] as? String) ?? key
        let order = (def["order"] as? Int) ?? Int.max
        let type = ((def["type"] as? String) ?? "").lowercased()

        switch type {
        case "slider":
            let v = numeric(def["value"]) ?? 0
            let mn = numeric(def["min"]) ?? 0
            let mx = numeric(def["max"]) ?? 1
            return UserPropertyDefinition(key: key, label: label, order: order,
                                          kind: .slider(value: v, min: mn, max: mx))
        case "bool", "checkbox":
            let v = (def["value"] as? Bool) ?? ((def["value"] as? NSNumber)?.boolValue ?? false)
            return UserPropertyDefinition(key: key, label: label, order: order, kind: .bool(value: v))
        case "color":
            let raw = (def["value"] as? String) ?? "1 1 1"
            let c = UserPropertyDefinition.ColorRGB.parse(raw) ??
                UserPropertyDefinition.ColorRGB(r: 1, g: 1, b: 1)
            return UserPropertyDefinition(key: key, label: label, order: order, kind: .color(value: c))
        case "text", "textinput":
            let v = (def["value"] as? String) ?? ""
            return UserPropertyDefinition(key: key, label: label, order: order, kind: .text(value: v))
        case "combo":
            let v = (def["value"] as? String) ?? ""
            let opts = (def["options"] as? [[String: Any]]) ?? []
            let parsedOpts: [UserPropertyDefinition.ComboOption] = opts.map { o in
                let value = (o["value"] as? String) ?? (o["text"] as? String) ?? ""
                let label = (o["label"] as? String) ?? (o["text"] as? String) ?? value
                return UserPropertyDefinition.ComboOption(value: value, label: label)
            }
            return UserPropertyDefinition(key: key, label: label, order: order,
                                          kind: .combo(value: v, options: parsedOpts))
        default:
            return nil
        }
    }

    private static func numeric(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
}

// MARK: - Codable ラウンドトリップ用 ValueBox

/// User Properties の値 1 件を表す Codable 型。
/// Why: JSON 経由で SceneScript / Web 壁紙へ流す際、Any でなく型安全に扱えるようにする。
public enum UserPropertyValue: Codable, Equatable {
    case number(Double)
    case bool(Bool)
    case color(UserPropertyDefinition.ColorRGB)
    case text(String)

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .color(let v): try c.encode(v.serialized)
        case .text(let s): try c.encode(s)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let s = try? c.decode(String.self) {
            // "1 0 0" のような色形式は color に格上げ。
            if let rgb = UserPropertyDefinition.ColorRGB.parse(s) {
                self = .color(rgb)
            } else {
                self = .text(s)
            }
            return
        }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported user property value")
    }

    /// JSContext / Web へ流す際の plain value。
    public var asAny: Any {
        switch self {
        case .number(let n): return n
        case .bool(let b): return b
        case .color(let c): return c.serialized
        case .text(let s): return s
        }
    }
}

// MARK: - UserPropertiesStore (Singleton 仲介役)

/// SceneScript ランタイムと WKWebView (Web 壁紙) の双方に同時に
/// applyUserProperties イベントを伝える Singleton。
public final class UserPropertiesStore: ObservableObject {
    public static let shared = UserPropertiesStore()

    @Published public private(set) var values: [String: UserPropertyValue] = [:]

    private var subscribers: [([String: UserPropertyValue]) -> Void] = []
    private let queue = DispatchQueue(label: "com.artia.user-properties-store", attributes: .concurrent)

    public init() {}

    /// 任意のキーに値を設定し、購読者 (SceneScript / Web 壁紙) を起動する。
    public func set(_ key: String, value: UserPropertyValue) {
        values[key] = value
        notify()
    }

    /// 一括上書き。テスト/初期化用。
    public func replaceAll(_ next: [String: UserPropertyValue]) {
        values = next
        notify()
    }

    /// 購読者を登録する。
    /// - Returns: 解除用クロージャ (現状は no-op)。
    @discardableResult
    public func subscribe(_ handler: @escaping ([String: UserPropertyValue]) -> Void) -> () -> Void {
        subscribers.append(handler)
        return { /* 必要になれば handler-id 化する。Phase 5 ではシンプル維持。 */ }
    }

    private func notify() {
        let snapshot = values
        for handler in subscribers {
            handler(snapshot)
        }
    }

    /// 現在の値を `[String: Any]` に直して JSContext / Web 壁紙へ渡せる形にする。
    public func asPlainDictionary() -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in values {
            out[k] = v.asAny
        }
        return out
    }
}

// MARK: - SwiftUI 自動 UI

/// project.json から得た UserPropertyDefinition を編集する SwiftUI フォーム。
public struct UserPropertiesAutoUI: View {
    public let definitions: [UserPropertyDefinition]
    @ObservedObject public var store: UserPropertiesStore

    public init(definitions: [UserPropertyDefinition], store: UserPropertiesStore = .shared) {
        self.definitions = definitions
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(definitions, id: \.key) { def in
                row(for: def)
            }
        }
        .padding()
    }

    @ViewBuilder
    private func row(for def: UserPropertyDefinition) -> some View {
        switch def.kind {
        case .slider(let v, let mn, let mx):
            sliderRow(def: def, initial: v, range: mn...mx)
        case .bool(let b):
            toggleRow(def: def, initial: b)
        case .color(let c):
            colorRow(def: def, initial: c)
        case .text(let s):
            textRow(def: def, initial: s)
        case .combo(let v, let opts):
            comboRow(def: def, initial: v, options: opts)
        }
    }

    private func sliderRow(def: UserPropertyDefinition, initial: Double,
                           range: ClosedRange<Double>) -> some View {
        let binding = Binding<Double>(
            get: {
                if case .number(let n) = store.values[def.key] { return n }
                return initial
            },
            set: { newValue in store.set(def.key, value: .number(newValue)) }
        )
        return HStack {
            Text(def.label)
            Slider(value: binding, in: range)
            Text(String(format: "%.2f", binding.wrappedValue)).monospacedDigit()
        }
    }

    private func toggleRow(def: UserPropertyDefinition, initial: Bool) -> some View {
        let binding = Binding<Bool>(
            get: {
                if case .bool(let b) = store.values[def.key] { return b }
                return initial
            },
            set: { newValue in store.set(def.key, value: .bool(newValue)) }
        )
        return Toggle(def.label, isOn: binding)
    }

    private func colorRow(def: UserPropertyDefinition,
                          initial: UserPropertyDefinition.ColorRGB) -> some View {
        let binding = Binding<Color>(
            get: {
                let c: UserPropertyDefinition.ColorRGB
                if case .color(let stored) = store.values[def.key] {
                    c = stored
                } else {
                    c = initial
                }
                return Color(red: c.r, green: c.g, blue: c.b)
            },
            set: { newValue in
                #if canImport(AppKit)
                let ns = NSColor(newValue).usingColorSpace(.deviceRGB) ?? NSColor.white
                let rgb = UserPropertyDefinition.ColorRGB(
                    r: Double(ns.redComponent),
                    g: Double(ns.greenComponent),
                    b: Double(ns.blueComponent)
                )
                store.set(def.key, value: .color(rgb))
                #endif
            }
        )
        return ColorPicker(def.label, selection: binding, supportsOpacity: false)
    }

    private func textRow(def: UserPropertyDefinition, initial: String) -> some View {
        let binding = Binding<String>(
            get: {
                if case .text(let s) = store.values[def.key] { return s }
                return initial
            },
            set: { newValue in store.set(def.key, value: .text(newValue)) }
        )
        return HStack {
            Text(def.label)
            TextField("", text: binding)
        }
    }

    private func comboRow(def: UserPropertyDefinition, initial: String,
                          options: [UserPropertyDefinition.ComboOption]) -> some View {
        let binding = Binding<String>(
            get: {
                if case .text(let s) = store.values[def.key] { return s }
                return initial
            },
            set: { newValue in store.set(def.key, value: .text(newValue)) }
        )
        return Picker(def.label, selection: binding) {
            ForEach(options, id: \.value) { opt in
                Text(opt.label).tag(opt.value)
            }
        }
    }
}

// MARK: - SceneScript / Web 連携配線ヘルパ

public enum UserPropertiesBindings {
    /// SceneScriptRuntime と Web 壁紙の双方へ applyUserProperties を伝える購読を仕掛ける。
    /// - Parameters:
    ///   - store: 値の発信元。
    ///   - runtime: SceneScript 側 (nil 可)。
    ///   - webDispatch: Web 側へ渡すクロージャ (例: WKWebView 内 `wallpaperPropertyListener.applyUserProperties` を発火)。
    /// - Returns: 解除用クロージャ。
    @discardableResult
    public static func bind(store: UserPropertiesStore,
                            runtime: SceneScriptRuntime?,
                            webDispatch: @escaping ([String: Any]) -> Void) -> () -> Void {
        let cancel = store.subscribe { values in
            var plain: [String: Any] = [:]
            for (k, v) in values { plain[k] = v.asAny }
            runtime?.dispatch(.applyUserProperties(values: plain))
            webDispatch(plain)
        }
        return cancel
    }
}
