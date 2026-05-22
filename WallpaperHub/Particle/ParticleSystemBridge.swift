import Foundation

// MARK: - Descriptor 構造体 (Phase 4A)
// Why: Rust artia-wgpu の `ParticleSystemDescriptor` / `ParticleSystemParams` と JSON 互換にする。
//      Swift 側で構築 → JSON 化 → C 文字列で FFI に渡し → Rust 側 serde で deserialize する。

/// Emitter の出生形状。Rust 側 `EmitterShape` と "type" tag (snake_case) で一致させる。
enum ParticleEmitterShape: Codable, Equatable {
    case point
    case box(width: Float, height: Float)
    case circle(radius: Float)

    private enum CodingKeys: String, CodingKey { case type, width, height, radius }
    private enum ShapeType: String, Codable { case point, box, circle }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ShapeType.self, forKey: .type)
        switch type {
        case .point:
            self = .point
        case .box:
            let w = try container.decode(Float.self, forKey: .width)
            let h = try container.decode(Float.self, forKey: .height)
            self = .box(width: w, height: h)
        case .circle:
            let r = try container.decode(Float.self, forKey: .radius)
            self = .circle(radius: r)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .point:
            try container.encode(ShapeType.point, forKey: .type)
        case .box(let w, let h):
            try container.encode(ShapeType.box, forKey: .type)
            try container.encode(w, forKey: .width)
            try container.encode(h, forKey: .height)
        case .circle(let r):
            try container.encode(ShapeType.circle, forKey: .type)
            try container.encode(r, forKey: .radius)
        }
    }
}

/// Emitter 定義。Rust 側 `EmitterDescriptor` と一致。
struct ParticleEmitterDescriptor: Codable, Equatable {
    var origin: [Float] = [0, 0]
    var spawnRate: Float = 0
    var burst: UInt32 = 0
    var shape: ParticleEmitterShape = .point
    /// Phase 6A: audio binding (省略可)。Rust 側 `ParticleSystem.audio_binding` と
    /// 同じ概念だが、descriptor 経由で送りたい場合の便宜フィールド。
    /// 実バインドは `AudioUniformBridge.bindEmitter` (FFI 経由) で行うのが正規ルート。
    var audioBinding: EmitterAudioBinding? = nil

    enum CodingKeys: String, CodingKey {
        case origin
        case spawnRate = "spawn_rate"
        case burst
        case shape
        case audioBinding = "audio_binding"
    }
}

/// Initializer 定義。Rust 側 `InitializerDescriptor` enum (snake_case) と一致。
enum ParticleInitializerDescriptor: Codable, Equatable {
    case lifetimeRange(min: Float, max: Float)
    case velocityCone(direction: [Float], angle: Float, speedMin: Float, speedMax: Float)
    case sizeRange(min: Float, max: Float)
    case colorRamp(color: [Float])
    case randomDirection(speedMin: Float, speedMax: Float)

