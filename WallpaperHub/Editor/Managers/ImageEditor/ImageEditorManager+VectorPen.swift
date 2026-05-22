import Foundation
import AppKit
import AVFoundation
import Combine
import MetalKit
import UniformTypeIdentifiers

// MARK: - ImageEditorManager + VectorPen
// Why: Photoshop風ベクターペン操作（アンカー追加/移動/削除/補間）を集約。

extension ImageEditorManager {

    func clearVectorPenState() {
        selection = .init()
        freeformBrushCompletedOutlines = []
        requestRender()
    }

    func appendPenAnchor(at canvasPoint: CGPoint, isCorner: Bool, outHandleOffset: CGPoint?) {
        var s = selection
        s.penPath.isClosed = false
        s.mask = nil
        if isCorner {
            s.penPath.points.append(PenAnchorPoint(point: canvasPoint, outHandleOffset: nil, isCorner: true))
        } else {
            let off = outHandleOffset ?? .zero
            s.penPath.points.append(PenAnchorPoint(point: canvasPoint, outHandleOffset: off, isCorner: false))
        }
        selection = s
        requestRender()
    }

    func appendCurvaturePenAnchorClick(at canvasPoint: CGPoint) {
        var s = selection
        s.penPath.isClosed = false
        s.mask = nil
        if let prev = s.penPath.points.last {
            let dx = canvasPoint.x - prev.point.x
            let dy = canvasPoint.y - prev.point.y
            let len = hypot(dx, dy)
            let scale = min(len * 0.28, 120)
            let ux = len > 0.5 ? dx / len * scale : scale
            let uy = len > 0.5 ? dy / len * scale : 0
            s.penPath.points.append(PenAnchorPoint(point: canvasPoint, outHandleOffset: CGPoint(x: ux, y: uy), isCorner: false))
        } else {
            s.penPath.points.append(PenAnchorPoint(point: canvasPoint, outHandleOffset: nil, isCorner: true))
        }
        selection = s
        requestRender()
    }

    func tryClosePenPath(near canvasPoint: CGPoint, hitRadiusCanvas: CGFloat) -> Bool {
        guard selection.penPath.canClose, let first = selection.penPath.points.first else { return false }
        let d = hypot(canvasPoint.x - first.point.x, canvasPoint.y - first.point.y)
        guard d <= hitRadiusCanvas else { return false }
        var s = selection
        s.penPath.isClosed = true
        if let mask = rasterizeSelectionMask(from: s.penPath) {
            s.mask = mask
        }
        selection = s
        requestRender()
        return true
    }

    func translatePenPath(by delta: CGSize) {
        var s = selection
        guard !s.penPath.points.isEmpty else { return }
        s.mask = nil
        for i in s.penPath.points.indices {
            s.penPath.points[i].point.x += delta.width
            s.penPath.points[i].point.y += delta.height
        }
        if s.penPath.isClosed, s.penPath.points.count >= 3, let mask = rasterizeSelectionMask(from: s.penPath) {
            s.mask = mask
        }
        selection = s
        requestRender()
    }

    func setPenAnchorCanvasPosition(at index: Int, point: CGPoint) {
        var s = selection
        guard index >= 0, index < s.penPath.points.count else { return }
        s.penPath.points[index].point = point
        s.mask = nil
        if s.penPath.isClosed, s.penPath.points.count >= 3, let mask = rasterizeSelectionMask(from: s.penPath) {
            s.mask = mask
        }
        selection = s
        requestRender()
    }

    func closePenPathIfPossible() {
        guard !penToolKind.isFreeformBrushLike, selection.penPath.canClose else { return }
        var s = selection
        s.penPath.isClosed = true
        if let mask = rasterizeSelectionMask(from: s.penPath) {
            s.mask = mask
        }
        selection = s
        requestRender()
    }

    func hitTestPenAnchorIndex(at canvasPoint: CGPoint, radius: CGFloat) -> Int? {
        for (i, p) in selection.penPath.points.enumerated() {
            if hypot(canvasPoint.x - p.point.x, canvasPoint.y - p.point.y) <= radius {
                return i
            }
        }
        return nil
    }

