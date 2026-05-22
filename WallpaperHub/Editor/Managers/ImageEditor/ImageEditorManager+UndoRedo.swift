import Foundation
import AppKit
import AVFoundation
import Combine
import MetalKit
import UniformTypeIdentifiers

// MARK: - ImageEditorManager + UndoRedo
// Why: アンドゥ/リドゥ、Rust 側 WGPU エンジンとの状態同期を集約。

extension ImageEditorManager {

    func saveUndoSnapshot(description: String) {
        do {
            let data = try JSONEncoder().encode(project)
            undoStack.append(EditorProjectSnapshot(projectData: data, description: description))
            if undoStack.count > maxUndoSteps {
                undoStack.removeFirst()
            }
            redoStack.removeAll()
        } catch {
            debugLog("[ImageEditorManager] Undoスナップショット保存失敗: \(error.localizedDescription)")
        }
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }

        // 現在の状態をRedoスタックに保存
        if let currentData = try? JSONEncoder().encode(project) {
            redoStack.append(EditorProjectSnapshot(projectData: currentData, description: snapshot.description))
        }

        // スナップショットから復元
        if let restored = try? JSONDecoder().decode(EditorProject.self, from: snapshot.projectData) {
            project = restored
            selectedLayerID = restored.selectedLayerID
            reloadAllTextures()
            requestRender()
            debugLog("[ImageEditorManager] Undo: \(snapshot.description)")
        }
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }

        // 現在の状態をUndoスタックに保存
        if let currentData = try? JSONEncoder().encode(project) {
            undoStack.append(EditorProjectSnapshot(projectData: currentData, description: snapshot.description))
        }

        // スナップショットから復元
        if let restored = try? JSONDecoder().decode(EditorProject.self, from: snapshot.projectData) {
            project = restored
            selectedLayerID = restored.selectedLayerID
            reloadAllTextures()
            requestRender()
            debugLog("[ImageEditorManager] Redo: \(snapshot.description)")
        }
    }

    func reloadAllTextures() {
        let device = renderer?.metalDevice ?? metalDevice

        // WGPUエンジンを再作成
        rebuildWgpuEngine()

        for layer in project.layers {
            if let videoPath = layer.videoPath {
                // 動画レイヤー: VideoFrameExtractorを再作成
                let url = URL(fileURLWithPath: videoPath)
                if FileManager.default.fileExists(atPath: videoPath),
                   let dev = device,
                   let extractor = VideoFrameExtractor(url: url, device: dev) {
                    layer.videoFrameExtractor = extractor
                    layer.texture = extractor.thumbnailTexture()

                    // WGPUエンジンに再登録
                    if let engine = wgpuEngine,
                       let rgbaData = extractFirstFrameRGBA(extractor: extractor) {
                        let w = UInt32(layer.videoWidth)
                        let h = UInt32(layer.videoHeight)
                        if let rustID = RustCore.wgpuAddLayer(
                            engine, name: layer.name, width: w, height: h, rgbaData: rgbaData
                        ) {
                            layer.rustLayerID = rustID
                            syncLayerPropertiesToRust(layer, rustLayerID: rustID)
                        }
                    }

                    debugLog("[ImageEditorManager] 動画レイヤー再ロード: \(layer.name)")
                }
            } else if let path = layer.imagePath {
                // 画像レイヤー
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: path) {
                    if let dev = device {
                        layer.loadTexture(from: url, device: dev)
                    }

                    // WGPUエンジンに再登録
                    if let engine = wgpuEngine {
                        layer.rustLayerID = RustCore.wgpuAddLayerFromFile(
                            engine, name: layer.name, filePath: path
                        )
                        if let rustID = layer.rustLayerID {
                            syncLayerPropertiesToRust(layer, rustLayerID: rustID)
                        }
                    }
                }
            }
        }

        syncRustLayerStackOrder()
    }

    func syncEffectMaskToWgpuEngine() {
        guard let engine = wgpuEngine else { return }
        guard let maskData = EffectManager.shared.maskData else { return }
        let w = UInt32(project.canvasWidth)
        let h = UInt32(project.canvasHeight)
        guard maskData.width == Int(w), maskData.height == Int(h) else {
            debugLog("[ImageEditorManager] マスク解像度がキャンバスと一致しません (\(maskData.width)x\(maskData.height))")
            return
        }
        if maskData.data.allSatisfy({ $0 == 255 }) {
            RustCore.wgpuClearMask(engine)
        } else {
            RustCore.wgpuSetMaskTexture(engine, width: w, height: h, maskData: Data(maskData.data))
        }
        requestRender()
    }

    func syncRustLayerStackOrder() {
        guard let engine = wgpuEngine else { return }
        let ids = project.layers.compactMap { $0.rustLayerID }
        guard ids.count == project.layers.count, !ids.isEmpty else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: ids, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        if !RustCore.wgpuSetLayerStackOrderJson(engine, json: json) {
            debugLog("[ImageEditorManager] Rustレイヤースタック同期失敗")
        }
    }

    func rebuildWgpuEngine() {
        if let engine = wgpuEngine {
            RustCore.destroyWgpuEngine(engine)
            wgpuEngine = nil
        }

        let w = UInt32(project.canvasWidth)
        let h = UInt32(project.canvasHeight)
        wgpuEngine = RustCore.createWgpuEngine(width: w, height: h)

        if let engine = wgpuEngine {
            updateIOSurfaceTexture(engine: engine)
        }
    }

    func syncLayerPropertiesToRust(_ layer: EditorLayer, rustLayerID: String) {
        guard let engine = wgpuEngine else { return }

        RustCore.wgpuSetLayerOpacity(engine, layerId: rustLayerID, opacity: layer.opacity)
        RustCore.wgpuSetLayerBlendMode(engine, layerId: rustLayerID, blendMode: UInt32(layer.blendMode.rawValue))
        RustCore.wgpuSetLayerVisible(engine, layerId: rustLayerID, visible: layer.isVisible)

        let transformJson = transformToJSON(layer.transform)
        RustCore.wgpuSetLayerEditorTransform(engine, layerId: rustLayerID, transformJson: transformJson)

        let adj = layer.filterPreset == .none
            ? layer.adjustments
            : layer.filterPreset.adjustments.merged(with: layer.adjustments)
        let adjJson = adjustmentsToJSON(adj, filterType: layer.filterPreset.rawValue)
        RustCore.wgpuSetLayerAdjustments(engine, layerId: rustLayerID, adjustmentsJson: adjJson)
    }

    func adjustmentsToJSON(_ adj: ImageAdjustments, filterType: Int = 0) -> String {
        return """
        {"brightness":\(adj.brightness),"contrast":\(adj.contrast),"saturation":\(adj.saturation),\
        "temperature":\(adj.temperature),"sharpness":\(adj.sharpness),"gamma":\(adj.gamma),\
        "exposure":\(adj.exposure),"filter_type":\(filterType)}
        """
    }

    func transformToJSON(_ t: LayerTransform) -> String {
        return """
        {"offsetX":\(t.offsetX),"offsetY":\(t.offsetY),"scaleX":\(t.scaleX),"scaleY":\(t.scaleY),\
        "rotation":\(t.rotation),"flipHorizontal":\(t.flipHorizontal),"flipVertical":\(t.flipVertical)}
        """
    }
}