    private enum CodingKeys: String, CodingKey {
        case type
        case min, max, direction, angle
        case speedMin = "speed_min"
        case speedMax = "speed_max"
        case color
    }
    private enum InitType: String, Codable {
        case lifetimeRange = "lifetime_range"
        case velocityCone = "velocity_cone"
        case sizeRange = "size_range"
        case colorRamp = "color_ramp"
        case randomDirection = "random_direction"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(InitType.self, forKey: .type) {
        case .lifetimeRange:
            self = .lifetimeRange(
                min: try c.decode(Float.self, forKey: .min),
                max: try c.decode(Float.self, forKey: .max)
            )
        case .velocityCone:
            self = .velocityCone(
                direction: try c.decode([Float].self, forKey: .direction),
                angle: try c.decode(Float.self, forKey: .angle),
                speedMin: try c.decode(Float.self, forKey: .speedMin),
                speedMax: try c.decode(Float.self, forKey: .speedMax)
            )
        case .sizeRange:
            self = .sizeRange(
                min: try c.decode(Float.self, forKey: .min),
                max: try c.decode(Float.self, forKey: .max)
            )
        case .colorRamp:
            self = .colorRamp(color: try c.decode([Float].self, forKey: .color))
        case .randomDirection:
            self = .randomDirection(
                speedMin: try c.decode(Float.self, forKey: .speedMin),
                speedMax: try c.decode(Float.self, forKey: .speedMax)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .lifetimeRange(let mn, let mx):
            try c.encode(InitType.lifetimeRange, forKey: .type)
            try c.encode(mn, forKey: .min); try c.encode(mx, forKey: .max)
        case .velocityCone(let d, let a, let smin, let smax):
            try c.encode(InitType.velocityCone, forKey: .type)
            try c.encode(d, forKey: .direction)
            try c.encode(a, forKey: .angle)
            try c.encode(smin, forKey: .speedMin); try c.encode(smax, forKey: .speedMax)
        case .sizeRange(let mn, let mx):
            try c.encode(InitType.sizeRange, forKey: .type)
            try c.encode(mn, forKey: .min); try c.encode(mx, forKey: .max)
        case .colorRamp(let col):
            try c.encode(InitType.colorRamp, forKey: .type)
            try c.encode(col, forKey: .color)
        case .randomDirection(let smin, let smax):
            try c.encode(InitType.randomDirection, forKey: .type)
            try c.encode(smin, forKey: .speedMin); try c.encode(smax, forKey: .speedMax)
        }
    }
}

/// Operator 定義。Rust 側 `OperatorDescriptor` enum と一致。
enum ParticleOperatorDescriptor: Codable, Equatable {
    case gravity(acceleration: [Float])
    case drag(coefficient: Float)
    case sizeOverLife(start: Float, end: Float)
    case colorOverLife(start: [Float], end: [Float])
    case killBeyondBounds(min: [Float], max: [Float])

    private enum CodingKeys: String, CodingKey {
        case type, acceleration, coefficient, start, end, min, max
    }
    private enum OpType: String, Codable {
        case gravity, drag
        case sizeOverLife = "size_over_life"
        case colorOverLife = "color_over_life"
        case killBeyondBounds = "kill_beyond_bounds"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(OpType.self, forKey: .type) {
        case .gravity:
            self = .gravity(acceleration: try c.decode([Float].self, forKey: .acceleration))
        case .drag:
            self = .drag(coefficient: try c.decode(Float.self, forKey: .coefficient))
        case .sizeOverLife:
            self = .sizeOverLife(
                start: try c.decode(Float.self, forKey: .start),
                end: try c.decode(Float.self, forKey: .end)
            )
        case .colorOverLife:
            self = .colorOverLife(
                start: try c.decode([Float].self, forKey: .start),
                end: try c.decode([Float].self, forKey: .end)
            )
        case .killBeyondBounds:
            self = .killBeyondBounds(
                min: try c.decode([Float].self, forKey: .min),
                max: try c.decode([Float].self, forKey: .max)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .gravity(let a):
            try c.encode(OpType.gravity, forKey: .type)
            try c.encode(a, forKey: .acceleration)
        case .drag(let coef):
            try c.encode(OpType.drag, forKey: .type)
            try c.encode(coef, forKey: .coefficient)
        case .sizeOverLife(let s, let e):
            try c.encode(OpType.sizeOverLife, forKey: .type)
            try c.encode(s, forKey: .start); try c.encode(e, forKey: .end)
        case .colorOverLife(let s, let e):
            try c.encode(OpType.colorOverLife, forKey: .type)
            try c.encode(s, forKey: .start); try c.encode(e, forKey: .end)
        case .killBeyondBounds(let mn, let mx):
            try c.encode(OpType.killBeyondBounds, forKey: .type)
            try c.encode(mn, forKey: .min); try c.encode(mx, forKey: .max)
        }
    }
}

/// `ParticleSystemDescriptor` (Rust) と一致する Codable 構造体。
struct ParticleSystemDescriptor: Codable, Equatable {
    var capacity: UInt32 = 1024
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    var emitter: ParticleEmitterDescriptor
    var initializers: [ParticleInitializerDescriptor] = []
    var operators: [ParticleOperatorDescriptor] = []

    enum CodingKeys: String, CodingKey {
        case capacity, seed, emitter, initializers, operators
    }
}

/// `ParticleSystemParams` (Rust) と一致する部分更新 Codable 構造体。
struct ParticleSystemParams: Codable, Equatable {
    var emitter: ParticleEmitterDescriptor?
    var initializers: [ParticleInitializerDescriptor]?
    var operators: [ParticleOperatorDescriptor]?
}

// MARK: - Bridge

/// Phase 4A: ParticleSystem 用 Rust FFI ラッパー。
/// Why: 既存 `RustCore` enum (`RustBridge.swift`) と同じ「静的メソッドのみ」パターンで Rust API を露出する。
enum ParticleSystemBridge {

