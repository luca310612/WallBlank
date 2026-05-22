import Foundation
import SwiftUI

/// キャンバスのビューポート状態（ズーム、パン、座標変換）を管理する
/// Photoshopのようにキャンバスをズーム・パンしながら操作するための座標系を提供
class CanvasViewport: ObservableObject {

    // MARK: - ビューポート状態

    /// ユーザーズーム倍率（1.0 = ビューにフィット）
    @Published var zoomLevel: CGFloat = 1.0

    /// スクリーン座標でのパンオフセット
    @Published var panOffset: CGPoint = .zero

    /// ビューの実サイズ（GeometryReaderから設定）
    @Published var viewSize: CGSize = .zero

    // MARK: - キャンバスプロパティ

    /// キャンバス幅（ピクセル）
    var canvasWidth: CGFloat = 1920

    /// キャンバス高さ（ピクセル）
    var canvasHeight: CGFloat = 1080

    // MARK: - ズーム制限

    static let minZoom: CGFloat = 0.05
    static let maxZoom: CGFloat = 16.0

    // MARK: - 計算プロパティ

    /// ビューにフィットするための基本スケール（余白20px含む）
    var fitScale: CGFloat {
        guard viewSize.width > 0, viewSize.height > 0,
              canvasWidth > 0, canvasHeight > 0 else { return 1.0 }
        let marginedWidth = viewSize.width - 40
        let marginedHeight = viewSize.height - 40
        guard marginedWidth > 0, marginedHeight > 0 else { return 1.0 }
        return min(marginedWidth / canvasWidth, marginedHeight / canvasHeight)
    }

    /// 総合スケール（fitScale × zoomLevel）
    var totalScale: CGFloat {
        fitScale * zoomLevel
    }

    /// キャンバスの表示サイズ（スクリーンピクセル）
    var displayedCanvasSize: CGSize {
        CGSize(
            width: canvasWidth * totalScale,
            height: canvasHeight * totalScale
        )
    }

    /// キャンバス左上隅のビュー座標
    var canvasOriginInView: CGPoint {
        let displayed = displayedCanvasSize
        return CGPoint(
            x: (viewSize.width - displayed.width) / 2 + panOffset.x,
            y: (viewSize.height - displayed.height) / 2 + panOffset.y
        )
    }

    /// ズーム率（パーセント表示用）
    var zoomPercent: Int {
        Int(totalScale * 100)
    }

    // MARK: - 座標変換

    /// スクリーン座標 → キャンバス座標
    func screenToCanvas(_ screenPoint: CGPoint) -> CGPoint {
        let origin = canvasOriginInView
        let scale = totalScale
        guard scale > 0 else { return .zero }
        return CGPoint(
            x: (screenPoint.x - origin.x) / scale,
            y: (screenPoint.y - origin.y) / scale
        )
    }

    /// キャンバス座標 → スクリーン座標
    func canvasToScreen(_ canvasPoint: CGPoint) -> CGPoint {
        let origin = canvasOriginInView
        let scale = totalScale
        return CGPoint(
            x: canvasPoint.x * scale + origin.x,
            y: canvasPoint.y * scale + origin.y
        )
    }

    /// スクリーン上の長さ → キャンバス上の長さ
    func screenLengthToCanvas(_ length: CGFloat) -> CGFloat {
        let scale = totalScale
        guard scale > 0 else { return 0 }
        return length / scale
    }

    // MARK: - ビューポート操作

    /// 指定スクリーン位置を中心にズーム
    func zoomBy(_ factor: CGFloat, center: CGPoint) {
        // ズーム前のキャンバス座標を記録
        let canvasPoint = screenToCanvas(center)

        // ズームレベル更新
        zoomLevel = max(Self.minZoom, min(Self.maxZoom, zoomLevel * factor))

        // ズーム後に同じキャンバス座標がマウス位置に来るようパンを補正
        let newScreenPoint = canvasToScreen(canvasPoint)
        panOffset.x += center.x - newScreenPoint.x
        panOffset.y += center.y - newScreenPoint.y
    }

    /// ビュー全体にフィット
    func fitToView() {
        zoomLevel = 1.0
        panOffset = .zero
    }

    /// 100%表示（キャンバス1px = スクリーン1px）
    func zoom100Percent() {
        let scale = fitScale
        guard scale > 0 else { return }
        // fitScale * zoomLevel = 1.0 となるzoomLevelを求める
        zoomLevel = 1.0 / scale
        panOffset = .zero
    }

    /// キャンバスサイズを更新（プロジェクト変更時）
    func updateCanvasSize(width: CGFloat, height: CGFloat) {
        canvasWidth = width
        canvasHeight = height
    }
}
