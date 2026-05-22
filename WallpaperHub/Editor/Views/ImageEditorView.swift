import SwiftUI

// MARK: - Photoshop 風エディタークロム（暗め・情報密度寄り）

/// 右プロパティ列（インスペクター）のレイアウト既定値
private enum EditorInspectorLayout {
    /// 従来デフォルト 304pt の 1/3
    static let defaultColumnWidth: Double = 304.0 / 3.0
    static let minColumnWidth: CGFloat = 100
    static let maxColumnWidth: CGFloat = 900
}

private enum EditorChrome {
    static let canvasSurround = Color(red: 0.18, green: 0.18, blue: 0.18)
    static let menuBar = Color(red: 0.14, green: 0.14, blue: 0.14)
    static let optionsBar = Color(red: 0.12, green: 0.12, blue: 0.12)
    static let toolStrip = Color(red: 0.11, green: 0.11, blue: 0.11)
    static let panel = Color(red: 0.16, green: 0.16, blue: 0.16)
    static let hairline = Color.black.opacity(0.55)
}

/// メインエディタービュー（Photoshop 風：上段メニュー + オプションバー + 左ツール列 + キャンバス + 右インスペクター + 下タイムライン）
struct ImageEditorView: View {
    @StateObject private var editorManager = ImageEditorManager.shared
    @StateObject private var animationManager = AnimationManager()
    @ObservedObject private var steamManager = SteamManager.shared
    @State private var showWorkshopSubscribeList = false
    @State private var showMaskEditor = false
    @State private var maskEditorImage: NSImage?
    @StateObject private var maskEditorViewModel = MaskEditorViewModel(effectManager: .shared)
    @State private var showEditorWelcome = false
    /// 右インスペクター列の幅（ドラッグで変更、次回起動時の目安にも使用）
    /// v2: 既定幅を 304 の 1/3 に変更したためキーを分離（初回〜は新既定が効く）
    @AppStorage("artia.editor.inspectorColumnWidth.v2") private var storedInspectorColumnWidth: Double = EditorInspectorLayout.defaultColumnWidth

    var body: some View {
        VStack(spacing: 0) {
            if showEditorWelcome {
                EditorWelcomeView(
                    editorManager: editorManager,
                    onDismissWelcome: { showEditorWelcome = false }
                )
                .transition(.opacity)
            } else {
                mainEditorChrome
            }
        }
        .background(EditorChrome.canvasSurround)
        .onAppear {
            setupAnimationManager()
            setupWindowCloseInterceptor()
            if UserDefaults.standard.bool(forKey: Self.presentWelcomeHubDefaultsKey) {
                UserDefaults.standard.set(false, forKey: Self.presentWelcomeHubDefaultsKey)
                showEditorWelcome = true
            }
        }
    }

    private static let presentWelcomeHubDefaultsKey = "artia.editor.presentWelcomeHub"

    /// メインハブの「壁紙を作成」から開いたときにウェルカムを出す
    static func requestWelcomeHubOnNextEditorOpen() {
        UserDefaults.standard.set(true, forKey: presentWelcomeHubDefaultsKey)
    }

    @ViewBuilder
    private var mainEditorChrome: some View {
        VStack(spacing: 0) {
            editorMenuBar
                .zIndex(1)

            Rectangle()
                .fill(EditorChrome.hairline)
                .frame(height: 1)
                .zIndex(1)

            editorToolOptionsBar
                .zIndex(1)

            Rectangle()
                .fill(EditorChrome.hairline)
                .frame(height: 1)
                .zIndex(1)

            HStack(spacing: 0) {
                verticalToolStrip
                    .zIndex(2)

                Rectangle()
                    .fill(EditorChrome.hairline)
                    .frame(width: 1)
                    .zIndex(2)

                if showMaskEditor, let image = maskEditorImage {
                    MaskEditorView(
                        viewModel: maskEditorViewModel,
                        backgroundImage: image,
                        imageSize: image.size
                    )
                    .transition(.opacity)
                    .zIndex(0)
                } else {
                    HSplitView {
                        EditorCanvasView(editorManager: editorManager)
                            .frame(minWidth: 320, minHeight: 200)
                            .clipped()
                            .background(EditorChrome.canvasSurround)

                        resizableInspectorColumn
                    }
                    .zIndex(0)
                }
            }

            if !showMaskEditor {
                TimelineView(
                    animationManager: animationManager,
                    editorManager: editorManager
                )
                .zIndex(1)
            }
        }
    }

