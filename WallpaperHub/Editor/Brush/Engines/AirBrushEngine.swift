import Foundation

// MARK: - エアブラシエンジン
// Why: 圧力と速度に応じてスタンプ間隔を細かくし、ふんわり積層する挙動を表現。
// CircleBrush に対して spacing 比率を狭め、低圧時は間隔を広げて不透明度蓄積を抑える。

final class AirBrushEngine: BrushEngine {
    let id: BrushEngineID = .airbrush
    let displayName: String = "エアブラシ"
    let supportsPressure: Bool = true
    let supportsTilt: Bool = true

    /// ベース間隔比率（CircleBrush の半分=0.05 で密に積層）
    private let baseSpacingRatio: CGFloat = 0.05

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

        // 圧力に応じて spacing を調整: 弱圧=広め(粒が見える)、強圧=密
        let radius = max(0.1, context.stroke.radius)
        let pressureFactor: CGFloat = max(0.2, sample.pressure)
        let spacing = max(0.5, radius * 2 * baseSpacingRatio / pressureFactor)

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

    /// エアブラシは圧力を「フロー」へマッピング。
    /// 弱圧でも完全停止しないよう 0.1 を下限とする (薄く色が乗り続ける)。
    func pressureResponse(for sample: BrushInputSample) -> BrushPressureResponse {
        var r = BrushPressureResponse.identity
        r.flowMultiplier = max(0.1, min(1.0, sample.pressure))
        return r
    }
}
