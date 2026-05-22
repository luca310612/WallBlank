import SwiftUI

/// レイヤーリスト（単独左パネル、または右インスペクター列の下段）
struct LayerPanelView: View {
    @ObservedObject var editorManager: ImageEditorManager
    /// 右インスペクター列に埋め込む場合 true
    var stretchHorizontally: Bool = false
    var panelBackground: Color = Color(NSColor.controlBackgroundColor)

    var body: some View {
        Group {
            if stretchHorizontally {
                panelContent
                    .frame(maxWidth: .infinity)
            } else {
                panelContent
                    .frame(width: 220)
            }
        }
        .background(panelBackground)
    }

    private var panelContent: some View {
        VStack(spacing: 0) {
            // ヘッダー
            layerHeader

            Divider()

            // レイヤーリスト
            if editorManager.project.layers.isEmpty {
                emptyState
            } else {
                layerList
            }

            Divider()

            // フッター（追加ボタン）
            layerFooter
        }
    }

    // MARK: - ヘッダー

    private var layerHeader: some View {
        HStack {
            Label("レイヤー", systemImage: "square.3.layers.3d")
                .font(.system(size: 12, weight: .semibold))

            Spacer()

            Text("\(editorManager.project.layers.count)")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor)
                .cornerRadius(8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, stretchHorizontally ? 6 : 8)
    }

    // MARK: - 空の状態

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("画像・動画をドラッグ＆ドロップ\nまたは＋ボタンで追加")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - レイヤーリスト

    private var layerList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                // レイヤーを上から表示（描画順は逆）
                ForEach(editorManager.project.layers.reversed()) { layer in
                    LayerRowView(
                        layer: layer,
                        isSelected: editorManager.selectedLayerID == layer.id,
                        onSelect: {
                            editorManager.selectLayer(layer.id)
                        },
                        onToggleVisibility: {
                            editorManager.toggleLayerVisibility(layer.id)
                        },
                        onToggleLock: {
                            editorManager.toggleLayerLock(layer.id)
                        }
                    )
                    .contextMenu {
                        layerContextMenu(for: layer)
                    }
                }
                .onMove { source, destination in
                    let reversedCount = editorManager.project.layers.count
                    // reversed()のインデックスを元に戻す
                    let sourceIndices = source.map { reversedCount - 1 - $0 }
                    let destIndex = reversedCount - 1 - destination
                    if let from = sourceIndices.first {
                        editorManager.moveLayer(from: from, to: max(0, destIndex))
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - コンテキストメニュー

    @ViewBuilder
    private func layerContextMenu(for layer: EditorLayer) -> some View {
        Button(action: { editorManager.duplicateLayer(layer.id) }) {
            Label("複製", systemImage: "doc.on.doc")
        }

        Divider()

        Button(action: { editorManager.layerViaCopyFromSelection() }) {
            Label("選択範囲をレイヤーに（コピー）", systemImage: "square.on.square")
        }
        .disabled(editorManager.selection.mask == nil || editorManager.selectedLayerID != layer.id)

        Button(action: { editorManager.layerViaCutFromSelection() }) {
            Label("選択範囲をレイヤーに（切り取り）", systemImage: "scissors")
        }
        .disabled(editorManager.selection.mask == nil || editorManager.selectedLayerID != layer.id)

        Button(action: { editorManager.clearSelection() }) {
            Label("選択解除", systemImage: "xmark.circle")
        }
        .disabled(editorManager.selection.mask == nil)

        Divider()

        Button(action: { editorManager.mergeDown(layer.id) }) {
            Label("下と結合", systemImage: "arrow.down.to.line")
        }

        Divider()

        Button(action: { editorManager.toggleLayerVisibility(layer.id) }) {
            Label(layer.isVisible ? "非表示" : "表示", systemImage: layer.isVisible ? "eye.slash" : "eye")
        }

        Button(action: { editorManager.toggleLayerLock(layer.id) }) {
            Label(layer.isLocked ? "ロック解除" : "ロック", systemImage: layer.isLocked ? "lock.open" : "lock")
        }

        Divider()

        Button(role: .destructive, action: { editorManager.removeLayer(layer.id) }) {
            Label("削除", systemImage: "trash")
        }
    }

    // MARK: - フッター

    private var layerFooter: some View {
        HStack(spacing: 8) {
            Button(action: { editorManager.showAddLayerDialog() }) {
                Image(systemName: "plus")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .help("画像・動画を追加")

            Spacer()

            if let selectedID = editorManager.selectedLayerID {
                Button(action: { editorManager.duplicateLayer(selectedID) }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("レイヤーを複製")

                Button(action: { editorManager.removeLayer(selectedID) }) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(.red)
                .help("レイヤーを削除")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - レイヤー行ビュー

struct LayerRowView: View {
    @ObservedObject var layer: EditorLayer
    let isSelected: Bool
    let onSelect: () -> Void
    let onToggleVisibility: () -> Void
    let onToggleLock: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // 表示/非表示ボタン
            Button(action: onToggleVisibility) {
                Image(systemName: layer.isVisible ? "eye.fill" : "eye.slash")
                    .font(.system(size: 10))
                    .foregroundColor(layer.isVisible ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 16)

            // サムネイル
            layerThumbnail
                .frame(width: 36, height: 24)
                .cornerRadius(4)

            // レイヤー名
            VStack(alignment: .leading, spacing: 2) {
                Text(layer.name)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    // 動画マーカー
                    if layer.isVideoLayer {
                        Image(systemName: "film")
                            .font(.system(size: 8))
                            .foregroundColor(.green)
                    }
                    // ブレンドモード表示
                    if layer.blendMode != .normal {
                        Text(layer.blendMode.displayName)
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                    // 不透明度表示
                    if layer.opacity < 1.0 {
                        Text("\(Int(layer.opacity * 100))%")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // ロックアイコン
            if layer.isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }

    @ViewBuilder
    private var layerThumbnail: some View {
        if layer.isVideoLayer {
            // 動画レイヤーのサムネイル
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.green.opacity(0.3), .blue.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Image(systemName: "video.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                )
        } else if layer.texture != nil {
            // 画像レイヤーのサムネイル
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.blue.opacity(0.3), .purple.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Image(systemName: "photo")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                )
        } else {
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .overlay(
                    Image(systemName: "photo")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                )
        }
    }
}