    /// JSON で descriptor を渡してパーティクルシステムを作成する。
    /// - Returns: 0 でない `ParticleSystemId.0` (1 以上) / 失敗時 0。
    static func create(
        engine: UnsafeMutableRawPointer,
        descriptor: ParticleSystemDescriptor
    ) -> UInt32 {
        guard let json = encodeJSON(descriptor) else { return 0 }
        return json.withCString { cString in
            artia_particle_create(engine, cString)
        }
    }

    /// 既存パーティクルシステムにパラメータを部分適用する。
    /// - Returns: 成功時 nil / 失敗時 Rust 側エラーメッセージ。
    static func update(
        engine: UnsafeMutableRawPointer,
        id: UInt32,
        params: ParticleSystemParams
    ) -> String? {
        guard let json = encodeJSON(params) else { return "Swift: encode params failed" }
        let result = json.withCString { cString -> UnsafeMutablePointer<CChar>? in
            artia_particle_update(engine, id, cString)
        }
        guard let resultPtr = result else { return nil }
        let message = String(cString: resultPtr)
        artia_free_string(resultPtr)
        return message
    }

    /// パーティクルシステムを破棄する。
    /// - Returns: 成功時 true / 該当 ID 不在で false。
    @discardableResult
    static func destroy(engine: UnsafeMutableRawPointer, id: UInt32) -> Bool {
        artia_particle_destroy(engine, id) != 0
    }

    /// 現在登録されている ParticleSystem 数 (テスト/メトリクス用)。
    static func systemCount(engine: UnsafeMutableRawPointer) -> UInt32 {
        artia_particle_system_count(engine)
    }

    /// Engine を介さない疎通確認: descriptor の JSON ラウンドトリップを Rust 側で実行して結果を返す。
    /// - Returns: 成功時に Rust が再シリアライズした JSON、失敗時 nil。
    static func validateDescriptor(_ descriptor: ParticleSystemDescriptor) -> String? {
        guard let json = encodeJSON(descriptor) else { return nil }
        let resultPtr = json.withCString { cString -> UnsafeMutablePointer<CChar>? in
            artia_particle_validate_descriptor(cString)
        }
        guard let ptr = resultPtr else { return nil }
        let message = String(cString: ptr)
        artia_free_string(ptr)
        // Rust 側がエラーオブジェクトを返した場合は nil を返してエラー扱いにする。
        if message.contains("\"error\"") { return nil }
        return message
    }

    // MARK: - Helpers

    private static func encodeJSON<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        // Rust 側 serde は配列もそのまま受けるため特別な調整は不要。
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Sample helpers

    /// 雪風プリセット: 上方から下に降る粒子。動作確認 / テストフィクスチャ用。
    /// - Parameters:
    ///   - canvasWidth/Height: 出生範囲計算用キャンバス寸法
    static func makeSimpleSnowDescriptor(
        canvasWidth: Float,
        canvasHeight: Float
    ) -> ParticleSystemDescriptor {
        ParticleSystemDescriptor(
            capacity: 4096,
            seed: 0xCAFEBABE,
            emitter: ParticleEmitterDescriptor(
                origin: [canvasWidth * 0.5, canvasHeight + 10],
                spawnRate: 200,
                burst: 0,
                shape: .box(width: canvasWidth, height: 4)
            ),
            initializers: [
                .lifetimeRange(min: 4.0, max: 7.0),
                .sizeRange(min: 1.5, max: 4.0),
                .colorRamp(color: [1.0, 1.0, 1.0, 0.85]),
                .velocityCone(
                    direction: [0.0, -1.0],
                    angle: 0.4,
                    speedMin: 30.0,
                    speedMax: 60.0
                )
            ],
            operators: [
                .gravity(acceleration: [0.0, -8.0]),
                .drag(coefficient: 0.05),
                .killBeyondBounds(
                    min: [-canvasWidth * 0.1, -50.0],
                    max: [canvasWidth * 1.1, canvasHeight + 50.0]
                )
            ]
        )
    }
}
