import Foundation
import AppKit
import QuartzCore

// MARK: - 入力サンプル
// Why: マウス・トラックパッド・Apple Pencil・タブレットなど入力デバイスごとの差分を
// 1つの正規化レコードに集約し、BrushEngine 実装が入力源を意識しなくて済むようにする。

/// 1点のブラシ入力サンプル
struct BrushInputSample: Equatable {
    /// キャンバス座標系（pt）
    var position: CGPoint
    /// 圧力 0…1（非対応端末は 1.0）
    var pressure: CGFloat
    /// 傾き角度（度、0=垂直、90=水平）。非対応は 0
    var tiltDegrees: CGFloat
    /// 方位角（度、0=右、反時計回り）。非対応は 0
    var azimuthDegrees: CGFloat
    /// 速度（pt/秒）。直前サンプルとの差分から計算
    var velocity: CGVector
    /// 入力の時刻（CACurrentMediaTime ベース）
    var timestamp: TimeInterval
    /// 予測サンプル（将来 UIPencilInteraction の predicted touch 等で利用）
    var isPredicted: Bool

    init(
        position: CGPoint,
        pressure: CGFloat = 1.0,
        tiltDegrees: CGFloat = 0,
        azimuthDegrees: CGFloat = 0,
        velocity: CGVector = .zero,
        timestamp: TimeInterval = CACurrentMediaTime(),
        isPredicted: Bool = false
    ) {
        self.position = position
        self.pressure = pressure
        self.tiltDegrees = tiltDegrees
        self.azimuthDegrees = azimuthDegrees
        self.velocity = velocity
        self.timestamp = timestamp
        self.isPredicted = isPredicted
    }
}

// MARK: - NSEvent からの抽出
// Why: NSEvent は subtype ごとに pressure/tilt が取れるかどうかが変わる。
// 取得失敗時のフォールバック値を 1ヶ所に集約しておく。

extension BrushInputSample {
    /// NSEvent からブラシ入力サンプルを生成
    /// - Parameters:
    ///   - event: 元イベント
    ///   - canvasPoint: キャンバス座標へ変換済みの位置
    ///   - previous: 直前のサンプル（速度算出に使用）
    static func fromNSEvent(
        _ event: NSEvent,
        at canvasPoint: CGPoint,
        previous: BrushInputSample? = nil
    ) -> BrushInputSample {
        let pressure: CGFloat = {
            // NSEvent.pressure は 0…1 で返る。タブレット非対応マウスでも 1.0 が入る
            CGFloat(event.pressure)
        }()

        // tilt は tablet pointer 系イベントでのみ意味を持つ
        let tilt: CGFloat
        let azimuth: CGFloat
        if event.subtype == .tabletPoint {
            // tilt.x/y は -1…1。垂直からの傾き角に近似変換
            let tx = CGFloat(event.tilt.x)
            let ty = CGFloat(event.tilt.y)
            let tiltMagnitude = sqrt(tx * tx + ty * ty) // 0…sqrt(2)
            tilt = min(1.0, tiltMagnitude) * 90.0
            azimuth = atan2(ty, tx) * 180.0 / .pi
        } else {
            tilt = 0
            azimuth = 0
        }

        let now = CACurrentMediaTime()
        let velocity: CGVector
        if let prev = previous {
            let dt = max(now - prev.timestamp, 0.001)
            velocity = CGVector(
                dx: (canvasPoint.x - prev.position.x) / CGFloat(dt),
                dy: (canvasPoint.y - prev.position.y) / CGFloat(dt)
            )
        } else {
            velocity = .zero
        }

        return BrushInputSample(
            position: canvasPoint,
            pressure: pressure,
            tiltDegrees: tilt,
            azimuthDegrees: azimuth,
            velocity: velocity,
            timestamp: now
        )
    }
}
