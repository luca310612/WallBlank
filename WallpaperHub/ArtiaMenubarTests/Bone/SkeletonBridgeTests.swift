import Foundation
import XCTest

@testable import WallBlank

/// Phase 4C: SkeletonBridge の Codable / FFI ラウンドトリップ + AnimationManager+Bone 拡張の検証。
final class SkeletonBridgeTests: XCTestCase {

    // MARK: - Helpers

    private func makeDescriptor() -> SkeletonDescriptor {
        SkeletonDescriptor(
            sourceLayerId: "skel-layer",
            bones: [
                BoneDescriptor(
                    name: "root",
                    parentId: -1,
                    localTranslation: [0, 0, 0],
                    localRotation: 0,
                    localScale: [1, 1, 1],
                    length: 10
                ),
                BoneDescriptor(
                    name: "child",
                    parentId: 0,
                    localTranslation: [10, 0, 0],
                    localRotation: 0,
                    localScale: [1, 1, 1],
                    length: 10
                )
            ],
            weights: [
                .single(boneIndex: 0),
                .single(boneIndex: 1)
            ],
            restPositions: [[0, 0], [10, 0]]
        )
    }

    // MARK: - Codable round-trip

    func test_descriptor_jsonRoundTrip_throughRustValidator() throws {
        let descriptor = makeDescriptor()
        guard let normalized = SkeletonBridge.validateDescriptor(descriptor) else {
            XCTFail("Rust 側の validate が nil を返した")
            return
        }
        let data = Data(normalized.utf8)
        let decoded = try JSONDecoder().decode(SkeletonDescriptor.self, from: data)
        XCTAssertEqual(decoded, descriptor)
    }

    func test_boneDescriptor_pureSwiftRoundTrip() throws {
        let bone = BoneDescriptor(
            name: "arm",
            parentId: 1,
            localTranslation: [5, 10, 0],
            localRotation: .pi / 4,
            localScale: [1, 1, 1],
            length: 12
        )
        let data = try JSONEncoder().encode(bone)
        let back = try JSONDecoder().decode(BoneDescriptor.self, from: data)
        XCTAssertEqual(back, bone)
    }

    func test_vertexBoneWeights_pureSwiftRoundTrip() throws {
        let w = VertexBoneWeights(boneIndices: [0, 1, 2, 3], weights: [0.4, 0.3, 0.2, 0.1])
        let data = try JSONEncoder().encode(w)
        let back = try JSONDecoder().decode(VertexBoneWeights.self, from: data)
        XCTAssertEqual(back, w)
    }

    func test_identityMatrix_isCorrect() {
        let m = SkeletonBridge.identityMatrix()
        for col in 0..<4 {
            for row in 0..<4 {
                let expected: Float = (col == row) ? 1 : 0
                XCTAssertEqual(m[col][row], expected, accuracy: Float(1e-6))
            }
        }
    }

    func test_translationMatrix_packsValuesInColumn3() {
        let m = SkeletonBridge.translationMatrix(x: 5, y: 7)
        XCTAssertEqual(m[3][0], Float(5), accuracy: Float(1e-6))
        XCTAssertEqual(m[3][1], Float(7), accuracy: Float(1e-6))
    }

    // MARK: - FFI engine round-trip

    func test_engineRoundTrip_createUpdateDestroy() throws {
        guard let engine = RustCore.createWgpuEngine(width: 128, height: 128) else {
            throw XCTSkip("Metal adapter 未取得のため engine round-trip をスキップ")
        }
        defer { RustCore.destroyWgpuEngine(engine) }

        let descriptor = makeDescriptor()
        let id = SkeletonBridge.create(engine: engine, descriptor: descriptor)
        XCTAssertGreaterThan(id, 0)
        XCTAssertEqual(SkeletonBridge.count(engine: engine), 1)

        // bone 数 (2) と一致する pose を渡す
        let params = SkeletonPoseParams(
            localMatrices: [
                SkeletonBridge.translationMatrix(x: 1, y: 0),
                SkeletonBridge.translationMatrix(x: 10, y: 0)
            ]
        )
        let updateError = SkeletonBridge.updatePose(engine: engine, id: id, params: params)
        XCTAssertNil(updateError, "正しい bone 数の pose 更新は nil を返すべき (\(updateError ?? ""))")

        let destroyed = SkeletonBridge.destroy(engine: engine, id: id)
        XCTAssertTrue(destroyed)
        XCTAssertEqual(SkeletonBridge.count(engine: engine), 0)
    }

    func test_engineUpdatePose_failsForMismatchedBoneCount() throws {
        guard let engine = RustCore.createWgpuEngine(width: 64, height: 64) else {
            throw XCTSkip("Metal adapter 未取得のためスキップ")
        }
        defer { RustCore.destroyWgpuEngine(engine) }

        let descriptor = makeDescriptor()
        let id = SkeletonBridge.create(engine: engine, descriptor: descriptor)

        // bone 数は 2 だが 1 つだけ送る → エラー
        let bad = SkeletonPoseParams(localMatrices: [SkeletonBridge.identityMatrix()])
        let error = SkeletonBridge.updatePose(engine: engine, id: id, params: bad)
        XCTAssertNotNil(error)

        SkeletonBridge.destroy(engine: engine, id: id)
    }

    // MARK: - BoneAnimationClip lerp

    func test_boneAnimationClip_sample_returnsStartBeforeFirstKey() throws {
        let clip = BoneAnimationClip(
            name: "test",
            duration: 1.0,
            keyframes: [
                BoneKeyframe(time: 0.0, localMatrices: [SkeletonBridge.translationMatrix(x: 0, y: 0)]),
                BoneKeyframe(time: 1.0, localMatrices: [SkeletonBridge.translationMatrix(x: 10, y: 0)])
            ]
        )
        let sampled = try XCTUnwrap(clip.sample(at: -0.5))
        XCTAssertEqual(sampled[0][3][0], Float(0), accuracy: Float(1e-4))
    }

    func test_boneAnimationClip_sample_lerpsAtMidpoint() throws {
        let clip = BoneAnimationClip(
            name: "test",
            duration: 1.0,
            keyframes: [
                BoneKeyframe(time: 0.0, localMatrices: [SkeletonBridge.translationMatrix(x: 0, y: 0)]),
                BoneKeyframe(time: 1.0, localMatrices: [SkeletonBridge.translationMatrix(x: 10, y: 0)])
            ]
        )
        let sampled = try XCTUnwrap(clip.sample(at: 0.5))
        XCTAssertEqual(sampled[0][3][0], Float(5), accuracy: Float(1e-4))
    }

    func test_boneAnimationClip_emptyKeyframesReturnsNil() {
        let clip = BoneAnimationClip(name: "empty", duration: 0, keyframes: [])
        XCTAssertNil(clip.sample(at: 0.5))
    }
}
