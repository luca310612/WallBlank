import Foundation

// MARK: - 消しゴムエンジン
// Why: ストローク生成は CircleBrushEngine と同じだが、利用側に「これは減算用」
// という意図を渡すために id と displayName だけ別にしておく。
// マスクへの実際の合成は BrushMaskRasterizer 側の paintMode = .subtract で処理する。

final class EraserBrushEngine: BrushEngine {
    let id: BrushEngineID = .eraser
    let displayName: String = "消しゴム"
    let supportsPressure: Bool = true
    let supportsTilt: Bool = false

    private let inner = CircleBrushEngine()

    func beginStroke(context: inout BrushStrokeContext, sample: BrushInputSample) -> [CGPoint] {
        inner.beginStroke(context: &context, sample: sample)
    }

    func continueStroke(context: inout BrushStrokeContext, sample: BrushInputSample) -> [CGPoint] {
        inner.continueStroke(context: &context, sample: sample)
    }

    func endStroke(context: inout BrushStrokeContext, sample: BrushInputSample) -> [CGPoint] {
        inner.endStroke(context: &context, sample: sample)
    }

    /// 消しゴムは圧力を「不透明度」へマッピング。
    /// 弱圧で消し残しが起きないよう 0.25 を下限とする。
    func pressureResponse(for sample: BrushInputSample) -> BrushPressureResponse {
        var r = BrushPressureResponse.identity
        r.opacityMultiplier = max(0.25, min(1.0, sample.pressure))
        return r
    }
}
