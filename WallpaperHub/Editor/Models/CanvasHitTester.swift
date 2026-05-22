import Foundation
import AppKit

/// レイヤーのヒットテスト・バウンディングボックス計算
/// シェーダーの transformUV と同一ロジックでレイヤーの表示領域を算出する
enum CanvasHitTester {

    // MARK: - リサイズハンドル位置

    /// バウンディングボックスの8方向ハンドル
    enum HandlePosition: CaseIterable {
        case topLeft, topCenter, topRight
        case middleLeft, middleRight
        case bottomLeft, bottomCenter, bottomRight
    }

    // MARK: - バウンディングボックス計算

    /// レイヤーのバウンディングボックスをキャンバス座標で計算する
    /// Rust WGPUエンジン (EditorTransform.to_matrix) と同一のロジック:
    ///   NDC空間: sx = scale_x * layer_w / canvas_w
    ///   キャンバスピクセル: width = scale_x * layer_w
    /// scale=1.0のとき画像の元解像度がそのまま表示される
    static func boundingBox(for layer: EditorLayer, canvasSize: CGSize) -> CGRect {
        let canvasW = canvasSize.width
        let canvasH = canvasSize.height
        let layerW = CGFloat(layer.imageWidth > 0 ? layer.imageWidth : layer.videoWidth)
        let layerH = CGFloat(layer.imageHeight > 0 ? layer.imageHeight : layer.videoHeight)

        guard layerW > 0, layerH > 0, canvasW > 0, canvasH > 0 else {
            return .zero
        }

        // Rust側と同じ計算: scale=1.0で画像の元ピクセルサイズがそのまま表示される
        let t = layer.transform
        let finalW = layerW * CGFloat(t.scaleX)
        let finalH = layerH * CGFloat(t.scaleY)

        // キャンバス中央 + オフセット
        let centerX = canvasW / 2 + CGFloat(t.offsetX)
        let centerY = canvasH / 2 + CGFloat(t.offsetY)

        return CGRect(
            x: centerX - finalW / 2,
            y: centerY - finalH / 2,
            width: finalW,
            height: finalH
        )
    }

    // MARK: - ヒットテスト

    /// キャンバス座標の点がどのレイヤーに当たるか（最前面から判定）
    static func hitTest(
        point: CGPoint,
        layers: [EditorLayer],
        canvasSize: CGSize
    ) -> EditorLayer? {
        // レイヤーは配列の後ろほど上に表示されるため、逆順で判定
        for layer in layers.reversed() {
            guard layer.isVisible, !layer.isLocked else { continue }

            let rect = boundingBox(for: layer, canvasSize: canvasSize)
            guard !rect.isEmpty else { continue }

            // 回転がある場合は回転を考慮したヒットテスト
            if abs(layer.transform.rotation) > 0.001 {
                if hitTestRotated(point: point, rect: rect, rotation: CGFloat(layer.transform.rotation)) {
                    return layer
                }
            } else {
                if rect.contains(point) {
                    return layer
                }
            }
        }
        return nil
    }

    /// 回転を考慮したヒットテスト
    /// テスト対象の点を逆回転してからAABBテストを行う
    private static func hitTestRotated(
        point: CGPoint,
        rect: CGRect,
        rotation: CGFloat
    ) -> Bool {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = point.x - center.x
        let dy = point.y - center.y

        // 点を逆回転
        let cosR = cos(-rotation)
        let sinR = sin(-rotation)
        let localX = dx * cosR - dy * sinR + center.x
        let localY = dx * sinR + dy * cosR + center.y

        return rect.contains(CGPoint(x: localX, y: localY))
    }

    // MARK: - ハンドル位置

    /// 指定ハンドルのキャンバス座標上の位置を返す
    static func handlePosition(_ handle: HandlePosition, for rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft:      return CGPoint(x: rect.minX, y: rect.minY)
        case .topCenter:    return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight:     return CGPoint(x: rect.maxX, y: rect.minY)
        case .middleLeft:   return CGPoint(x: rect.minX, y: rect.midY)
        case .middleRight:  return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomLeft:   return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomCenter: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomRight:  return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    /// キャンバス座標の点がどのハンドルに近いか判定する
    /// - Parameter handleRadius: ハンドルの当たり判定半径（キャンバス座標）
    static func hitTestHandle(
        point: CGPoint,
        layerRect: CGRect,
        handleRadius: CGFloat
    ) -> HandlePosition? {
        let radiusSq = handleRadius * handleRadius

        for handle in HandlePosition.allCases {
            let pos = handlePosition(handle, for: layerRect)
            let dx = point.x - pos.x
            let dy = point.y - pos.y
            if dx * dx + dy * dy <= radiusSq {
                return handle
            }
        }
        return nil
    }

    /// ハンドル位置に応じたカーソルスタイル
    static func cursorForHandle(_ handle: HandlePosition) -> NSCursor {
        switch handle {
        case .topLeft, .bottomRight:
            return NSCursor(image: NSCursor.arrow.image, hotSpot: NSPoint(x: 8, y: 8))
        case .topRight, .bottomLeft:
            return NSCursor(image: NSCursor.arrow.image, hotSpot: NSPoint(x: 8, y: 8))
        case .topCenter, .bottomCenter:
            return NSCursor.resizeUpDown
        case .middleLeft, .middleRight:
            return NSCursor.resizeLeftRight
        }
    }
}
