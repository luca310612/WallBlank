import Foundation

// MARK: - スマッジブラシエンジン
// Why: 下地ピクセルを引きずって混ぜる「指でこする」挙動の Strategy 実装。
// 実際のピクセル引きずり合成は GPU compute（Phase 1.4）で BrushMaskRasterizer に
// 追加するため、本クラスはストロークサンプリング（細かいスタンプ列）に責務を絞る。
//
// 設計上の差分:
// - spacing 比率を 0.05 と狭く取る → スタンプ列が密になり、引きずり合成時に滑らかにブレンドされる。
// - 速度が遅いほど混ざりが強く感じられるよう、追加のサンプリング補正は入れない
//   （速度反応は Phase 1.4 の rasterizer 側で alpha モジュレーションとして実装する想定）。

final class SmudgeBrushEngine: BrushEngine {
    let id: BrushEngineID = .smudge
    let displayName: String = "スマッジ"
    let supportsPressure: Bool = true
    let supportsTilt: Bool = false

    /// 引きずりを滑らかにするため、スタンプを密に配置する。
    private let spacingRatio: CGFloat = 0.05

    func beginStroke(context: inout BrushStrokeContext, sample: BrushInputSample) -> [CGPoint] {
        context.append(sample)
        context.appendStamp(sample.position)
        return [sample.position]
    }

    func continueStroke(context: inout BrushStrokeContext, sample: BrushInputSample) -> [CGPoint] {
        guard let lastStamp = context.lastStampPoint else {
            return beginStroke(context: &context, sample: sample)
        }
        context.append(sample)

        let radius = max(0.1, context.stroke.radius)
        let spacing = max(0.5, radius * 2 * spacingRatio)

        var leftover = context.distanceSinceLastStamp
        let newStamps = stampPositions(
            from: lastStamp,
            to: sample.position,
            spacing: spacing,
            leftover: &leftover
        )
        context.distanceSinceLastStamp = leftover

        for p in newStamps {
            context.appendStamp(p)
        }
        return newStamps
    }

    func endStroke(context: inout BrushStrokeContext, sample: BrushInputSample) -> [CGPoint] {
        continueStroke(context: &context, sample: sample)
    }

    /// スマッジは圧力を「引きずり強度」へマッピング。
    /// 弱圧では下地がほぼ動かないよう 0.15 を下限とする。
    func pressureResponse(for sample: BrushInputSample) -> BrushPressureResponse {
        var r = BrushPressureResponse.identity
        r.strengthMultiplier = max(0.15, min(1.0, sample.pressure))
        return r
    }
}
