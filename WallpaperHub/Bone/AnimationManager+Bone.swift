import Foundation

// Phase 4C: AnimationManager の Bone keyframe 拡張
// Why: 既存 AnimationManager は image/canvas のアニメーションを扱うが、Phase 4C で
//      ボーンキーフレームをサポートする。本 extension は Codable な keyframe + 補間
//      ヘルパに留め、既存 AnimationManager の本体は変更しない。
//      実際の pose 更新 (FFI 呼び出し) は呼び出し側が `SkeletonBridge.updatePose` を行う。

/// 1 つのボーンキーフレーム。
struct BoneKeyframe: Codable, Equatable {
    /// アニメーション開始からの秒数 (0.0 が開始)。
    var time: Float
    /// 全ボーン分のローカル行列 (Skeleton.bone_count と一致が必要)。
    var localMatrices: [SkeletonMat4]

    enum CodingKeys: String, CodingKey {
        case time
        case localMatrices = "local_matrices"
    }
}

/// ボーンキーフレーム列。
struct BoneAnimationClip: Codable, Equatable {
    var name: String
    var duration: Float
    var keyframes: [BoneKeyframe]

    /// 指定時刻の `local_matrices` を線形補間で生成する。
    /// - 範囲外は最初/最後の keyframe を返す (clamp)。
    /// - keyframes が空のときは nil。
    func sample(at time: Float) -> [SkeletonMat4]? {
        guard !keyframes.isEmpty else { return nil }
        let sorted = keyframes.sorted(by: { $0.time < $1.time })
        if time <= sorted.first!.time {
            return sorted.first!.localMatrices
        }
        if time >= sorted.last!.time {
            return sorted.last!.localMatrices
        }
        // バイナリサーチ的な補間先頭を線形検索 (キーフレーム数は通常少ない)
        for i in 0..<sorted.count - 1 {
            let a = sorted[i]
            let b = sorted[i + 1]
            if time >= a.time && time <= b.time {
                let span = max(b.time - a.time, 1e-6)
                let t = (time - a.time) / span
                return BoneAnimationClip.lerpMatrices(a.localMatrices, b.localMatrices, t: t)
            }
        }
        return sorted.last!.localMatrices
    }

    /// 線形補間 (component-wise)。Slerp は将来対応 (回転を分解する必要があるため)。
    static func lerpMatrices(
        _ a: [SkeletonMat4],
        _ b: [SkeletonMat4],
        t: Float
    ) -> [SkeletonMat4] {
        let n = min(a.count, b.count)
        var result: [SkeletonMat4] = []
        result.reserveCapacity(n)
        for i in 0..<n {
            var blended: SkeletonMat4 = SkeletonBridge.identityMatrix()
            for col in 0..<4 {
                for row in 0..<4 {
                    let av = a[i][col][row]
                    let bv = b[i][col][row]
                    blended[col][row] = av + (bv - av) * t
                }
            }
            result.append(blended)
        }
        return result
    }
}

/// AnimationManager に bone clip 用 API を追加する extension。
/// 既存 AnimationManager は壁紙画像/エフェクトのアニメを扱うが、ここでは
/// ボーンクリップをスタンドアロンに評価できるユーティリティのみを提供する。
extension AnimationManager {
    /// 指定 clip と時刻から SkeletonPoseParams を組み立てる。
    /// - 戻り値: keyframes が空の場合は nil。
    func evaluateBoneClip(
        _ clip: BoneAnimationClip,
        atTime time: Float
    ) -> SkeletonPoseParams? {
        guard let matrices = clip.sample(at: time) else { return nil }
        return SkeletonPoseParams(localMatrices: matrices)
    }
}
