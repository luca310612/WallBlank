import Foundation
import SwiftUI

/// Phase 6B: ParamMeta から自動 UI を生成する SwiftUI ビュー。
/// Why: effect.json に書かれた仕様をそのまま編集 UI に反映し、
///      新エフェクトを増やすたびに UI コードを書く手間を排する。
public struct EffectParamsView: View {

    public let effect: EffectMetadata

    /// key → 現在の値を保持するストレージ。
    @Binding public var values: [String: ParamValue]

    public init(effect: EffectMetadata, values: Binding<[String: ParamValue]>) {
        self.effect = effect
        self._values = values
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(effect.displayName)
                .font(.headline)
            ForEach(effect.params, id: \.key) { param in
                if isVisible(param) {
                    row(for: param)
                }
            }
        }
        .padding()
    }

    /// visibleWhen 簡易評価 (等価のみ; 不等号は将来拡張)。
    private func isVisible(_ param: ParamMeta) -> Bool {
        guard let cond = param.visibleWhen else { return true }
        let actual = values[cond.key] ?? defaultValue(forKey: cond.key)
        return actual == cond.equals
    }

    private func defaultValue(forKey key: String) -> ParamValue? {
        effect.params.first(where: { $0.key == key })?.defaultValue
    }

    @ViewBuilder
    private func row(for param: ParamMeta) -> some View {
        switch param.type {
        case .float:
            sliderRow(for: param)
        case .int:
            stepperRow(for: param)
        case .bool:
            toggleRow(for: param)
        case .color:
            colorRow(for: param)
        case .enum:
            enumRow(for: param)
        case .vec2:
            vecRow(for: param, components: 2)
        case .vec3:
            vecRow(for: param, components: 3)
        }
    }

    // MARK: - 各 UI

    private func sliderRow(for param: ParamMeta) -> some View {
        let binding = Binding<Double>(
            get: { values[param.key]?.asDouble ?? param.defaultValue.asDouble ?? 0 },
            set: { values[param.key] = .number($0) }
        )
        let lo = param.min ?? 0
        let hi = param.max ?? 1
        return HStack {
            Text(param.label)
            Slider(value: binding, in: lo...hi)
            Text(String(format: "%.2f", binding.wrappedValue)).monospacedDigit()
        }
    }

    private func stepperRow(for param: ParamMeta) -> some View {
        let binding = Binding<Double>(
            get: { values[param.key]?.asDouble ?? param.defaultValue.asDouble ?? 0 },
            set: { values[param.key] = .integer(Int($0)) }
        )
        let step = param.step ?? 1
        return HStack {
            Text(param.label)
            Stepper(value: binding,
                    in: (param.min ?? 0)...(param.max ?? 100),
                    step: step) {
                Text("\(Int(binding.wrappedValue))").monospacedDigit()
            }
        }
    }

    private func toggleRow(for param: ParamMeta) -> some View {
        let binding = Binding<Bool>(
            get: { values[param.key]?.asBool ?? param.defaultValue.asBool ?? false },
            set: { values[param.key] = .bool($0) }
        )
        return Toggle(param.label, isOn: binding)
    }

    private func colorRow(for param: ParamMeta) -> some View {
        let initial: (Double, Double, Double, Double) = {
            if case let .color(r, g, b, a) = (values[param.key] ?? param.defaultValue) {
                return (r, g, b, a)
            }
            return (1, 1, 1, 1)
        }()
        let binding = Binding<Color>(
            get: { Color(red: initial.0, green: initial.1, blue: initial.2) },
            set: { newValue in
                #if canImport(AppKit)
                let ns = NSColor(newValue).usingColorSpace(.deviceRGB) ?? NSColor.white
                values[param.key] = .color(red: Double(ns.redComponent),
                                           green: Double(ns.greenComponent),
                                           blue: Double(ns.blueComponent),
                                           alpha: 1.0)
                #else
                _ = newValue
                #endif
            }
        )
        return ColorPicker(param.label, selection: binding, supportsOpacity: false)
    }

    private func enumRow(for param: ParamMeta) -> some View {
        let options = param.options ?? []
        let binding = Binding<String>(
            get: {
                if case let .string(s) = (values[param.key] ?? param.defaultValue) { return s }
                return options.first ?? ""
            },
            set: { values[param.key] = .string($0) }
        )
        return Picker(param.label, selection: binding) {
            ForEach(options, id: \.self) { opt in
                Text(opt).tag(opt)
            }
        }
    }

    private func vecRow(for param: ParamMeta, components: Int) -> some View {
        let initial: [Double] = {
            switch values[param.key] ?? param.defaultValue {
            case .vec2(let x, let y): return [x, y]
            case .vec3(let x, let y, let z): return [x, y, z]
            default: return Array(repeating: 0, count: components)
            }
        }()
        let lo = param.min ?? 0
        let hi = param.max ?? 1
        return HStack {
            Text(param.label)
            ForEach(0..<components, id: \.self) { idx in
                let comp = Binding<Double>(
                    get: { idx < initial.count ? initial[idx] : 0 },
                    set: { newValue in
                        var arr = initial
                        while arr.count < components { arr.append(0) }
                        arr[idx] = newValue
                        if components == 2 {
                            values[param.key] = .vec2(arr[0], arr[1])
                        } else {
                            values[param.key] = .vec3(arr[0], arr[1], arr[2])
                        }
                    }
                )
                Slider(value: comp, in: lo...hi)
            }
        }
    }
}
