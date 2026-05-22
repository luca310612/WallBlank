import Foundation

// MARK: - Phase 6B: effect.json スキーマ
// Why: 各エフェクトに <Name>.effect.json を同梱し、起動時の EffectRegistry が
//      パラメータ仕様 / UI / オーディオ連動 を 1 箇所で記述できるようにする。
//      既存 EffectTypes / EffectManager は破壊せず並走させる。

/// `<Name>.effect.json` の最上位構造。
public struct EffectMetadata: Codable, Equatable {
    public let id: String                     // "plasma", "bloom", ...
    public let displayName: String
    public let category: String               // "background", "distortion", "post", "particle", "audio"
    public let metalFunction: String          // fragment 関数名 (例: "bloomEffect")
    public let params: [ParamMeta]
    public let audio: AudioBinding?
    /// 任意のメモ書き (未使用キーを許可するため). ロードには関係しない。
    public let notes: String?

    public init(id: String, displayName: String, category: String, metalFunction: String,
                params: [ParamMeta], audio: AudioBinding? = nil, notes: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.category = category
        self.metalFunction = metalFunction
        self.params = params
        self.audio = audio
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case category
        case metalFunction
        case params
        case audio
        case notes
    }
}

// MARK: - ParamMeta

/// 1 つのパラメータの仕様。
public struct ParamMeta: Codable, Equatable {
    public let key: String
    public let label: String
    public let type: ParamType
    public let defaultValue: ParamValue
    public let min: Double?
    public let max: Double?
    public let step: Double?
    public let options: [String]?            // enum のとき
    public let visibleWhen: VisibleCondition?

    public init(key: String, label: String, type: ParamType, defaultValue: ParamValue,
                min: Double? = nil, max: Double? = nil, step: Double? = nil,
                options: [String]? = nil, visibleWhen: VisibleCondition? = nil) {
        self.key = key
        self.label = label
        self.type = type
        self.defaultValue = defaultValue
        self.min = min
        self.max = max
        self.step = step
        self.options = options
        self.visibleWhen = visibleWhen
    }

    enum CodingKeys: String, CodingKey {
        case key
        case label
        case type
        case defaultValue = "default"
        case min
        case max
        case step
        case options
        case visibleWhen
    }
}

// MARK: - ParamType

/// パラメータ型。
public enum ParamType: String, Codable, Equatable {
    case float
    case int
    case bool
    case color
    case `enum`
    case vec2
    case vec3
}

// MARK: - ParamValue

/// パラメータの既定値 / 現在値を表現する値型。
/// Why: JSON で型混在を扱うため、enum の自動 Codable で多態を吸収する。
public enum ParamValue: Codable, Equatable {
    case number(Double)
    case integer(Int)
    case bool(Bool)
    case string(String)
    case color(red: Double, green: Double, blue: Double, alpha: Double)
    case vec2(Double, Double)
    case vec3(Double, Double, Double)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .integer(i); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) {
            // "1 0.5 0" のような RGB / vec 文字列もここで吸収。
            let parts = s.split(whereSeparator: { $0 == " " || $0 == "," })
                .compactMap { Double($0) }
            switch parts.count {
            case 3: self = .color(red: parts[0], green: parts[1], blue: parts[2], alpha: 1.0); return
            case 4: self = .color(red: parts[0], green: parts[1], blue: parts[2], alpha: parts[3]); return
            default: self = .string(s); return
            }
        }
        if let arr = try? c.decode([Double].self) {
            switch arr.count {
            case 2: self = .vec2(arr[0], arr[1]); return
            case 3: self = .vec3(arr[0], arr[1], arr[2]); return
            case 4: self = .color(red: arr[0], green: arr[1], blue: arr[2], alpha: arr[3]); return
            default: break
            }
        }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "未対応のデフォルト値")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .color(let r, let g, let b, let a):
            try c.encode([r, g, b, a])
        case .vec2(let x, let y):
            try c.encode([x, y])
        case .vec3(let x, let y, let z):
            try c.encode([x, y, z])
        }
    }

    /// Slider などへ渡す Double 値 (該当しなければ nil)。
    public var asDouble: Double? {
        switch self {
        case .number(let v): return v
        case .integer(let v): return Double(v)
        default: return nil
        }
    }

    public var asBool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}

// MARK: - VisibleCondition

/// 「他 param が値 X のときだけ表示」を簡易表現する。
public struct VisibleCondition: Codable, Equatable {
    public let key: String
    public let equals: ParamValue

    public init(key: String, equals: ParamValue) {
        self.key = key
        self.equals = equals
    }

    enum CodingKeys: String, CodingKey {
        case key
        case equals
    }
}

// MARK: - AudioBinding

/// effect.json に含まれる任意のオーディオ連動メタ。
public struct AudioBinding: Codable, Equatable {
    /// "fft" / "amplitude" / "raw" など。
    public let source: String
    /// "bass" / "mid" / "treble" / "custom" など概念ラベル。
    public let binding: String
    public let bandIndex: Int?
    public let scale: Double?
    public let notes: String?

    public init(source: String, binding: String, bandIndex: Int? = nil,
                scale: Double? = nil, notes: String? = nil) {
        self.source = source
        self.binding = binding
        self.bandIndex = bandIndex
        self.scale = scale
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case source
        case binding
        case bandIndex
        case scale
        case notes
    }
}

// MARK: - EffectInvocation (DSL 解析結果)

/// EffectChainDSL がパースした結果の 1 ステップ。
public struct EffectInvocation: Equatable {
    public let id: String
    /// 位置引数 (数値のみを Phase 6B では受け付ける)。
    public let positionalArguments: [Double]

    public init(id: String, positionalArguments: [Double]) {
        self.id = id
        self.positionalArguments = positionalArguments
    }
}
