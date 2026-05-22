import Foundation
import QuartzCore

// MARK: - ストロークコンテキスト
// Why: 1ストローク中の蓄積状態（入力履歴・スタンプ位置・累積距離など）を
// BrushEngine 実装の外側で管理し、Engine 自体はステートレスに保つ。

/// 1ストローク中に蓄積される状態
struct BrushStrokeContext {
    /// 受け取った生入力サンプル（時系列）
    var samples: [BrushInputSample] = []
    /// 実際に「ダブを打った」位置（スタンプ間隔考慮後）
    var stampPoints: [CGPoint] = []
    /// 直前のスタンプからの累積距離（次のスタンプ判定に使用）
    var distanceSinceLastStamp: CGFloat = 0
    /// 適用するブラシ設定（ストローク開始時に固定）
    let stroke: EditorBrushStrokeSettings
    /// マスクポスト処理（ぼかし・しきい値・ノイズ）。ストローク開始時に固定
    let post: EditorMaskPostSettings
    /// グラデーション設定。ストローク開始時に固定
    let gradient: EditorMaskGradientSettings
    /// マスク合成モード（追加・減算など）。ストローク開始時に固定
    let combine: EditorMaskCombineMode
    /// 描画対象のキャンバスサイズ (px)
    let canvas: CGSize
    /// 既存マスク（差分焼き込み用、無ければ nil）
    var existing: SelectionMask?
    /// ストローク開始時刻
    let startTime: TimeInterval

    init(
        stroke: EditorBrushStrokeSettings,
        post: EditorMaskPostSettings = EditorMaskPostSettings(),
        gradient: EditorMaskGradientSettings = EditorMaskGradientSettings(),
        combine: EditorMaskCombineMode = .add,
        canvas: CGSize = .zero,
        existing: SelectionMask? = nil,
        startTime: TimeInterval = CACurrentMediaTime()
    ) {
        self.stroke = stroke
        self.post = post
        self.gradient = gradient
        self.combine = combine
        self.canvas = canvas
        self.existing = existing
        self.startTime = startTime
    }

    /// 直前のサンプル（速度算出用）
    var lastSample: BrushInputSample? { samples.last }

    /// 直前のスタンプ位置
    var lastStampPoint: CGPoint? { stampPoints.last }

    /// サンプルを追記
    mutating func append(_ sample: BrushInputSample) {
        samples.append(sample)
    }

    /// スタンプ位置を追記
    mutating func appendStamp(_ point: CGPoint) {
        stampPoints.append(point)
        distanceSinceLastStamp = 0
    }

    /// 累積距離を加算
    mutating func addDistance(_ d: CGFloat) {
        distanceSinceLastStamp += d
    }
}
