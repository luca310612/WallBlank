import SwiftUI
import AppKit

/// ブラシツールタイプ
enum MaskBrushTool: String, CaseIterable {
    case paint = "ペイント"
    case erase = "消しゴム"
    case rectFill = "矩形（表示）"
    case rectCut = "矩形（非表示）"

    var icon: String {
        switch self {
        case .paint: return "paintbrush.fill"
        case .erase: return "eraser.fill"
        case .rectFill: return "square.fill"
        case .rectCut: return "square.dashed"
        }
    }

    var isRectTool: Bool {
        switch self {
        case .rectFill, .rectCut: return true
        default: return false
        }
    }
}

/// マスクエディタービューモデル
class MaskEditorViewModel: ObservableObject {
    @Published var brushSize: CGFloat = 30
    @Published var brushSoftness: Float = 0.5
    @Published var brushTool: MaskBrushTool = .paint
    @Published var showMaskOverlay: Bool = true
    @Published var maskOpacity: Double = 0.5

    @Published var isProcessingAI: Bool = false
    @Published var aiDetectionConfidence: Float = 0

    weak var effectManager: EffectManager?

    // Undo/Redo スタック
    private var undoStack: [[UInt8]] = []
    private var redoStack: [[UInt8]] = []
    private let maxUndoSteps = AppConstants.Editor.maxUndoSteps
    private var pendingSnapshot: [UInt8]?

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(effectManager: EffectManager = .shared) {
        self.effectManager = effectManager
    }