    // MARK: - 上段（ファイル・書き出し）

    private var editorMenuBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Button(action: {
                    guard editorManager.confirmSaveBeforeClose() else { return }
                    editorManager.newProject()
                }) {
                    Label("新規", systemImage: "doc.badge.plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("新規プロジェクト")

                Button(action: { editorManager.showLoadDialog() }) {
                    Label("開く", systemImage: "folder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("プロジェクトを開く")

                Button(action: { showWorkshopSubscribeList = true }) {
                    Label("Workshopから開く", systemImage: "cloud")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .disabled(!steamManager.isAvailable)
                .help(steamManager.isAvailable ? "購読した Workshop の壁紙を開く" : steamManager.statusMessage)
                .sheet(isPresented: $showWorkshopSubscribeList) {
                    WorkshopSubscribeListView()
                }

                Button(action: { editorManager.showSaveDialog() }) {
                    Label("保存", systemImage: "square.and.arrow.down")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("プロジェクトを保存")
            }
            .foregroundStyle(Color(white: 0.82))

            thinSeparator

            HStack(spacing: 4) {
                Button(action: { editorManager.undo() }) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .disabled(!editorManager.canUndo)
                .help("元に戻す")

                Button(action: { editorManager.redo() }) {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .disabled(!editorManager.canRedo)
                .help("やり直す")
            }
            .foregroundStyle(Color(white: 0.82))

            Spacer()

            HStack(spacing: 6) {
                if editorManager.isModified {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 5, height: 5)
                }
                Text(editorManager.project.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(white: 0.58))
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button(action: exportImage) {
                        Label("エクスポート", systemImage: "square.and.arrow.up")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("画像をエクスポート")

                    Button(action: { editorManager.showExportForWorkshopDialog() }) {
                        Label("Workshop用にエクスポート", systemImage: "folder.badge.plus")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("配布用フォルダを出力")

                    Button(action: { editorManager.showUploadToWorkshopDialog() }) {
                        Label("Workshopに投稿", systemImage: "cloud.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .disabled(!steamManager.isAvailable)
                    .help(steamManager.isAvailable ? "Steam Workshop に投稿" : steamManager.statusMessage)
                }
                .foregroundStyle(Color(white: 0.82))

                Button(action: { editorManager.applyToWallpaperEngine() }) {
                    Label("壁紙に適用", systemImage: "desktopcomputer")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("合成結果を壁紙として適用")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(EditorChrome.menuBar)
    }

    private var thinSeparator: some View {
        Rectangle()
            .fill(EditorChrome.hairline)
            .frame(width: 1, height: 16)
    }

    // MARK: - オプションバー（ツール文脈 + よく使う操作）

    private var editorToolOptionsBar: some View {
        HStack(spacing: 10) {
            if showMaskEditor {
                Text("マスク編集モード — 終了するとキャンバスに反映されます")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.72))
            } else {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(optionsBarToolTitle)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(white: 0.88))
                            Text(optionsBarShortcut)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Color(white: 0.45))
                        }

                        if editorManager.currentTool == .pen {
                            Picker("", selection: $editorManager.penToolKind) {
                                Section("なぞり選択") {
                                    Label(PenToolKind.freeform.displayName, systemImage: PenToolKind.freeform.iconSystemName)
                                        .tag(PenToolKind.freeform)
                                    Label(PenToolKind.magneticPen.displayName, systemImage: PenToolKind.magneticPen.iconSystemName)
                                        .tag(PenToolKind.magneticPen)
                                }
                                Section("パスを描く") {
                                    Label(PenToolKind.standard.displayName, systemImage: PenToolKind.standard.iconSystemName)
                                        .tag(PenToolKind.standard)
                                    Label(PenToolKind.curvature.displayName, systemImage: PenToolKind.curvature.iconSystemName)
                                        .tag(PenToolKind.curvature)
                                    Label(PenToolKind.polygonal.displayName, systemImage: PenToolKind.polygonal.iconSystemName)
                                        .tag(PenToolKind.polygonal)
                                }
                                Section("パスを編集") {
                                    Label(PenToolKind.pathSelect.displayName, systemImage: PenToolKind.pathSelect.iconSystemName)
                                        .tag(PenToolKind.pathSelect)
                                    Label(PenToolKind.directSelect.displayName, systemImage: PenToolKind.directSelect.iconSystemName)
                                        .tag(PenToolKind.directSelect)
                                    Label(PenToolKind.addAnchor.displayName, systemImage: PenToolKind.addAnchor.iconSystemName)
                                        .tag(PenToolKind.addAnchor)
                                    Label(PenToolKind.deleteAnchor.displayName, systemImage: PenToolKind.deleteAnchor.iconSystemName)
                                        .tag(PenToolKind.deleteAnchor)
                                    Label(PenToolKind.convertPoint.displayName, systemImage: PenToolKind.convertPoint.iconSystemName)
                                        .tag(PenToolKind.convertPoint)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(minWidth: 140, alignment: .leading)
                            .labelsHidden()
                            .help("ペンの種類（Photoshop 風）")
                        }

                        if editorManager.currentTool == .pen, editorManager.penToolKind.isFreeformBrushLike {
                            ScrollView(.horizontal, showsIndicators: false) {
                                FreeformBrushOptionsBar(editorManager: editorManager)
                            }
                            .frame(maxHeight: 56)
                        }

                        if editorManager.currentTool == .flowBrush {
                            ScrollView(.horizontal, showsIndicators: false) {
                                FlowBrushOptionsBar(
                                    editorManager: editorManager,
                                    flowBrush: FlowBrushManager.shared
                                )
                            }
                            .frame(maxHeight: 56)
                        }
                    }

                    Spacer(minLength: 8)
                }
            }

            Spacer()

            Button(action: { editorManager.showAddLayerDialog() }) {
                Label("メディアを追加", systemImage: "plus.rectangle.on.rectangle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(white: 0.78))
            .help("画像・動画レイヤーを追加")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(minHeight: ((editorManager.currentTool == .pen && editorManager.penToolKind.isFreeformBrushLike) || editorManager.currentTool == .flowBrush) ? 78 : 28)
        .background(EditorChrome.optionsBar)
    }

    private var optionsBarToolTitle: String {
        switch editorManager.currentTool {
        case .move: return "移動ツール"
        case .pen: return "ペンツール — \(editorManager.penToolKind.displayName)"
        case .hand: return "ハンドツール"
        case .zoom: return "ズームツール"
        case .flowBrush: return "水流ブラシ"
        }
    }

    private var optionsBarShortcut: String {
        switch editorManager.currentTool {
        case .move: return "V"
        case .pen: return "P"
        case .hand: return "H"
        case .zoom: return "Z"
        case .flowBrush: return "F"
        }
    }

    // MARK: - 左ツールストリップ

    private var verticalToolStrip: some View {
        VStack(spacing: 0) {
            toolStripIconButton(tool: .move, shortcut: "V")
            toolStripIconButton(tool: .pen, shortcut: "P")
            toolStripIconButton(tool: .flowBrush, shortcut: "F")

            Rectangle()
                .fill(EditorChrome.hairline)
                .frame(height: 1)
                .padding(.vertical, 6)

            maskToolStripButton()

            Spacer(minLength: 0)
        }
        .frame(width: 50)
        .background(EditorChrome.toolStrip)
    }

    private func toolStripIconButton(tool: EditorTool, shortcut: String) -> some View {
        let selected = editorManager.currentTool == tool && !showMaskEditor
        return Button {
            showMaskEditor = false
            editorManager.currentTool = tool
        } label: {
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(selected ? Color.white.opacity(0.07) : Color.clear)
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(selected ? Color.accentColor : Color.clear)
                        .frame(width: 3)
                    Image(systemName: tool.icon)
                        .font(.system(size: 17))
                        .foregroundColor(selected ? .white : Color(white: 0.58))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(tool.displayName) (\(shortcut))")
    }

    private func maskToolStripButton() -> some View {
        let selected = showMaskEditor
        return Button {
            if showMaskEditor {
                showMaskEditor = false
                editorManager.syncEffectMaskToWgpuEngine()
            } else {
                editorManager.clearSelection()
                maskEditorImage = editorManager.exportAsImage()
                if maskEditorImage != nil {
                    showMaskEditor = true
                }
            }
        } label: {
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(selected ? Color.white.opacity(0.07) : Color.clear)
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(selected ? Color.accentColor : Color.clear)
                        .frame(width: 3)
                    Image(systemName: "paintbrush.pointed")
                        .font(.system(size: 17))
                        .foregroundColor(selected ? .white : Color(white: 0.58))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("マスク編集（ブラシ・消しゴム）")
    }

    // MARK: - 右インスペクター（ドラッグで幅変更・プロパティ上／レイヤー下）

    private var resizableInspectorColumn: some View {
        GeometryReader { geo in
            VSplitView {
                PropertyPanelView(
                    editorManager: editorManager,
                    stretchHorizontally: true,
                    panelBackground: EditorChrome.panel,
                    layoutWidth: geo.size.width
                )
                .frame(minHeight: 200)

                LayerPanelView(
                    editorManager: editorManager,
                    stretchHorizontally: true,
                    panelBackground: EditorChrome.panel
                )
                .frame(minHeight: 120)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .task(id: geo.size.width) {
                let w = geo.size.width
                guard w > 10 else { return }
                let clamped = min(EditorInspectorLayout.maxColumnWidth, max(EditorInspectorLayout.minColumnWidth, w))
                if abs(storedInspectorColumnWidth - Double(clamped)) > 1.5 {
                    storedInspectorColumnWidth = Double(clamped)
                }
            }
        }
        .frame(
            minWidth: EditorInspectorLayout.minColumnWidth,
            idealWidth: CGFloat(storedInspectorColumnWidth),
            maxWidth: EditorInspectorLayout.maxColumnWidth
        )
        .preferredColorScheme(.dark)
    }

    // MARK: - アクション

    private func setupAnimationManager() {
        // EditorManagerにAnimationManagerの参照を設定
        editorManager.animationManager = animationManager

        animationManager.onFrameUpdate = { [weak editorManager] time in
            guard let manager = editorManager else { return }
            // アニメーション中のレイヤー状態を更新
            for layer in manager.project.layers {
                animationManager.updateFrameAnimation(for: layer, at: time)
            }
            manager.requestRender()
        }
    }

    /// エディターウィンドウの閉じるボタンをインターセプトして保存確認を行う
    private func setupWindowCloseInterceptor() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let window = NSApp.windows.first(where: {
                $0.title == "WallBlank エディター" || $0.identifier?.rawValue == "editor"
            }) else { return }

            let delegate = EditorWindowDelegate(editorManager: editorManager)
            // delegateの参照を保持するためwindowのassociatedObjectに格納
            objc_setAssociatedObject(window, &EditorWindowDelegate.associatedKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            window.delegate = delegate
        }
    }

    private func exportImage() {
        let panel = NSSavePanel()
        panel.title = "画像をエクスポート"
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = "\(editorManager.project.name).png"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            let format: NSBitmapImageRep.FileType = url.pathExtension.lowercased() == "jpg" || url.pathExtension.lowercased() == "jpeg" ? .jpeg : .png

            if editorManager.renderer?.exportToFile(url: url, format: format) == true {
                debugLog("[ImageEditorView] エクスポート完了: \(url.path)")
            }
        }
    }
}

// MARK: - ウィンドウ閉じる時の保存確認デリゲート

/// エディターウィンドウが閉じられる前に未保存の変更を確認するデリゲート
class EditorWindowDelegate: NSObject, NSWindowDelegate {
    static var associatedKey: UInt8 = 0

    private let editorManager: ImageEditorManager

    init(editorManager: ImageEditorManager) {
        self.editorManager = editorManager
        super.init()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return editorManager.confirmSaveBeforeClose()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // 長時間放置やスリープ復帰後、画像だけ固まっている場合に再描画する
        editorManager.forceRefreshAfterWake()
    }
}

// MARK: - プレビュー

#Preview {
    ImageEditorView()
        .frame(width: 1200, height: 800)
}
