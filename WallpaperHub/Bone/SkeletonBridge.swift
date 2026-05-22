import Foundation

// Phase 4C: Skeleton Codable + Rust FFI ブリッジ。
// Why: Rust 側 `SkeletonDescriptor` / `SkeletonPoseParams` と JSON 互換にし、
//      Swift 側で構築 → JSON 化 → C 文字列で FFI に渡す。
//      実 GPU 経路は後続フェーズで compositor に組み込む。

/// Rust `BoneDescriptor` と一致。
struct BoneDescriptor: Codable, Equatable {
    var name: String
    /// -1 = ルート、それ以外は親 bone の index
    var parentId: Int32 = -1
    var localTranslation: [Float] = [0, 0, 0]
    var localRotation: Float = 0
    var localScale: [Float] = [1, 1, 1]
    var length: Float = 1

    enum CodingKeys: String, CodingKey {
        case name
        case parentId = "parent_id"
        case localTranslation = "local_translation"
        case localRotation = "local_rotation"
        case localScale = "local_scale"
        case length
    }
}

/// Rust `VertexWeights` と一致 (4 ボーン重み)。
struct VertexBoneWeights: Codable, Equatable {
    var boneIndices: [Int32] = [-1, -1, -1, -1]
    var weights: [Float] = [0, 0, 0, 0]

    enum CodingKeys: String, CodingKey {
        case boneIndices = "bone_indices"
        case weights
    }

    /// 単一ボーン参照のヘルパ。
    static func single(boneIndex: Int32) -> Self {
        Self(boneIndices: [boneIndex, -1, -1, -1], weights: [1, 0, 0, 0])
    }
}

/// Rust `SkeletonDescriptor` と一致。
struct SkeletonDescriptor: Codable, Equatable {
    var sourceLayerId: String
    var bones: [BoneDescriptor] = []
    var weights: [VertexBoneWeights] = []
    var restPositions: [[Float]] = []

    enum CodingKeys: String, CodingKey {
        case sourceLayerId = "source_layer_id"
        case bones
        case weights
        case restPositions = "rest_positions"
    }
}

/// 4x4 行列 (列優先 16 個の Float)。Rust `Mat4 = [[f32;4];4]` と一致。
typealias SkeletonMat4 = [[Float]]

/// Rust `SkeletonPoseParams` と一致。
struct SkeletonPoseParams: Codable, Equatable {
    var localMatrices: [SkeletonMat4]?

    enum CodingKeys: String, CodingKey {
        case localMatrices = "local_matrices"
    }
}

/// Phase 4C: Skeleton 用 Rust FFI ラッパー。
enum SkeletonBridge {

    /// JSON で descriptor を渡して Skeleton を作成する。
    static func create(
        engine: UnsafeMutableRawPointer,
        descriptor: SkeletonDescriptor
    ) -> UInt32 {
        guard let json = encodeJSON(descriptor) else { return 0 }
        return json.withCString { cString in
            artia_skeleton_create(engine, cString)
        }
    }

    /// pose を更新 (全ボーンの local 行列を一括差し替え)。
    static func updatePose(
        engine: UnsafeMutableRawPointer,
        id: UInt32,
        params: SkeletonPoseParams
    ) -> String? {
        guard let json = encodeJSON(params) else { return "Swift: encode params failed" }
        let result = json.withCString { cString -> UnsafeMutablePointer<CChar>? in
            artia_skeleton_update_pose(engine, id, cString)
        }
        guard let ptr = result else { return nil }
        let message = String(cString: ptr)
        artia_free_string(ptr)
        return message
    }

    /// Skeleton を破棄する。
    @discardableResult
    static func destroy(engine: UnsafeMutableRawPointer, id: UInt32) -> Bool {
        artia_skeleton_destroy(engine, id) != 0
    }

    /// 現在登録されている Skeleton 数 (テスト/メトリクス用)。
    static func count(engine: UnsafeMutableRawPointer) -> UInt32 {
        artia_skeleton_count(engine)
    }

    /// Engine を介さない疎通確認。
    static func validateDescriptor(_ descriptor: SkeletonDescriptor) -> String? {
        guard let json = encodeJSON(descriptor) else { return nil }
        let resultPtr = json.withCString { cString -> UnsafeMutablePointer<CChar>? in
            artia_skeleton_validate_descriptor(cString)
        }
        guard let ptr = resultPtr else { return nil }
        let message = String(cString: ptr)
        artia_free_string(ptr)
        if message.contains("\"error\"") { return nil }
        return message
    }

    // MARK: - Helpers

    /// 単位行列 (列優先 4x4)。
    static func identityMatrix() -> SkeletonMat4 {
        [
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, 1, 0],
            [0, 0, 0, 1]
        ]
    }

    /// 2D 並行移動行列 (列優先)。
    static func translationMatrix(x: Float, y: Float) -> SkeletonMat4 {
        [
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, 1, 0],
            [x, y, 0, 1]
        ]
    }

    /// 2D z 軸回転行列 (radians)。
    static func rotationZMatrix(radians: Float) -> SkeletonMat4 {
        let c = cos(radians)
        let s = sin(radians)
        return [
            [c, s, 0, 0],
            [-s, c, 0, 0],
            [0, 0, 1, 0],
            [0, 0, 0, 1]
        ]
    }

    private static func encodeJSON<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