    func removePenAnchor(at index: Int) {
        var s = selection
        guard index >= 0, index < s.penPath.points.count else { return }
        s.penPath.points.remove(at: index)
        s.penPath.isClosed = false
        s.mask = nil
        selection = s
        requestRender()
    }

    func removeLastPenAnchorIfOpenPath() {
        guard !penToolKind.isFreeformBrushLike, !selection.penPath.isClosed, !selection.penPath.points.isEmpty else { return }
        removePenAnchor(at: selection.penPath.points.count - 1)
    }

    func togglePenAnchorCorner(at index: Int) {
        var s = selection
        guard index >= 0, index < s.penPath.points.count else { return }
        if s.penPath.points[index].isCorner {
            s.penPath.points[index].isCorner = false
            let prevPt: CGPoint
            if index > 0 {
                prevPt = s.penPath.points[index - 1].point
            } else if s.penPath.points.count > 1 {
                prevPt = s.penPath.points.last!.point
            } else {
                prevPt = s.penPath.points[index].point
            }
            let dx = s.penPath.points[index].point.x - prevPt.x
            let dy = s.penPath.points[index].point.y - prevPt.y
            let len = max(hypot(dx, dy), 1)
            s.penPath.points[index].outHandleOffset = CGPoint(x: dx / len * 48, y: dy / len * 48)
        } else {
            s.penPath.points[index].isCorner = true
            s.penPath.points[index].outHandleOffset = nil
        }
        s.mask = nil
        if s.penPath.isClosed, s.penPath.points.count >= 3, let mask = rasterizeSelectionMask(from: s.penPath) {
            s.mask = mask
        }
        selection = s
        requestRender()
    }

    func insertPenAnchorOnNearestSegment(at canvasPoint: CGPoint, maxDistance: CGFloat) -> Bool {
        var s = selection
        let pts = s.penPath.points
        let count = pts.count
        guard count >= 2 else { return false }

        var bestDist: CGFloat = .greatestFiniteMagnitude
        var bestInsertIndex = 0
        var bestNewPoint = CGPoint.zero

        if s.penPath.isClosed {
            for i in 0..<count {
                let p0 = pts[i]
                let p1 = pts[(i + 1) % count]
                let hit = closestOnPenSegment(p0: p0, p1: p1, target: canvasPoint, samples: 28)
                if hit.distance < bestDist {
                    bestDist = hit.distance
                    bestNewPoint = hit.point
                    bestInsertIndex = (i == count - 1) ? count : i + 1
                }
            }
        } else {
            for i in 0..<(count - 1) {
                let p0 = pts[i]
                let p1 = pts[i + 1]
                let hit = closestOnPenSegment(p0: p0, p1: p1, target: canvasPoint, samples: 28)
                if hit.distance < bestDist {
                    bestDist = hit.distance
                    bestNewPoint = hit.point
                    bestInsertIndex = i + 1
                }
            }
        }

        guard bestDist <= maxDistance else { return false }

        if bestInsertIndex >= s.penPath.points.count {
            s.penPath.points.append(PenAnchorPoint(point: bestNewPoint, outHandleOffset: nil, isCorner: true))
        } else {
            s.penPath.points.insert(PenAnchorPoint(point: bestNewPoint, outHandleOffset: nil, isCorner: true), at: bestInsertIndex)
        }
        s.penPath.isClosed = false
        s.mask = nil
        selection = s
        requestRender()
        return true
    }

    func closestOnPenSegment(p0: PenAnchorPoint, p1: PenAnchorPoint, target: CGPoint, samples: Int) -> (point: CGPoint, distance: CGFloat) {
        var bestD = CGFloat.greatestFiniteMagnitude
        var bestP = p0.point
        for k in 0...samples {
            let t = CGFloat(k) / CGFloat(samples)
            let pt = PenPath.pointOnSegment(from: p0, to: p1, t: t)
            let d = hypot(pt.x - target.x, pt.y - target.y)
            if d < bestD {
                bestD = d
                bestP = pt
            }
        }
        return (bestP, bestD)
    }
}
