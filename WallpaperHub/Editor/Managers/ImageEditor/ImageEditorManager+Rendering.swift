import Foundation
import AppKit
import AVFoundation
import Combine
import MetalKit
import UniformTypeIdentifiers

// MARK: - ImageEditorManager + Rendering
// Why: 同期/非同期レンダリング、アイドル更新、デバイスロスト復旧を集約。

extension ImageEditorManager {

    func renderLatestSync(bumpRenderVersion: Bool = false) {
        guard let engine = wgpuEngine else { return }
        for layer in project.layers {
            guard let rustID = layer.rustLayerID else { continue }
            let json = transformToJSON(layer.transform)
            RustCore.wgpuSetLayerEditorTransform(engine, layerId: rustID, transformJson: json)
        }
        let rate = Float(max(0.05, min(8.0, project.scene.playbackRate)))
        let dt: Float = (1.0 / 120.0) * rate
        let success = RustCore.wgpuRenderFrame(engine, deltaTime: dt)
        updateIOSurfaceTexture(engine: engine)
        if bumpRenderVersion {
            renderVersion &+= 1
        }
        if success {
            consecutiveRenderFailures = 0
        } else {
            consecutiveRenderFailures += 1
            if consecutiveRenderFailures >= maxConsecutiveFailuresBeforeRebuild {
                recoverFromDeviceLost()
            }
        }
    }

    func notifyLiveEditDisplayChanged() {
        objectWillChange.send()
    }

    func requestRender() {
        if isModified {
            scheduleAutosave()
        }
        if isInteracting {
            // インタラクション中は MTKView（isPaused=false）の draw が renderLatestSync で毎フレーム追従する
            return
        }
        renderDebounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.render()
        }
        renderDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + renderDebounceInterval, execute: workItem)
    }

    func render() {
        if let engine = wgpuEngine {
            let rate = Float(max(0.05, min(8.0, project.scene.playbackRate)))
            let dt = Float(renderDebounceInterval) * rate
            let success = RustCore.wgpuRenderFrame(engine, deltaTime: dt)

            updateIOSurfaceTexture(engine: engine)
            renderVersion &+= 1

            if success {
                consecutiveRenderFailures = 0
            } else {
                consecutiveRenderFailures += 1
                if consecutiveRenderFailures >= maxConsecutiveFailuresBeforeRebuild {
                    debugLog("[ImageEditorManager] レンダリング連続失敗 → エンジン再構築")
                    recoverFromDeviceLost()
                }
            }
        }

        renderer?.composeLayers(project.layers, canvasSize: project.canvasSize)
    }

    func scheduleAsyncRender() {
        asyncRenderNeeded = true
        guard !asyncRenderInFlight else { return }
        fireAsyncRender()
    }

    func fireAsyncRender() {
        guard let engine = wgpuEngine else { return }
        asyncRenderInFlight = true
        asyncRenderNeeded = false

        // メインスレッドで現在のtransformをキャプチャ（Mutexブロックなし）
        let layerSnapshots: [(rustID: String, json: String)] = project.layers.compactMap { layer in
            guard let rustID = layer.rustLayerID else { return nil }
            return (rustID, transformToJSON(layer.transform))
        }

        renderQueue.async { [weak self] in
            guard let self = self else { return }

            // バックグラウンドでRust同期 + GPU描画（Mutexはこのスレッドでのみ保持）
            for snapshot in layerSnapshots {
                RustCore.wgpuSetLayerEditorTransform(engine, layerId: snapshot.rustID, transformJson: snapshot.json)
            }
            let rate = Float(max(0.05, min(8.0, self.project.scene.playbackRate)))
            let dt: Float = (1.0 / 60.0) * rate
            let success = RustCore.wgpuRenderFrame(engine, deltaTime: dt)

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.asyncRenderInFlight = false

                // インタラクションに入った後に遅れて届いたフレームは捨てる（画像と枠のずれ防止）
                if self.isInteracting {
                    return
                }

                self.updateIOSurfaceTexture(engine: engine)
                self.renderVersion &+= 1

                if success {
                    self.consecutiveRenderFailures = 0
                } else {
                    self.consecutiveRenderFailures += 1
                    if self.consecutiveRenderFailures >= self.maxConsecutiveFailuresBeforeRebuild {
                        debugLog("[ImageEditorManager] レンダリング連続失敗 → エンジン再構築")
                        self.recoverFromDeviceLost()
                    }
                }

                if self.asyncRenderNeeded {
                    self.fireAsyncRender()
                }
            }
        }
    }

    func setEditorCanvasVisible(_ visible: Bool) {
        guard isEditorCanvasVisible != visible else { return }
        isEditorCanvasVisible = visible
        if visible {
            startIdleRefreshTimer()
        } else {
            stopIdleRefreshTimer()
        }
    }

    func startIdleRefreshTimer() {
        stopIdleRefreshTimer()
        idleRefreshTimer = Timer.scheduledTimer(withTimeInterval: idleRefreshInterval, repeats: true) { [weak self] _ in
            guard let self = self, self.isEditorCanvasVisible, !self.isInteracting else { return }
            // 放置時の画像固まり対策: IOSurface再バインドを強制してからレンダー
            self.lastIOSurfacePtr = nil
            self.render()
        }
        idleRefreshTimer?.tolerance = 0.2
        if let timer = idleRefreshTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stopIdleRefreshTimer() {
        idleRefreshTimer?.invalidate()
        idleRefreshTimer = nil
    }

    func forceRefreshAfterWake() {
        lastIOSurfacePtr = nil
        lastViewportPixelWidth = 0
        lastViewportPixelHeight = 0
        requestRender()
    }

    func recoverFromDeviceLost() {
        guard !isRebuilding else { return }
        isRebuilding = true
        consecutiveRenderFailures = 0

        debugLog("[ImageEditorManager] GPUデバイスロスト検出 → エンジン再構築開始")

        reloadAllTextures()
        lastIOSurfacePtr = nil
        lastViewportPixelWidth = 0
        lastViewportPixelHeight = 0

        if let engine = wgpuEngine {
            updateIOSurfaceTexture(engine: engine)
        }

        isRebuilding = false
        debugLog("[ImageEditorManager] エンジン再構築完了")

        requestRender()
    }
}
