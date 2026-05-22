import Foundation
import AppKit
import AVFoundation
import Combine
import MetalKit
import UniformTypeIdentifiers

// MARK: - ImageEditorManager + SelectionToLayer
// Why: 選択範囲からの「レイヤーをコピー/カット作成」処理を集約。

extension ImageEditorManager {

    func layerViaCopyFromSelection() {
        guard let mask = selection.mask, mask.width == project.canvasWidth, mask.height == project.canvasHeight else { return }
        guard let sourceLayer = selectedLayer else { return }
        guard !sourceLayer.isLocked else { return }
        guard let renderer = renderer else { return }

        saveUndoSnapshot(description: "選択範囲をレイヤーに（コピー）")

        // ソースレイヤーのみをキャンバスにレンダリングしてベイクする
        renderer.composeLayers([sourceLayer], canvasSize: project.canvasSize)
        guard let baked = renderer.exportAsImage(),
              let bakedRGBA = imageToRGBA(baked) else { return }

        let (maskedRGBA, w, h) = applySelectionMaskToRGBA(
            rgba: bakedRGBA,
            width: project.canvasWidth,
            height: project.canvasHeight,
            mask: mask,
            mode: .keepInside
        )

        guard let newImage = rgbaToNSImage(data: maskedRGBA, width: w, height: h) else { return }
        let newLayer = EditorLayer(name: "\(sourceLayer.name) 選択")
        newLayer.imagePath = nil
        newLayer.imageWidth = w
        newLayer.imageHeight = h
        newLayer.transform = .identity

        if let device = renderer.metalDevice as MTLDevice? {
            newLayer.loadTexture(from: newImage, device: device)
        }

        if let engine = wgpuEngine, let rgbaData = imageToRGBA(newImage) {
            let rw = UInt32(w)
            let rh = UInt32(h)
            newLayer.rustLayerID = RustCore.wgpuAddLayer(engine, name: newLayer.name, width: rw, height: rh, rgbaData: rgbaData)
            if let rustID = newLayer.rustLayerID {
                syncLayerPropertiesToRust(newLayer, rustLayerID: rustID)
            }
        }

        // 選択レイヤーの上に挿入
        if let idx = project.layerIndex(for: sourceLayer.id) {
            project.layers.insert(newLayer, at: idx + 1)
        } else {
            project.layers.append(newLayer)
        }
        syncRustLayerStackOrder()
        selectLayer(newLayer.id)
        clearSelection()
        isModified = true
        requestRender()
    }

    func layerViaCutFromSelection() {
        guard let mask = selection.mask, mask.width == project.canvasWidth, mask.height == project.canvasHeight else { return }
        guard let sourceLayer = selectedLayer else { return }
        guard !sourceLayer.isLocked else { return }
        guard let renderer = renderer else { return }

        saveUndoSnapshot(description: "選択範囲をレイヤーに（切り取り）")

        // ソースレイヤーのみをキャンバスにレンダリングしてベイク
        renderer.composeLayers([sourceLayer], canvasSize: project.canvasSize)
        guard let baked = renderer.exportAsImage(),
              let bakedRGBA = imageToRGBA(baked) else { return }

        // 1) 新レイヤー用（選択内だけ保持）
        let (copiedRGBA, w, h) = applySelectionMaskToRGBA(
            rgba: bakedRGBA,
            width: project.canvasWidth,
            height: project.canvasHeight,
            mask: mask,
            mode: .keepInside
        )
        guard let copiedImage = rgbaToNSImage(data: copiedRGBA, width: w, height: h) else { return }

        // 2) 元レイヤー更新用（選択内を透明化）
        let (cutRGBA, _, _) = applySelectionMaskToRGBA(
            rgba: bakedRGBA,
            width: project.canvasWidth,
            height: project.canvasHeight,
            mask: mask,
            mode: .clearInside
        )
        guard let cutImage = rgbaToNSImage(data: cutRGBA, width: w, height: h) else { return }

        // 新規レイヤー作成
        let newLayer = EditorLayer(name: "\(sourceLayer.name) 選択")
        newLayer.imagePath = nil
        newLayer.imageWidth = w
        newLayer.imageHeight = h
        newLayer.transform = .identity
        if let device = renderer.metalDevice as MTLDevice? {
            newLayer.loadTexture(from: copiedImage, device: device)
        }

        // 元レイヤーを「ベイク済みキャンバスサイズ画像」に差し替え（MVP: 破壊編集）
        sourceLayer.imagePath = nil
        sourceLayer.imageWidth = w
        sourceLayer.imageHeight = h
        sourceLayer.transform = .identity
        if let device = renderer.metalDevice as MTLDevice? {
            sourceLayer.loadTexture(from: cutImage, device: device)
        }

        if let engine = wgpuEngine {
            // 元レイヤー差し替え: いったん削除→再追加（mergeDownと同方式）
            if let oldRust = sourceLayer.rustLayerID {
                RustCore.wgpuRemoveLayer(engine, layerId: oldRust)
            }
            if let rgbaData = imageToRGBA(cutImage) {
                let rw = UInt32(w)
                let rh = UInt32(h)
                sourceLayer.rustLayerID = RustCore.wgpuAddLayer(engine, name: sourceLayer.name, width: rw, height: rh, rgbaData: rgbaData)
                if let rustID = sourceLayer.rustLayerID {
                    syncLayerPropertiesToRust(sourceLayer, rustLayerID: rustID)
                }
            }

            // 新レイヤー追加
            if let rgbaData = imageToRGBA(copiedImage) {
                let rw = UInt32(w)
                let rh = UInt32(h)
                newLayer.rustLayerID = RustCore.wgpuAddLayer(engine, name: newLayer.name, width: rw, height: rh, rgbaData: rgbaData)
                if let rustID = newLayer.rustLayerID {
                    syncLayerPropertiesToRust(newLayer, rustLayerID: rustID)
                }
            }
        }

        if let idx = project.layerIndex(for: sourceLayer.id) {
            project.layers.insert(newLayer, at: idx + 1)
        } else {
            project.layers.append(newLayer)
        }
        syncRustLayerStackOrder()
        selectLayer(newLayer.id)
        clearSelection()
        isModified = true
        requestRender()
    }

    func applySelectionMaskToRGBA(
        rgba: Data,
        width: Int,
        height: Int,
        mask: SelectionMask,
        mode: SelectionMaskApplyMode
    ) -> (Data, Int, Int) {
        let pixelCount = width * height
        guard rgba.count >= pixelCount * 4, mask.data.count >= pixelCount else {
            return (rgba, width, height)
        }
        let keepInside = mode == .keepInside
        if let out = RustCore.rgbaApplySelectionMask(
            rgba: rgba,
            width: width,
            height: height,
            mask: mask.data,
            keepInside: keepInside
        ) {
            return (out, width, height)
        }
        return (rgba, width, height)
    }
}
