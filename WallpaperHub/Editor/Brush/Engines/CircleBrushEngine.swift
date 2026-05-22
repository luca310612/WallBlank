import Foundation

// MARK: - 円形ブラシエンジン
// Why: 既存の自由ペン（freeform）の挙動を BrushEngine 抽象に乗せた実装。
// 既存パスとピクセル一致させるため、特別な圧力反応や速度補正は入れない。

final class CircleBrushEngine: BrushEngine {
    let id: BrushEngineID = .circle
    let displayName: String = "円形ブラシ"
    let supportsPressure: Bool = true
    let supportsTilt: Bool = false

    /// 直径に対するスタンプ間隔の比率（一般的には 0.1〜0.25）
    private let spacingRatio: CGFloat = 0.1

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
        // 終端は continueStroke と同じ扱い（最後のサンプルでスタンプを追加）
        let stamps = continueStroke(context: &context, sample: sample)
        return stamps
    }

    /// 円形ブラシは圧力を「半径」へマッピング。
    /// pressure=0 でも完全に消えないよう 0.2 を下限としてクランプ。
    func pressureResponse(for sample: BrushInputSample) -> BrushPressureResponse {
        var r = BrushPressureResponse.identity
        r.radiusMultiplier = max(0.2, min(1.0, sample.pressure))
        return r
    }
}
