import SwiftUI

// MARK: - エディタ用ブラシショートカット
// Why: Photoshop / Procreate と揃えた標準ショートカットを CommandMenu 配下に提供する。
// CommandMenu のボタンは responder chain を尊重するため、テキスト入力中は
// 自動的に無効化される（TextField が先に キー入力を消費するため）。
//
// - B: ブラシツール選択 (.pen)
// - E: 消しゴム選択 (.pen + paintMode = .subtract)
// - [ : 直径 −10%
// - ] : 直径 +10%
// - 1〜9: プリセット 1〜9 切替（インデックスベース）

struct EditorBrushCommands: Commands {

    var body: some Commands {
        CommandMenu("ブラシ") {
            Button("ブラシ") { selectBrush() }
                .keyboardShortcut("b", modifiers: [])

            Button("消しゴム") { selectEraser() }
                .keyboardShortcut("e", modifiers: [])

            Divider()

            Button("ブラシを縮小") { adjustDiameter(by: 0.9) }
                .keyboardShortcut("[", modifiers: [])

            Button("ブラシを拡大") { adjustDiameter(by: 1.1) }
                .keyboardShortcut("]", modifiers: [])

            Divider()

            // 1..9 でプリセット切替（保存順）
            ForEach(1...9, id: \.self) { index in
                Button("プリセット \(index)") { selectPreset(at: index - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: [])
            }
        }
    }

    // MARK: - 操作

    @MainActor
    private func selectBrush() {
        let manager = ImageEditorManager.shared
        manager.currentTool = .pen
        manager.mutateToolSettings { $0.stroke.paintMode = .normal }
    }

    @MainActor
    private func selectEraser() {
        let manager = ImageEditorManager.shared
        manager.currentTool = .pen
        manager.mutateToolSettings { $0.stroke.paintMode = .subtract }
    }

    @MainActor
    private func adjustDiameter(by factor: Double) {
        let manager = ImageEditorManager.shared
        manager.mutateToolSettings { settings in
            // 0.1...800 の範囲で 1px 未満を割り込まないようクランプする
            let raw = settings.stroke.diameterPixels * factor
            settings.stroke.diameterPixels = max(0.1, min(raw, 800))
        }
    }

    @MainActor
    private func selectPreset(at index: Int) {
        let library = BrushPresetLibrary.shared
        guard index >= 0, index < library.presets.count else { return }
        let preset = library.presets[index]
        ImageEditorManager.shared.mutateToolSettings { settings in
            preset.apply(to: &settings)
        }
        library.activePresetID = preset.id
    }
}
