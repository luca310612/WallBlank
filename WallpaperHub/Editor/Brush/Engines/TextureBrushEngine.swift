import Foundation

// MARK: - テクスチャブラシエンジン
// Why: 画像テクスチャをストロークに沿って粒として落とす Strategy 実装。
// CircleBrush との差は「スタンプ間隔」のみで、ラスタ化（テクスチャ画像のサンプル合成）は
// Phase 1.4 の GPU compute 化フェーズで BrushMaskRasterizer 側に追加する想定。
// 本クラスは Strategy 抽象に乗せるためのストローク生成責務に閉じる。
//
// 設計上の差分:
// - spacing 比率を 0.25 と広めに取る → スタンプ間隔が空き、テクスチャの粒感が見える。
// - 圧力でスタンプ間隔を細かくする（強圧=密、弱圧=粒が散らばる）。

final class TextureBrushEngine: BrushEngine {
    let id: BrushEngineID = .texture
    let displayName: String = "テクスチャブラシ"
    let supportsPressure: Bool = true
    let supportsTilt: Bool = true

    /// テクスチャ粒が見えるよう CircleBrush(0.1) より大幅に広い既定値。
    private let baseSpacingRatio: CGFloat = 0.25

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
        // 圧力が強いほど spacing を狭めて積層感を出す（弱圧時は粒が離散的に見える）。
        let pressureFactor: CGFloat = max(0.3, sample.pressure)
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

    /// テクスチャブラシは圧力を「粒密度」へマッピング。
    /// 弱圧でも 0.3 程度は粒が出るようクランプし、テクスチャの存在感を保つ。
    func pressureResponse(for sample: BrushInputSample) -> BrushPressureResponse {
        var r = BrushPressureResponse.identity
        r.densityMultiplier = max(0.3, min(1.0, sample.pressure))
        return r
    }
}
