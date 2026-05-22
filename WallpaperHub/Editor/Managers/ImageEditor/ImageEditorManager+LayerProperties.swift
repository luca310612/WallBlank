import Foundation
import AppKit
import AVFoundation
import Combine
import MetalKit
import UniformTypeIdentifiers

// MARK: - ImageEditorManager + LayerProperties
// Why: レイヤー単体の不透明度/ブレンド/フィルタ/トランスフォーム変更を集約。

extension ImageEditorManager {

    func setLayerOpacity(_ id: UUID, opacity: Float) {
        guard let layer = project.layers.first(where: { $0.id == id }) else { return }
        // スライダー操作開始時に1回だけスナップショットを保存
        if !hasOpacityUndoSnapshot {
            saveUndoSnapshot(description: "不透明度変更")
            hasOpacityUndoSnapshot = true
        }
        layer.opacity = max(0.1, min(1, opacity))

        // Rust WGPUエンジンに同期
        if let engine = wgpuEngine, let rustID = layer.rustLayerID {
            RustCore.wgpuSetLayerOpacity(engine, layerId: rustID, opacity: layer.opacity)
        }

        isModified = true
        requestRender()
        // スライダー操作終了後にフラグをリセット
        opacityUndoWorkItem?.cancel()
        let opacityWork = DispatchWorkItem { [weak self] in
            self?.hasOpacityUndoSnapshot = false
        }
        opacityUndoWorkItem = opacityWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: opacityWork)
    }

    func setLayerBlendMode(_ id: UUID, blendMode: EditorBlendMode) {
        guard let layer = project.layers.first(where: { $0.id == id }) else { return }
        saveUndoSnapshot(description: "ブレンドモード変更")
        layer.blendMode = blendMode

        // Rust WGPUエンジンに同期
        if let engine = wgpuEngine, let rustID = layer.rustLayerID {
            RustCore.wgpuSetLayerBlendMode(engine, layerId: rustID, blendMode: UInt32(blendMode.rawValue))
        }

        isModified = true
        requestRender()
    }

    func toggleLayerVisibility(_ id: UUID) {
        guard let layer = project.layers.first(where: { $0.id == id }) else { return }
        layer.isVisible.toggle()

        // Rust WGPUエンジンに同期
        if let engine = wgpuEngine, let rustID = layer.rustLayerID {
            RustCore.wgpuSetLayerVisible(engine, layerId: rustID, visible: layer.isVisible)
        }

        isModified = true
        requestRender()
    }

    func toggleLayerLock(_ id: UUID) {
        guard let layer = project.layers.first(where: { $0.id == id }) else { return }
        layer.isLocked.toggle()
    }

    func setLayerAdjustments(_ id: UUID, adjustments: ImageAdjustments) {
        guard let layer = project.layers.first(where: { $0.id == id }) else { return }
        if !hasAdjustmentsUndoSnapshot {
            saveUndoSnapshot(description: "画像調整変更")
            hasAdjustmentsUndoSnapshot = true
        }
        layer.adjustments = adjustments

        // Rust WGPUエンジンに同期
        if let engine = wgpuEngine, let rustID = layer.rustLayerID {
            let json = adjustmentsToJSON(adjustments)
            RustCore.wgpuSetLayerAdjustments(engine, layerId: rustID, adjustmentsJson: json)
        }

        isModified = true
        requestRender()
        adjustmentsUndoWorkItem?.cancel()
        let adjWork = DispatchWorkItem { [weak self] in
            self?.hasAdjustmentsUndoSnapshot = false
        }
        adjustmentsUndoWorkItem = adjWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: adjWork)
    }

    func setLayerFilter(_ id: UUID, preset: FilterPreset) {
        guard let layer = project.layers.first(where: { $0.id == id }) else { return }
        saveUndoSnapshot(description: "フィルター変更")
        layer.filterPreset = preset

        // フィルタープリセット適用後の調整値をRustに同期
        if let engine = wgpuEngine, let rustID = layer.rustLayerID {
            let adj = preset == .none
                ? layer.adjustments
                : preset.adjustments.merged(with: layer.adjustments)
            let json = adjustmentsToJSON(adj, filterType: preset.rawValue)
            RustCore.wgpuSetLayerAdjustments(engine, layerId: rustID, adjustmentsJson: json)
        }

        isModified = true
        requestRender()
    }

    func setLayerTransform(_ id: UUID, transform: LayerTransform) {
        guard let layer = project.layers.first(where: { $0.id == id }) else { return }
        if !hasTransformUndoSnapshot {
            saveUndoSnapshot(description: "変形変更")
            hasTransformUndoSnapshot = true
        }
        // Swift側は即座に更新（アウトラインが即座に追従）
        layer.transform = transform
        isModified = true
        // project は struct なのでレイヤー参照の transform だけでは @Published が飛ばないことがある
        objectWillChange.send()

        if isInteracting {
            // インタラクション中: WGPU は MTKView の draw で毎フレーム同期レンダー
            requestRender()
        } else {
            // 非インタラクション: 従来通り同期的にRustに反映
            if let engine = wgpuEngine, let rustID = layer.rustLayerID {
                let json = transformToJSON(transform)
                RustCore.wgpuSetLayerEditorTransform(engine, layerId: rustID, transformJson: json)
            }
            requestRender()

            transformUndoWorkItem?.cancel()
            let transformWork = DispatchWorkItem { [weak self] in
                self?.hasTransformUndoSnapshot = false
            }
            transformUndoWorkItem = transformWork
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: transformWork)
        }
    }

    func finalizeTransformInteraction() {
        // バックグラウンドレンダリングの残りを待たずに、最終状態を同期的にRustへ反映
        if let engine = wgpuEngine {
            for layer in project.layers {
                guard let rustID = layer.rustLayerID else { continue }
                let json = transformToJSON(layer.transform)
                RustCore.wgpuSetLayerEditorTransform(engine, layerId: rustID, transformJson: json)
            }
        }
        render()

        transformUndoWorkItem?.cancel()
        let transformWork = DispatchWorkItem { [weak self] in
            self?.hasTransformUndoSnapshot = false
        }
        transformUndoWorkItem = transformWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: transformWork)
    }
}
