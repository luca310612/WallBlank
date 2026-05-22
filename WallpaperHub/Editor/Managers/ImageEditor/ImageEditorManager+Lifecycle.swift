import Foundation
import AppKit
import AVFoundation
import Combine
import MetalKit
import UniformTypeIdentifiers

// MARK: - ImageEditorManager + Lifecycle
// Why: スリープ/復帰観測とオートセーブキャッシュ管理を集約。

extension ImageEditorManager {

    func setupWakeObserver() {
        let center = NSWorkspace.shared.notificationCenter
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.handleSystemWake()
        }
        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.autosaveDebounceWorkItem?.cancel()
            self?.saveToAutosaveCache()
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.autosaveDebounceWorkItem?.cancel()
            self?.saveToAutosaveCache()
        }
    }

    func handleSystemWake() {
        lastWakeTrigger = Date()
        forceRefreshAfterWake()
        debugLog("[ImageEditorManager] スリープ復帰検知 → \(wakeRestoreDelay)秒後に状態保存・リセット予約")

        // 復帰直後はGPU/表示が不安定なため、少し待ってから「現在の状態を保存 → エンジン・テクスチャをリセット」
        DispatchQueue.main.asyncAfter(deadline: .now() + wakeRestoreDelay) { [weak self] in
            guard let self = self else { return }
            // 1. 画像レイヤー・テクスチャの設定状態をキャッシュに保存
            self.forceSaveCurrentStateToAutosaveCache()
            // 2. WGPUエンジンとテクスチャを再構築してリセット（表示の不具合を解消）
            if !self.project.layers.isEmpty {
                self.reloadAllTextures()
            }
            self.forceRefreshAfterWake()
            debugLog("[ImageEditorManager] 復帰後の状態保存・リセット完了（レイヤー数: \(self.project.layers.count)）")
        }
    }

    func scheduleAutosave() {
        guard isModified else { return }
        autosaveDebounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.saveToAutosaveCache()
        }
        autosaveDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + autosaveDebounceInterval, execute: workItem)
    }

    func saveToAutosaveCache() {
        guard isModified else { return }
        writeProjectToAutosaveCache(project)
    }

    func forceSaveCurrentStateToAutosaveCache() {
        writeProjectToAutosaveCache(project)
    }

    func writeProjectToAutosaveCache(_ projectToSave: EditorProject) {
        do {
            let data = try JSONEncoder().encode(projectToSave)
            if data.count > autosaveMaxDataSize {
                debugLog("[ImageEditorManager] オートセーブスキップ: サイズ超過 (\(data.count / 1024 / 1024)MB > \(autosaveMaxDataSize / 1024 / 1024)MB)")
                clearAutosaveCache()
                return
            }
            try data.write(to: autosaveCacheURL)
            debugLog("[ImageEditorManager] オートセーブキャッシュ保存完了")
        } catch {
            debugLog("[ImageEditorManager] オートセーブキャッシュ保存失敗: \(error.localizedDescription)")
        }
    }

    func tryRestoreFromAutosave() {
        guard FileManager.default.fileExists(atPath: autosaveCacheURL.path) else { return }
        do {
            let data = try Data(contentsOf: autosaveCacheURL)
            let restored = try JSONDecoder().decode(EditorProject.self, from: data)
            project = restored
            selectedLayerID = restored.selectedLayerID
            isModified = true
            debugLog("[ImageEditorManager] オートセーブキャッシュから復元しました（レイヤー数: \(restored.layers.count)）")
        } catch {
            debugLog("[ImageEditorManager] オートセーブ復元失敗: \(error.localizedDescription)")
        }
    }

    func clearAutosaveCache() {
        try? FileManager.default.removeItem(at: autosaveCacheURL)
    }

    func cleanupStaleEditorCacheIfNeeded() {
        let dir = autosaveCacheURL.deletingLastPathComponent()
        let currentName = autosaveCacheURL.lastPathComponent
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-Double(cacheStaleDays * 24 * 60 * 60))
        for url in contents where url.lastPathComponent != currentName {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let mod = attrs[.modificationDate] as? Date, mod < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
            debugLog("[ImageEditorManager] 古いキャッシュ削除: \(url.lastPathComponent)")
        }
    }
}