    /// AIで髪を検出
    func detectHairWithAI(from image: NSImage) {
        isProcessingAI = true
        saveUndoSnapshot()

        HairSegmentation.shared.detectHair(from: image) { [weak self] result in
            DispatchQueue.main.async {
                self?.isProcessingAI = false

                switch result {
                case .success(let segmentationResult):
                    self?.effectManager?.maskData = segmentationResult.maskData
                    self?.aiDetectionConfidence = segmentationResult.confidence
                    self?.commitUndoSnapshot()
                    print("[MaskEditor] AI detection completed in \(String(format: "%.2f", segmentationResult.processingTime))s, confidence: \(segmentationResult.confidence)")

                case .failure(let error):
                    self?.pendingSnapshot = nil
                    print("[MaskEditor] AI detection failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Undo/Redo

    /// ストローク開始前にスナップショットを保存（まだスタックにはpushしない）
    func saveUndoSnapshot() {
        guard let maskData = effectManager?.maskData else { return }
        pendingSnapshot = maskData.data
    }

    /// ストローク完了時にスタックにpush
    func commitUndoSnapshot() {
        guard let snapshot = pendingSnapshot else { return }
        undoStack.append(snapshot)
        if undoStack.count > maxUndoSteps {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
        pendingSnapshot = nil
    }

    /// 元に戻す
    func undo() {
        guard let snapshot = undoStack.popLast(),
              let maskData = effectManager?.maskData else { return }
        redoStack.append(maskData.data)
        maskData.data = snapshot
        effectManager?.lastMaskUpdateTime = CACurrentMediaTime()
    }

    /// やり直す
    func redo() {
        guard let snapshot = redoStack.popLast(),
              let maskData = effectManager?.maskData else { return }
        undoStack.append(maskData.data)
        maskData.data = snapshot
        effectManager?.lastMaskUpdateTime = CACurrentMediaTime()
    }

    /// マスクをクリア
    func clearMask() {
        saveUndoSnapshot()
        effectManager?.clearMask()
        commitUndoSnapshot()
    }

    /// マスクを反転
    func invertMask() {
        saveUndoSnapshot()
        effectManager?.invertMask()
        commitUndoSnapshot()
    }

    /// マスクをぼかす
    func blurMask() {
        saveUndoSnapshot()
        effectManager?.blurMask(radius: 5)
        commitUndoSnapshot()
    }
}

/// マスクエディタービュー
struct MaskEditorView: View {
    @ObservedObject var viewModel: MaskEditorViewModel
    let backgroundImage: NSImage?
    let imageSize: CGSize

    @State private var lastDragLocation: CGPoint?
    @State private var currentMouseLocation: CGPoint?
    @State private var currentImageRect: CGRect = .zero
    @State private var maskVersion: Int = 0
    @State private var lastMaskRedrawTime: CFTimeInterval = 0
    @State private var isDrawingStroke: Bool = false
    @State private var strokeImagePoints: [CGPoint] = []
    @State private var strokeViewPoints: [CGPoint] = []
    /// 矩形ツール用ドラッグ開始（ビュー座標）
    @State private var rectDragStart: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            // 上部: ブラシ設定バー（Photoshop風のオプションバー）
            HStack(spacing: 16) {
                // 現在ツール
                HStack(spacing: 6) {
                    Image(systemName: viewModel.brushTool.icon)
                        .font(.system(size: 13))
                    Text(maskToolTitle(viewModel.brushTool))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Divider()
                    .frame(height: 18)

                // ブラシサイズ
                HStack(spacing: 6) {
                    Text("サイズ")
                        .font(.system(size: 11))
                    Slider(value: $viewModel.brushSize, in: 0.1...150, step: 0.1)
                        .frame(width: 140)
                    Text("\(Int(viewModel.brushSize)) px")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                // ブラシ硬さ
                HStack(spacing: 6) {
                    Text("硬さ")
                        .font(.system(size: 11))
                    Slider(value: $viewModel.brushSoftness, in: 0.1...1)
                        .frame(width: 100)
                }

                Spacer()

                // オーバーレイ表示/不透明度
                HStack(spacing: 8) {
                    Toggle(isOn: $viewModel.showMaskOverlay) {
                        Image(systemName: "eye")
                            .font(.system(size: 12))
                    }
                    .toggleStyle(.button)
                    .help("マスクオーバーレイ表示")

                    HStack(spacing: 4) {
                        Text("オーバーレイ")
                            .font(.system(size: 11))
                        Slider(value: $viewModel.maskOpacity, in: 0.1...1.0)
                            .frame(width: 80)
                            .disabled(!viewModel.showMaskOverlay)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // 中央: 左ツールバー + キャンバス + 右パネル
            HStack(spacing: 0) {
                // 左: 縦ツールバー（Photoshop風）
                VStack(spacing: 8) {
                    ForEach(MaskBrushTool.allCases, id: \.self) { tool in
                        Button(action: { viewModel.brushTool = tool }) {
                            Image(systemName: tool.icon)
                                .font(.system(size: 16))
                                .frame(width: 28, height: 28)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(viewModel.brushTool == tool ? Color.accentColor.opacity(0.25) : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(tool.rawValue)
                    }

                    Divider()
                        .frame(height: 1)
                        .padding(.vertical, 4)

                    Button(action: {
                        viewModel.clearMask()
                        maskVersion += 1
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("マスクをクリア")

                    Button(action: {
                        viewModel.invertMask()
                        maskVersion += 1
                    }) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 14))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("マスクを反転")

                    Button(action: {
                        viewModel.blurMask()
                        maskVersion += 1
                    }) {
                        Image(systemName: "drop.circle")
                            .font(.system(size: 14))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("マスクをぼかす")

                    Spacer()
                }
                .padding(8)
                .frame(width: 60)
                .background(Color(NSColor.controlBackgroundColor))

                Divider()

                // 中央: キャンバスエリア（チェッカーボード + 画像 + マスク）
                GeometryReader { geometry in
                    let imageRect = calculateImageRect(in: geometry.size)

                    ZStack {
                        // チェッカーボード背景
                        CheckerboardBackground()
                            .cornerRadius(4)

                        // 背景画像
                        if let image = backgroundImage {
                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                .frame(width: imageRect.width, height: imageRect.height)
                                .position(x: imageRect.midX, y: imageRect.midY)
                        }

                        // マスクオーバーレイ
                        if viewModel.showMaskOverlay, let maskData = viewModel.effectManager?.maskData {
                            MaskOverlayView(
                                maskData: maskData,
                                opacity: viewModel.maskOpacity,
                                version: maskVersion,
                                isDrawing: isDrawingStroke
                            )
                                .frame(width: imageRect.width, height: imageRect.height)
                                .position(x: imageRect.midX, y: imageRect.midY)
                        }

                        // ストロークプレビュー（マスクは更新せず線だけ表示）
                        if isDrawingStroke, strokeViewPoints.count >= 2, !viewModel.brushTool.isRectTool {
                            Canvas { context, _ in
                                var path = Path()
                                path.addLines(strokeViewPoints)

                                // 画面上のブラシ径に合わせたプレビュー線幅
                                let brushRadiusScreen = viewModel.brushSize * imageRect.width / imageSize.width
                                let diameter = max(1.0, brushRadiusScreen * 2.0) // カーソル円の直径と一致

                                // 赤い蛍光ペン風：太い半透明 + 加算系の見え方
                                context.blendMode = .plusLighter
                                context.stroke(
                                    path,
                                    with: .color(Color.red.opacity(0.28)),
                                    style: StrokeStyle(lineWidth: diameter, lineCap: .round, lineJoin: .round)
                                )
                                // 芯（少し濃い）を重ねて「蛍光ペン」っぽさを出す
                                context.stroke(
                                    path,
                                    with: .color(Color.red.opacity(0.45)),
                                    style: StrokeStyle(lineWidth: max(1.0, diameter * 0.55), lineCap: .round, lineJoin: .round)
                                )
                            }
                            .allowsHitTesting(false)
                        }

                        // ブラシカーソルプレビュー（実際のブラシ半径と一致させる）
                        if let mouseLocation = currentMouseLocation, !viewModel.brushTool.isRectTool {
                            // brushSize は画像ピクセル単位の半径として扱っているので、
                            // 画面上の半径に変換し、直径としてフレームサイズに設定する
                            let brushRadiusScreen = viewModel.brushSize * imageRect.width / imageSize.width
                            let diameter = brushRadiusScreen * 2

                            Circle()
                                .stroke(viewModel.brushTool == .paint ? Color.white : Color.black, lineWidth: 1.5)
                                .frame(width: diameter, height: diameter)
                                .position(mouseLocation)
                                .allowsHitTesting(false)

                            Circle()
                                .stroke(viewModel.brushTool == .paint ? Color.black.opacity(0.4) : Color.white.opacity(0.4), lineWidth: 0.5)
                                .frame(width: diameter + 2, height: diameter + 2)
                                .position(mouseLocation)
                                .allowsHitTesting(false)
                        }

                        // キャンバス領域の Geometry サイズ（レイアウト確認用）
                        GeometryReader { geo in
                            VStack {
                                Spacer()
                                HStack {
                                    Text("width: \(geo.size.width), height: \(geo.size.height)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                                    Spacer()
                                }
                            }
                            .padding(8)
                        }
                        .allowsHitTesting(false)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if viewModel.brushTool.isRectTool {
                                    if rectDragStart == nil {
                                        rectDragStart = value.startLocation
                                        viewModel.saveUndoSnapshot()
                                    }
                                    currentMouseLocation = value.location
                                    return
                                }
                                if !isDrawingStroke {
                                    isDrawingStroke = true
                                }
                                currentMouseLocation = value.location
                                handleDrag(at: value.location, in: geometry.size, imageRect: imageRect)
                            }
                            .onEnded { value in
                                if viewModel.brushTool.isRectTool {
                                    defer { rectDragStart = nil }
                                    applyRectMaskIfNeeded(
                                        start: value.startLocation,
                                        end: value.location,
                                        imageRect: imageRect
                                    )
                                    maskVersion += 1
                                    viewModel.commitUndoSnapshot()
                                    currentMouseLocation = nil
                                    return
                                }
                                lastDragLocation = nil
                                applyRecordedStrokeIfNeeded()
                                isDrawingStroke = false
                                strokeImagePoints.removeAll(keepingCapacity: true)
                                strokeViewPoints.removeAll(keepingCapacity: true)
                                viewModel.commitUndoSnapshot()
                            }
                    )
                    .onHover { isHovering in
                        if !isHovering {
                            currentMouseLocation = nil
                        }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            currentMouseLocation = location
                        case .ended:
                            currentMouseLocation = nil
                        }
                    }
                    .onAppear {
                        currentImageRect = imageRect
                    }
                    .onChange(of: geometry.size) {
                        currentImageRect = calculateImageRect(in: geometry.size)
                    }
                    .padding(12)
                }

                Divider()

                // 右: プロパティパネル
                VStack(alignment: .leading, spacing: 12) {
                    GroupBox(label: Text("ブラシ").font(.system(size: 11))) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("サイズ")
                                    .font(.system(size: 11))
                                Spacer()
                                Text("\(Int(viewModel.brushSize)) px")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $viewModel.brushSize, in: 0.1...150, step: 0.1)

                            HStack {
                                Text("硬さ")
                                    .font(.system(size: 11))
                                Spacer()
                                Text(String(format: "%.0f%%", viewModel.brushSoftness * 100))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $viewModel.brushSoftness, in: 0.1...1)
                        }
                        .padding(8)
                    }

                    GroupBox(label: Text("マスク").font(.system(size: 11))) {
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                viewModel.clearMask()
                                maskVersion += 1
                            } label: {
                                Label("クリア", systemImage: "trash")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)

                            Button {
                                viewModel.invertMask()
                                maskVersion += 1
                            } label: {
                                Label("反転", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)

                            Button {
                                viewModel.blurMask()
                                maskVersion += 1
                            } label: {
                                Label("ぼかす", systemImage: "drop.circle")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(8)
                    }

                    GroupBox(label: Text("AI").font(.system(size: 11))) {
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                if let image = backgroundImage {
                                    viewModel.detectHairWithAI(from: image)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    if viewModel.isProcessingAI {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                    } else {
                                        Image(systemName: "wand.and.stars")
                                    }
                                    Text("髪を自動検出")
                                        .font(.system(size: 11))
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(backgroundImage == nil || viewModel.isProcessingAI)

                            if viewModel.aiDetectionConfidence > 0 {
                                Text(String(format: "信頼度: %.0f%%", viewModel.aiDetectionConfidence * 100))
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(8)
                    }

                    Spacer()

                    // Undo / Redo
                    HStack(spacing: 12) {
                        Button {
                            viewModel.undo()
                            maskVersion += 1
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .disabled(!viewModel.canUndo)
                        .help("元に戻す (⌘Z)")

                        Button {
                            viewModel.redo()
                            maskVersion += 1
                        } label: {
                            Image(systemName: "arrow.uturn.forward")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .disabled(!viewModel.canRedo)
                        .help("やり直す (⇧⌘Z)")
                    }
                    .padding(.top, 4)
                }
                .padding(10)
                .frame(width: 220)
                .background(Color(NSColor.controlBackgroundColor))
            }
        }
    }

    // MARK: - Geometry

    /// 画像の表示矩形を計算
    private func calculateImageRect(in viewSize: CGSize) -> CGRect {
        let aspectRatio = imageSize.width / imageSize.height
        let viewAspectRatio = viewSize.width / viewSize.height

        if viewAspectRatio > aspectRatio {
            // 縦に合わせる
            let height = viewSize.height
            let width = height * aspectRatio
            let x = (viewSize.width - width) / 2
            return CGRect(x: x, y: 0, width: width, height: height)
        } else {
            // 横に合わせる
            let width = viewSize.width
            let height = width / aspectRatio
            let y = (viewSize.height - height) / 2
            return CGRect(x: 0, y: y, width: width, height: height)
        }
    }

    /// ビュー座標を画像ピクセル座標に変換
    private func viewToImageCoordinate(_ location: CGPoint, imageRect: CGRect) -> CGPoint? {
        guard imageRect.contains(location) else { return nil }
        let normalizedX = (location.x - imageRect.minX) / imageRect.width
        let normalizedY = (location.y - imageRect.minY) / imageRect.height
        return CGPoint(x: normalizedX * imageSize.width, y: normalizedY * imageSize.height)
    }

    private func maskToolTitle(_ tool: MaskBrushTool) -> String {
        switch tool {
        case .paint: return "ブラシ"
        case .erase: return "消しゴム"
        case .rectFill: return "矩形（表示）"
        case .rectCut: return "矩形（切り抜き）"
        }
    }

    /// ビュー座標を画像ピクセル座標へ（画像矩形外も数値化し、fillAxisAlignedRect 側でクリップ）
    private func imagePoint(fromView location: CGPoint, imageRect: CGRect) -> CGPoint {
        let nx = (location.x - imageRect.minX) / imageRect.width
        let ny = (location.y - imageRect.minY) / imageRect.height
        return CGPoint(x: nx * imageSize.width, y: ny * imageSize.height)
    }

    private func applyRectMaskIfNeeded(start: CGPoint, end: CGPoint, imageRect: CGRect) {
        guard let manager = viewModel.effectManager else { return }
        if manager.maskData == nil {
            manager.initializeMask(width: Int(imageSize.width), height: Int(imageSize.height))
        }
        let p0 = imagePoint(fromView: start, imageRect: imageRect)
        let p1 = imagePoint(fromView: end, imageRect: imageRect)
        let v: UInt8 = viewModel.brushTool == .rectFill ? 255 : 0
        manager.fillMaskRect(x0: p0.x, y0: p0.y, x1: p1.x, y1: p1.y, value: v)
    }

    // MARK: - Drag Handling

    private func handleDrag(at location: CGPoint, in viewSize: CGSize, imageRect: CGRect) {
        guard let manager = viewModel.effectManager else { return }

        // マスクが初期化されていない場合は初期化
        if manager.maskData == nil {
            manager.initializeMask(width: Int(imageSize.width), height: Int(imageSize.height))
            viewModel.saveUndoSnapshot()
        }

        // 画像座標に変換
        guard let imagePoint = viewToImageCoordinate(location, imageRect: imageRect) else { return }

        // ドラッグ開始時にUndoスナップショットを保存
        if lastDragLocation == nil {
            viewModel.saveUndoSnapshot()
            strokeImagePoints.removeAll(keepingCapacity: true)
            strokeViewPoints.removeAll(keepingCapacity: true)
        }

        // ブラシサイズを画像ピクセル単位の半径として扱う
        // （カーソル表示も同じ画像ピクセル基準でスケールしているため、見た目と実際の塗り範囲が一致する）
        let scaledBrushSize = max(1, Int(round(viewModel.brushSize)))

        // ストローク補間：前回の位置から現在の位置までを線形補間でサンプリング
        if let lastLocation = lastDragLocation,
           let lastImagePoint = viewToImageCoordinate(lastLocation, imageRect: imageRect) {
            let dx = imagePoint.x - lastImagePoint.x
            let dy = imagePoint.y - lastImagePoint.y
            let distance = sqrt(dx * dx + dy * dy)
            // 半径の約25%間隔でサンプリングして線を滑らかにする
            let step = max(1.0, CGFloat(scaledBrushSize) * 0.25)
            if distance > step {
                let steps = max(Int(distance / step), 1)
                for i in 1...steps {
                    let t = CGFloat(i) / CGFloat(steps)
                    let interpPoint = CGPoint(
                        x: lastImagePoint.x + dx * t,
                        y: lastImagePoint.y + dy * t
                    )
                    strokeImagePoints.append(interpPoint)
                }
            } else {
                strokeImagePoints.append(imagePoint)
            }
        } else {
            // 最初のタッチ
            strokeImagePoints.append(imagePoint)
        }

        lastDragLocation = location

        // プレビュー用のパスはView座標でそのまま蓄積
        strokeViewPoints.append(location)

        // プレビューの再描画用（極端な連続更新を軽く抑制）
        let now = CACurrentMediaTime()
        let minInterval: CFTimeInterval = 1.0 / 120.0
        if now - lastMaskRedrawTime >= minInterval {
            lastMaskRedrawTime = now
        }
    }

    private func applyRecordedStrokeIfNeeded() {
        guard let manager = viewModel.effectManager else { return }
        guard manager.maskData != nil else { return }
        guard !strokeImagePoints.isEmpty else { return }

        let brushValue: UInt8 = viewModel.brushTool == .paint ? 255 : 0
        let isErasing = viewModel.brushTool == .erase
        let scaledBrushSize = max(1, Int(round(viewModel.brushSize)))

        manager.applyMaskStrokeDirect(
            points: strokeImagePoints,
            radius: scaledBrushSize,
            value: brushValue,
            softness: viewModel.brushSoftness,
            isErasing: isErasing
        )

        // マスクが確定更新されたタイミングでのみ再描画トリガーを進める
        maskVersion &+= 1
    }
}

/// マスクオーバーレイビュー
struct MaskOverlayView: View {
    let maskData: MaskData
    let opacity: Double
    var version: Int = 0  // 再描画トリガー
    var isDrawing: Bool = false

    @State private var cachedImage: CGImage?
    @State private var cachedVersion: Int = -1

    var body: some View {
        Canvas { context, size in
            let image: CGImage?
            if cachedVersion == version, let cached = cachedImage {
                image = cached
            } else {
                image = createMaskImage()
                DispatchQueue.main.async {
                    cachedImage = image
                    cachedVersion = version
                }
            }
            guard let cgImage = image else { return }
            let rect = CGRect(origin: .zero, size: size)
            context.draw(Image(decorative: cgImage, scale: 1), in: rect)
        }
        .opacity(opacity)
        .allowsHitTesting(false)
    }

    private func createMaskImage() -> CGImage? {
        let srcWidth = maskData.width
        let srcHeight = maskData.height
        guard srcWidth > 0, srcHeight > 0 else { return nil }

        // ほどよくダウンサンプリングしてCPU負荷を抑えつつ、見た目は十分な解像度を維持
        let baseScale = 2
        let pixelCount = srcWidth * srcHeight
        var dynamicScale: Int
        if pixelCount > 3840 * 2160 {
            dynamicScale = 4
        } else if pixelCount > 2560 * 1440 {
            dynamicScale = 3
        } else if pixelCount > 1920 * 1080 {
            dynamicScale = 2
        } else {
            dynamicScale = baseScale
        }
        // ストローク中はさらに一段階ダウンサンプリングしてCPU負荷を優先的に下げる
        if isDrawing {
            dynamicScale += 1
        }
        let scale = max(1, dynamicScale)

        let dstWidth = max(1, srcWidth / scale)
        let dstHeight = max(1, srcHeight / scale)

        var pixels = [UInt8](repeating: 0, count: dstWidth * dstHeight * 4)

        let maskBytes = maskData.data
        for y in 0..<dstHeight {
            let srcY = min(srcHeight - 1, y * scale)
            for x in 0..<dstWidth {
                let srcX = min(srcWidth - 1, x * scale)
                let srcIndex = srcY * srcWidth + srcX
                let maskValue = maskBytes[srcIndex]
                let dstIndex = (y * dstWidth + x) * 4
                // ストレートアルファの赤オーバーレイ（プレマルチだと暗い背景で「色が反転した」ように見えやすい）
                pixels[dstIndex] = 255
                pixels[dstIndex + 1] = 0
                pixels[dstIndex + 2] = 0
                pixels[dstIndex + 3] = maskValue
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)

        guard let context = CGContext(
            data: &pixels,
            width: dstWidth,
            height: dstHeight,
            bitsPerComponent: 8,
            bytesPerRow: dstWidth * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }

        return context.makeImage()
    }
}

/// チェッカーボード背景（Photoshop風の透明背景）
struct CheckerboardBackground: View {
    private let squareSize: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            let cols = Int(ceil(geometry.size.width / squareSize))
            let rows = Int(ceil(geometry.size.height / squareSize))
            let light = Color(NSColor.windowBackgroundColor)
            let dark = Color(NSColor.windowBackgroundColor).opacity(0.7)

            Canvas { context, size in
                for row in 0..<rows {
                    for col in 0..<cols {
                        let isDark = (row + col).isMultiple(of: 2)
                        let rect = CGRect(
                            x: CGFloat(col) * squareSize,
                            y: CGFloat(row) * squareSize,
                            width: squareSize,
                            height: squareSize
                        )
                        context.fill(
                            Path(rect),
                            with: .color(isDark ? dark : light)
                        )
                    }
                }
            }
        }
    }
}

/// マスクエディターダイアログ
struct MaskEditorDialog: View {
    @ObservedObject var viewModel: MaskEditorViewModel
    let backgroundImage: NSImage?
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー
            HStack {
                Text("マスクエディター")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            // エディター本体
            MaskEditorView(
                viewModel: viewModel,
                backgroundImage: backgroundImage,
                imageSize: backgroundImage?.size ?? CGSize(width: 1920, height: 1080)
            )
        }
        .frame(width: 800, height: 600)
    }
}
