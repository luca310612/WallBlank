import SwiftUI

/// 右パネル：プロパティ・調整・エフェクト
struct PropertyPanelView: View {
    @ObservedObject var editorManager: ImageEditorManager
    /// 右インスペクター列に埋め込む場合 true（幅いっぱい・Photoshop 風ドック）
    var stretchHorizontally: Bool = false
    /// ダークなパネル色（エディタークロムと揃える）
    var panelBackground: Color = Color(NSColor.controlBackgroundColor)
    /// インスペクター列の実幅（リサイズに応じてレイアウトを切り替え）
    var layoutWidth: CGFloat = 300

    private var inspectorNarrow: Bool { layoutWidth < 286 }
    private var inspectorCompact: Bool { layoutWidth < 236 }
    /// セクションカード背景（ダークドック用の薄い浮き上がり）
    private var sectionCardFill: Color {
        stretchHorizontally ? Color.white.opacity(0.07) : Color(NSColor.windowBackgroundColor)
    }

    var body: some View {
        Group {
            if stretchHorizontally {
                panelContent
                    .frame(maxWidth: .infinity)
            } else {
                panelContent
                    .frame(width: 280)
            }
        }
        .background(panelBackground)
    }

    private var panelContent: some View {
        VStack(spacing: 0) {
            // ヘッダー
            propertyHeader

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    if editorManager.currentTool == .pen, editorManager.penToolKind.isFreeformBrushLike {
                        EditorBrushToolPropertySections(
                            editorManager: editorManager,
                            sectionCardFill: sectionCardFill,
                            inspectorCompact: inspectorCompact
                        )
                        if editorManager.selection.mask != nil {
                            PropertySectionView(title: "選択", icon: "selection.pin.in.out", cardBackground: sectionCardFill) {
                                VStack(spacing: 10) {
                                    Button(action: { editorManager.layerViaCopyFromSelection() }) {
                                        HStack {
                                            Image(systemName: "square.on.square")
                                            Text("選択をレイヤーに（コピー）")
                                            Spacer()
                                            Text("⌘J")
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(.secondary)
                                        }
                                        .font(.system(size: 11, weight: .medium))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 7)
                                    }
                                    .buttonStyle(.plain)
                                    .background(Color.accentColor.opacity(0.10))
                                    .cornerRadius(8)

                                    Button(action: { editorManager.layerViaCutFromSelection() }) {
                                        HStack {
                                            Image(systemName: "scissors")
                                            Text("選択をレイヤーに（切り取り）")
                                            Spacer()
                                            Text("⇧⌘J")
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(.secondary)
                                        }
                                        .font(.system(size: 11, weight: .medium))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 7)
                                    }
                                    .buttonStyle(.plain)
                                    .background(Color.white.opacity(0.06))
                                    .cornerRadius(8)

                                    Button(action: { editorManager.clearSelection() }) {
                                        HStack {
                                            Image(systemName: "xmark.circle")
                                            Text("選択を解除")
                                            Spacer()
                                            Text("⌘D")
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(.secondary)
                                        }
                                        .font(.system(size: 11))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundColor(.secondary)
                                }
                            }
                        }
                        if editorManager.selectedLayer != nil {
                            Divider()
                        }
                    }

                    if let layer = editorManager.selectedLayer {
                        blendSection(layer: layer)

                        Divider()

                        transformSection(layer: layer)

                        Divider()

                        adjustmentSection(layer: layer)

                        Divider()

                        filterSection(layer: layer)
                    } else if !(editorManager.currentTool == .pen && editorManager.penToolKind.isFreeformBrushLike) {
                        noSelectionView
                    } else {
                        Text("レイヤーを選択するとブレンド・変形・調整が表示されます")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                }
                .padding(12)
            }
        }
    }

    // MARK: - ヘッダー

    private var propertyHeader: some View {
        HStack {
            Label("プロパティ", systemImage: "slider.horizontal.3")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, stretchHorizontally ? 6 : 8)
    }

    // MARK: - 選択なし

    private var noSelectionView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "cursorarrow.click.2")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("レイヤーを選択してください")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    // MARK: - ブレンド・不透明度

    private func blendSection(layer: EditorLayer) -> some View {
        PropertySectionView(title: "ブレンド", icon: "square.on.square", cardBackground: sectionCardFill) {
            VStack(spacing: 12) {
                // ブレンドモード
                if inspectorNarrow {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("モード")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Picker("", selection: Binding(
                            get: { layer.blendMode },
                            set: { editorManager.setLayerBlendMode(layer.id, blendMode: $0) }
                        )) {
                            ForEach(EditorBlendMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    HStack {
                        Text("モード")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { layer.blendMode },
                            set: { editorManager.setLayerBlendMode(layer.id, blendMode: $0) }
                        )) {
                            ForEach(EditorBlendMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .frame(maxWidth: min(148, layoutWidth * 0.48))
                    }
                }

                // 不透明度
                EditorSlider(
                    label: "不透明度",
                    value: Binding(
                        get: { layer.opacity },
                        set: { editorManager.setLayerOpacity(layer.id, opacity: $0) }
                    ),
                    range: 0.1...1,
                    showPercent: true,
                    stackValueUnderLabel: inspectorCompact
                )
            }
        }
    }

    // MARK: - 変形

    private func transformSection(layer: EditorLayer) -> some View {
        PropertySectionView(title: "変形", icon: "arrow.up.left.and.arrow.down.right", cardBackground: sectionCardFill) {
            VStack(spacing: 12) {
                // 位置
                Group {
                    if inspectorNarrow {
                        VStack(spacing: 8) {
                            EditorNumberField(
                                label: "X",
                                value: Binding(
                                    get: { layer.transform.offsetX },
                                    set: {
                                        var t = layer.transform
                                        t.offsetX = $0
                                        editorManager.setLayerTransform(layer.id, transform: t)
                                    }
                                )
                            )
                            EditorNumberField(
                                label: "Y",
                                value: Binding(
                                    get: { layer.transform.offsetY },
                                    set: {
                                        var t = layer.transform
                                        t.offsetY = $0
                                        editorManager.setLayerTransform(layer.id, transform: t)
                                    }
                                )
                            )
                        }
                    } else {
                        HStack(spacing: 8) {
                            EditorNumberField(
                                label: "X",
                                value: Binding(
                                    get: { layer.transform.offsetX },
                                    set: {
                                        var t = layer.transform
                                        t.offsetX = $0
                                        editorManager.setLayerTransform(layer.id, transform: t)
                                    }
                                )
                            )
                            EditorNumberField(
                                label: "Y",
                                value: Binding(
                                    get: { layer.transform.offsetY },
                                    set: {
                                        var t = layer.transform
                                        t.offsetY = $0
                                        editorManager.setLayerTransform(layer.id, transform: t)
                                    }
                                )
                            )
                        }
                    }
                }

                // スケール
                Group {
                    if inspectorNarrow {
                        VStack(spacing: 8) {
                            EditorNumberField(
                                label: "幅",
                                value: Binding(
                                    get: { layer.transform.scaleX },
                                    set: {
                                        var t = layer.transform
                                        t.scaleX = $0
                                        editorManager.setLayerTransform(layer.id, transform: t)
                                    }
                                ),
                                step: 0.1
                            )
                            EditorNumberField(
                                label: "高さ",
                                value: Binding(
                                    get: { layer.transform.scaleY },
                                    set: {
                                        var t = layer.transform
                                        t.scaleY = $0
                                        editorManager.setLayerTransform(layer.id, transform: t)
                                    }
                                ),
                                step: 0.1
                            )
                        }
                    } else {
                        HStack(spacing: 8) {
                            EditorNumberField(
                                label: "幅",
                                value: Binding(
                                    get: { layer.transform.scaleX },
                                    set: {
                                        var t = layer.transform
                                        t.scaleX = $0
                                        editorManager.setLayerTransform(layer.id, transform: t)
                                    }
                                ),
                                step: 0.1
                            )
                            EditorNumberField(
                                label: "高さ",
                                value: Binding(
                                    get: { layer.transform.scaleY },
                                    set: {
                                        var t = layer.transform
                                        t.scaleY = $0
                                        editorManager.setLayerTransform(layer.id, transform: t)
                                    }
                                ),
                                step: 0.1
                            )
                        }
                    }
                }

                // 回転
                EditorSlider(
                    label: "回転",
                    value: Binding(
                        get: { layer.transform.rotationDegrees },
                        set: {
                            var t = layer.transform
                            t.rotationDegrees = $0
                            editorManager.setLayerTransform(layer.id, transform: t)
                        }
                    ),
                    range: -180...180,
                    suffix: "°",
                    stackValueUnderLabel: inspectorCompact
                )

                // 反転ボタン
                let flipSpacing: CGFloat = inspectorNarrow ? 8 : 12
                Group {
                    if inspectorNarrow {
                        VStack(spacing: flipSpacing) {
                            transformFlipButton(
                                layer: layer,
                                horizontal: true,
                                icon: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                                title: "水平反転"
                            )
                            transformFlipButton(
                                layer: layer,
                                horizontal: false,
                                icon: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                                title: "垂直反転"
                            )
                        }
                    } else {
                        HStack(spacing: flipSpacing) {
                            transformFlipButton(
                                layer: layer,
                                horizontal: true,
                                icon: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                                title: "水平反転"
                            )
                            transformFlipButton(
                                layer: layer,
                                horizontal: false,
                                icon: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                                title: "垂直反転"
                            )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func transformFlipButton(layer: EditorLayer, horizontal: Bool, icon: String, title: String) -> some View {
        let isOn = horizontal ? layer.transform.flipHorizontal : layer.transform.flipVertical
        Button(action: {
            var t = layer.transform
            if horizontal { t.flipHorizontal.toggle() } else { t.flipVertical.toggle() }
            editorManager.setLayerTransform(layer.id, transform: t)
        }) {
            HStack(spacing: inspectorCompact ? 4 : 6) {
                Image(systemName: icon)
                    .font(.system(size: inspectorCompact ? 10 : 11))
                Text(title)
                    .font(.system(size: inspectorCompact ? 10 : 11))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, inspectorCompact ? 5 : 6)
            .background(isOn ? Color.accentColor.opacity(0.15) : Color.clear)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 画像調整

    private func adjustmentSection(layer: EditorLayer) -> some View {
        PropertySectionView(title: "画像調整", icon: "slider.horizontal.below.rectangle", cardBackground: sectionCardFill) {
            VStack(spacing: 10) {
                ForEach(AdjustmentParameter.allCases, id: \.self) { param in
                    EditorSlider(
                        label: param.displayName,
                        value: Binding(
                            get: { layer.adjustments[keyPath: param.keyPath] },
                            set: {
                                var adj = layer.adjustments
                                adj[keyPath: param.keyPath] = $0
                                editorManager.setLayerAdjustments(layer.id, adjustments: adj)
                            }
                        ),
                        range: param.range,
                        defaultValue: param.defaultValue,
                        stackValueUnderLabel: inspectorCompact
                    )
                }

                // リセットボタン
                if !layer.adjustments.isDefault {
                    Button(action: {
                        editorManager.setLayerAdjustments(layer.id, adjustments: .default)
                    }) {
                        Text("調整をリセット")
                            .font(.system(size: 11))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - フィルタープリセット

    private func filterSection(layer: EditorLayer) -> some View {
        let inner = max(40, layoutWidth - 44)
        let columnCount = max(2, min(6, Int(inner / (inspectorCompact ? 58.0 : 68.0))))
        let columns = Array(repeating: GridItem(.flexible(minimum: 52), spacing: 6), count: columnCount)

        return PropertySectionView(title: "フィルター", icon: "camera.filters", cardBackground: sectionCardFill) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(FilterPreset.allCases, id: \.self) { preset in
                    FilterPresetButton(
                        preset: preset,
                        isSelected: layer.filterPreset == preset,
                        compact: inspectorCompact || inspectorNarrow,
                        action: {
                            editorManager.setLayerFilter(layer.id, preset: preset)
                        }
                    )
                }
            }
        }
    }
}

// MARK: - プロパティセクションビュー

struct PropertySectionView<Content: View>: View {
    let title: String
    let icon: String
    var cardBackground: Color = Color(NSColor.windowBackgroundColor)
    @ViewBuilder let content: () -> Content

    @State private var isExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // セクションヘッダー（折りたたみ可能）
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundColor(.accentColor)
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(cardBackground)
        .cornerRadius(8)
    }
}

// MARK: - エディタースライダー

struct EditorSlider: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var defaultValue: Float?
    var showPercent: Bool = false
    var suffix: String = ""
    /// 狭いパネルではラベル行と数値を縦に分け、スライダーを確保する
    var stackValueUnderLabel: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: stackValueUnderLabel ? 6 : 3) {
            if stackValueUnderLabel {
                HStack(alignment: .firstTextBaseline) {
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer(minLength: 8)
                    if let def = defaultValue, abs(value - def) > 0.01 {
                        Button(action: { value = def }) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    if showPercent {
                        Text("\(Int(value * 100))%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    } else {
                        Text(String(format: "%.1f%@", value, suffix))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                Slider(value: $value, in: range)
                    .controlSize(.small)
            } else {
                HStack {
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()

                    if showPercent {
                        Text("\(Int(value * 100))%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 35, alignment: .trailing)
                    } else {
                        Text(String(format: "%.1f%@", value, suffix))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 45, alignment: .trailing)
                    }

                    if let def = defaultValue, abs(value - def) > 0.01 {
                        Button(action: { value = def }) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Slider(value: $value, in: range)
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - 数値入力フィールド

struct EditorNumberField: View {
    let label: String
    @Binding var value: Float
    var step: Float = 1.0

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(width: 16)

            TextField("", value: $value, format: .number.precision(.fractionLength(1)))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - フィルタープリセットボタン

struct FilterPresetButton: View {
    let preset: FilterPreset
    let isSelected: Bool
    var compact: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: compact ? 2 : 4) {
                Image(systemName: preset.icon)
                    .font(.system(size: compact ? 14 : 16))
                    .frame(height: compact ? 16 : 20)
                Text(preset.displayName)
                    .font(.system(size: compact ? 8 : 9))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, compact ? 6 : 8)
            .padding(.horizontal, 2)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? Color.accentColor : Color.gray.opacity(0.3),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
