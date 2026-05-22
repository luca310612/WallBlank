import SwiftUI
import AppKit

/// キャンバスインタラクションオーバーレイ
/// Metal描画の上に配置し、選択枠・ハンドル・ジェスチャーを処理する
struct CanvasInteractionOverlay: View {
    @ObservedObject var editorManager: ImageEditorManager
    @ObservedObject var viewport: CanvasViewport

    // MARK: - インタラクション状態

    @State private var isDraggingLayer = false
    @State private var activeHandle: CanvasHitTester.HandlePosition?
    @State private var dragStartCanvasPoint: CGPoint = .zero
    @State private var dragStartTransform: LayerTransform = .identity
    /// リサイズ開始時の1倍あたりの基本サイズ（ドラッグ中に変動しないよう保持）
    @State private var dragStartBaseSize: CGSize = .zero
    @State private var isSpaceHeld = false
    @State private var isPanning = false
    @State private var panStartOffset: CGPoint = .zero
    @State private var dragStartLocation: CGPoint = .zero

    /// NSEventモニターの参照（解除用）
    @State private var keyDownMonitor: Any?
    @State private var keyUpMonitor: Any?
    @State private var scrollMonitor: Any?
    @State private var magnifyMonitor: Any?

    /// ウィンドウ非アクティブ時にズーム/ジェスチャーを無効化するための監視
    @State private var windowDidResignMonitor: Any?
    @State private var windowDidBecomeMonitor: Any?
    @State private var rightMouseDownMonitor: Any?
    /// エディタウィンドウがアクティブかどうか
    @State private var isWindowActive: Bool = true

    /// ビューポート（パン・ズーム）インタラクション中かどうか
    @State private var isViewportInteracting: Bool = false
    /// ビューポートインタラクション終了デバウンス
    @State private var viewportInteractionWorkItem: DispatchWorkItem?

    /// キャンバスビューの参照（座標変換用）
    @State private var canvasNSView: NSView?

    // MARK: - ペンツール（パス編集）

    @State private var lastPointerScreenPoint: CGPoint?
    @State private var isTracingSelectionBrush = false
    /// 自由ペンなぞり中の軌跡（@State のみ更新し、ドラッグ中は ImageEditorManager に触れない → 全体再描画を避ける）
    @State private var liveFreeformBrushTrace: [CGPoint] = []
    @State private var finalizedBrushOutlinePoints: [CGPoint] = []
    /// ストローク開始時のブラシ設定スナップショット（途中で太さ等を変えても過去に波及させない）
    @State private var activeBrushStrokeSnapshot: EditorBrushStrokeSettings?
    @State private var activeMaskPostSnapshot: EditorMaskPostSettings?
    @State private var activeGradientSnapshot: EditorMaskGradientSettings?
    @State private var activeMaskCombineSnapshot: EditorMaskCombineMode?
    @State private var activeBrushRadiusSnapshot: CGFloat?

    // MARK: - Phase 1.3+: BrushEngine dispatch
    // Why: 既存のフリーハンド軌跡収集ロジックを残しつつ、Strategy パターンの BrushEngine に
    // 同じサンプルを並走で流し込む。Phase 1.4 (① Metal 化) で engine.commit(...) を本実装すれば
    // この context がそのまま GPU rasterizer に渡る。
    @State private var activeBrushEngine: BrushEngine?
    @State private var activeBrushEngineContext: BrushStrokeContext?
    @State private var lastBrushInputSample: BrushInputSample?
    /// NSEvent.mouseDragged ローカルモニタが取得した最新の圧力／傾き
    /// (DragGesture.Value 経由では取得できないためサイドチャネルで保持)
    @State private var lastNSEventPressure: CGFloat = 1.0
    @State private var lastNSEventTiltDegrees: CGFloat = 0
    @State private var lastNSEventAzimuthDegrees: CGFloat = 0
    @State private var brushPressureMonitor: Any?

    /// 非同期マスク適用の世代（新しいストロークで無効化し、古い完了を無視する）
    @State private var selectionMaskAsyncSerial: UInt64 = 0
    @State private var marchingAntsPhase: CGFloat = 0
    @State private var marchingAntsTimer: Timer?

    /// ベクターペン（標準／曲率）のドラッグ中プレビュー
    @State private var vectorPenGestureActive = false
    @State private var vectorPenDidDrag = false
    @State private var vectorPenStartScreen: CGPoint = .zero
    @State private var vectorPenCurrentScreen: CGPoint = .zero

    /// パス選択: いずれかのアンカーを掴んでパス全体を移動中
    @State private var pathSelectDragging = false
    @State private var pathSelectLastCanvas: CGPoint = .zero
    /// ダイレクト選択: ドラッグ中のアンカーインデックス
    @State private var directSelectAnchorIndex: Int?

    // MARK: - 水流ブラシ
    /// 水流ブラシのストローク中フラグ
    @State private var isFlowBrushStroking: Bool = false
    /// 水流ブラシ: 最後にRustへ送ったキャンバス座標（過密サンプル抑制用）
    @State private var lastFlowBrushCanvasPoint: CGPoint?
    /// 水流ブラシのターゲットレイヤー（Rust側ID）
    @State private var activeFlowBrushLayerId: String?

    /// ドラッグ判定用の最小距離（スクリーンピクセル）
    private let minDragDistance: CGFloat = 3
    /// ハンドルの当たり判定半径（スクリーンピクセル）
    private let handleHitRadius: CGFloat = 8

    // MARK: - 速度予測（非線形補間用）

    /// 前回のドラッグ位置（スクリーン座標）
    @State private var lastDragLocation: CGPoint = .zero
    /// 前回のドラッグ時刻
    @State private var lastDragTime: CFTimeInterval = 0
    /// 現在の速度ベクトル（スクリーンピクセル/秒）
    @State private var dragVelocity: CGPoint = .zero
    /// 速度の指数移動平均の平滑化係数（0に近いほど慣性が強い）
    private let velocitySmoothingFactor: CGFloat = 0.3
    /// 速度予測の適用倍率（予測フレーム数に相当）
    private let predictionFactor: CGFloat = 0.0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // ジェスチャー受付領域（透明）
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(canvasGesture)
                    .background(CanvasNSViewFinder(nsView: $canvasNSView))
                    .onAppear {
                        viewport.viewSize = geometry.size
                        setupEventMonitors()
                        startMarchingAnts()
                    }
                    .onDisappear {
                        removeEventMonitors()
                        stopMarchingAnts()
                    }
                    .onChange(of: editorManager.currentTool) { _, newTool in
                        // ペン以外に切り替えたら、ペン用オーバーレイを残さない
                        if newTool != .pen {
                            isTracingSelectionBrush = false
                            liveFreeformBrushTrace = []
                            finalizedBrushOutlinePoints = []
                            editorManager.clearFreeformBrushOutlinePreviews()
                            resetVectorPenGesture()
                        }
                    }
                    .onChange(of: editorManager.penToolKind) { _, newKind in
                        resetVectorPenGesture()
                        if newKind.isFreeformBrushLike {
                            var s = editorManager.selection
                            s.penPath = PenPath()
                            editorManager.selection = s
                        } else {
                            isTracingSelectionBrush = false
                            liveFreeformBrushTrace = []
                            finalizedBrushOutlinePoints = []
                            editorManager.clearFreeformBrushOutlinePreviews()
                            var s = editorManager.selection
                            s.brushTracePoints = []
                            editorManager.selection = s
                        }
                    }
                    .onChange(of: geometry.size) { _, newSize in
                        viewport.viewSize = newSize
                    }

                // 選択レイヤーのバウンディングボックス + ハンドル
                if let layer = editorManager.selectedLayer {
                    selectionOverlay(for: layer)
                        .allowsHitTesting(false)
                }

                if editorManager.currentTool == .pen {
                    if editorManager.penToolKind.isFreeformBrushLike {
                        // 確定ストロークは常に表示し、その上になぞり中マーカー（なぞり中も既存線を消さない）
                        ZStack {
                            ForEach(Array(editorManager.freeformBrushCompletedOutlines.enumerated()), id: \.offset) { _, pts in
                                brushTraceOverlay(
                                    points: pts,
                                    brushRadius: activeBrushRadiusSnapshot ?? editorManager.toolSettings.stroke.radius
                                )
                                .allowsHitTesting(false)
                            }
                            if !finalizedBrushOutlinePoints.isEmpty {
                                brushTraceOverlay(
                                    points: finalizedBrushOutlinePoints,
                                    brushRadius: activeBrushRadiusSnapshot ?? editorManager.selection.brushRadius
                                )
                                .allowsHitTesting(false)
                            }
                            if isTracingSelectionBrush, !liveFreeformBrushTrace.isEmpty {
                                brushMarkerOverlay(
                                    points: liveFreeformBrushTrace,
                                    brushRadius: activeBrushRadiusSnapshot ?? editorManager.selection.brushRadius
                                )
                                .allowsHitTesting(false)
                            }
                        }
                    } else {
                        vectorPenEditOverlay()
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    // MARK: - 選択オーバーレイ描画

    @ViewBuilder
    private func selectionOverlay(for layer: EditorLayer) -> some View {
        let canvasRect = CanvasHitTester.boundingBox(
            for: layer,
            canvasSize: editorManager.project.canvasSize
        )

        let scale = viewport.totalScale
        let screenOrigin = viewport.canvasToScreen(canvasRect.origin)
        let screenW = canvasRect.width * scale
        let screenH = canvasRect.height * scale

        // 画像背面の補助表示（アウトラインと同じ範囲）
        Rectangle()
            .fill(Color.accentColor.opacity(0.08))
            .frame(width: screenW, height: screenH)
            .position(
                x: screenOrigin.x + screenW / 2,
                y: screenOrigin.y + screenH / 2
            )

        // バウンディングボックス（青枠）
        Rectangle()
            .stroke(Color.accentColor, lineWidth: 1.5)
            .frame(width: screenW, height: screenH)
            .position(
                x: screenOrigin.x + screenW / 2,
                y: screenOrigin.y + screenH / 2
            )

        // 8つのリサイズハンドル
        ForEach(Array(CanvasHitTester.HandlePosition.allCases.enumerated()), id: \.offset) { _, handle in
            let handleCanvasPos = CanvasHitTester.handlePosition(handle, for: canvasRect)
            let screenPos = viewport.canvasToScreen(handleCanvasPos)

            Circle()
                .fill(Color.white)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle().stroke(Color.accentColor, lineWidth: 1.5)
                )
                .position(x: screenPos.x, y: screenPos.y)
        }
    }

    // MARK: - ジェスチャー

    private var canvasGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                handleDragChanged(value)
            }
            .onEnded { value in
                handleDragEnded(value)
            }
    }

    private func handleDragChanged(_ value: DragGesture.Value) {
        lastPointerScreenPoint = value.location

        // パンモード（スペースキー押下中）— ペンツール中もキャンバスを移動できるように先に処理
        if isSpaceHeld {
            if !isPanning {
                isPanning = true
                panStartOffset = viewport.panOffset
                dragStartLocation = value.startLocation
                editorManager.isInteracting = true
            }
            let dx = value.location.x - dragStartLocation.x
            let dy = value.location.y - dragStartLocation.y
            viewport.panOffset = CGPoint(
                x: panStartOffset.x + dx,
                y: panStartOffset.y + dy
            )
            return
        }

        // 水流ブラシツール
        if editorManager.currentTool == .flowBrush {
            handleFlowBrushDragChanged(value)
            return
        }

        // ペンツール
        if editorManager.currentTool == .pen {
            // Phase 1.3+: brushEngineID が解決できる種別 (≒isFreeformBrushLike) のときは
            // BrushEngine 抽象を経由する。既存の liveFreeformBrushTrace 収集は
            // 互換のため残置（描画パスは Phase 1.4 で engine.commit に置換）。
            if editorManager.penToolKind.brushEngineID != nil {
                let canvasPoint = viewport.screenToCanvas(value.location)
                let sample = makeBrushInputSample(at: canvasPoint)
                if !isTracingSelectionBrush {
                    isTracingSelectionBrush = true
                    var s = editorManager.selection
                    s.penPath = .init()
                    s.brushTracePoints = []
                    editorManager.selection = s
                    finalizedBrushOutlinePoints = []
                    liveFreeformBrushTrace = [canvasPoint]
                    // ストローク開始時点のブラシ設定を固定
                    activeBrushStrokeSnapshot = editorManager.toolSettings.stroke
                    activeMaskPostSnapshot = editorManager.toolSettings.maskPost
                    activeGradientSnapshot = editorManager.toolSettings.gradient
                    activeMaskCombineSnapshot = editorManager.toolSettings.maskCombine
                    activeBrushRadiusSnapshot = editorManager.toolSettings.stroke.radius
                    beginBrushEngineStroke(at: sample)
                } else {
                    // 過密サンプリングを避ける（@State を代入で更新してオーバーレイだけ再描画）
                    if let last = liveFreeformBrushTrace.last {
                        let minDist = viewport.screenLengthToCanvas(2.5)
                        if hypot(canvasPoint.x - last.x, canvasPoint.y - last.y) >= minDist {
                            var pts = liveFreeformBrushTrace
                            pts.append(canvasPoint)
                            liveFreeformBrushTrace = pts
                        }
                    } else {
                        liveFreeformBrushTrace = [canvasPoint]
                    }
                    continueBrushEngineStroke(with: sample)
                }
                return
            }

            if editorManager.penToolKind == .pathSelect {
                handlePathSelectDragChanged(value)
                return
            }
            if editorManager.penToolKind == .directSelect {
                handleDirectSelectDragChanged(value)
                return
            }

            handleVectorPenDragChanged(value)
            return
        }

        // ドラッグ開始判定
        if !isDraggingLayer && activeHandle == nil {
            let distance = hypot(
                value.location.x - value.startLocation.x,
                value.location.y - value.startLocation.y
            )

            if distance < minDragDistance {
                return
            }

            // インタラクションモード開始
            editorManager.isInteracting = true
            lastDragLocation = value.startLocation
            lastDragTime = CACurrentMediaTime()
            dragVelocity = .zero

            // ドラッグ開始位置でハンドル or レイヤーを判定
            let canvasPoint = viewport.screenToCanvas(value.startLocation)
            dragStartCanvasPoint = canvasPoint

            // 選択中レイヤーのハンドルチェック
            if let layer = editorManager.selectedLayer {
                let layerRect = CanvasHitTester.boundingBox(
                    for: layer,
                    canvasSize: editorManager.project.canvasSize
                )
                let handleRadiusInCanvas = viewport.screenLengthToCanvas(handleHitRadius)
                if let handle = CanvasHitTester.hitTestHandle(
                    point: canvasPoint,
                    layerRect: layerRect,
                    handleRadius: handleRadiusInCanvas
                ) {
                    activeHandle = handle
                    dragStartTransform = layer.transform
                    // リサイズ用：1倍あたりの基本サイズをドラッグ開始時に確定
                    let t = layer.transform
                    dragStartBaseSize = CGSize(
                        width: layerRect.width / CGFloat(t.scaleX),
                        height: layerRect.height / CGFloat(t.scaleY)
                    )
                    return
                }
            }

            // レイヤーヒットテスト
            if let hitLayer = editorManager.selectLayerAtCanvasPoint(canvasPoint) {
                isDraggingLayer = true
                dragStartTransform = hitLayer.transform
            }
            return
        }

        // 速度追跡（指数移動平均で平滑化）
        let now = CACurrentMediaTime()
        let dt = now - lastDragTime
        if dt > 0.001 {
            let instantVelocity = CGPoint(
                x: (value.location.x - lastDragLocation.x) / dt,
                y: (value.location.y - lastDragLocation.y) / dt
            )
            dragVelocity = CGPoint(
                x: dragVelocity.x * (1 - velocitySmoothingFactor) + instantVelocity.x * velocitySmoothingFactor,
                y: dragVelocity.y * (1 - velocitySmoothingFactor) + instantVelocity.y * velocitySmoothingFactor
            )
        }
        lastDragLocation = value.location
        lastDragTime = now

        // ハンドルドラッグ中（リサイズ）
        if let handle = activeHandle {
            performResize(value: value, handle: handle)
            return
        }

        // レイヤードラッグ中（移動 — 速度予測付き）
        if isDraggingLayer {
            performMove(value: value)
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value) {
        // スペース＋パンをペンツール中に使った場合は、パン終了のみ（アンカーを置かない）
        if isPanning, editorManager.currentTool == .pen {
            isPanning = false
            editorManager.isInteracting = false
            resetVectorPenGesture()
            return
        }

        // 水流ブラシツール終了
        if editorManager.currentTool == .flowBrush {
            handleFlowBrushDragEnded(value)
            return
        }

        // ペンツール
        if editorManager.currentTool == .pen {
            if editorManager.penToolKind.brushEngineID != nil {
                if isTracingSelectionBrush {
                    isTracingSelectionBrush = false
                    let endCanvasPoint = viewport.screenToCanvas(value.location)
                    let endSample = makeBrushInputSample(at: endCanvasPoint)
                    endBrushEngineStroke(with: endSample)
                    let refinedPoints = finalizeBrushOutlinePoints(
                        liveFreeformBrushTrace,
                        brushRadius: activeBrushRadiusSnapshot ?? editorManager.selection.brushRadius
                    )
                    liveFreeformBrushTrace = []
                    finalizedBrushOutlinePoints = []
                    var sel = editorManager.selection
                    sel.brushTracePoints = refinedPoints
                    editorManager.selection = sel
                    if editorManager.penToolKind == .magneticPen {
                        let combine = activeMaskCombineSnapshot ?? editorManager.toolSettings.maskCombine
                        selectionMaskAsyncSerial += 1
                        let applySerial = selectionMaskAsyncSerial
                        let pointsForMask = refinedPoints
                        editorManager.buildMagneticSelectionMaskAsync(
                            seedCanvasPoints: pointsForMask,
                            tolerance01: 0.12,
                            combineMode: combine
                        ) { mask in
                            guard applySerial == selectionMaskAsyncSerial else { return }
                            guard let mask else { return }
                            var s = editorManager.selection
                            s.mask = mask
                            editorManager.selection = s
                            editorManager.appendFreeformBrushOutline(pointsForMask)
                        }
                    } else {
                        let stroke = activeBrushStrokeSnapshot ?? editorManager.toolSettings.stroke
                        let post = activeMaskPostSnapshot ?? editorManager.toolSettings.maskPost
                        let grad = activeGradientSnapshot ?? editorManager.toolSettings.gradient
                        let combine = activeMaskCombineSnapshot ?? editorManager.toolSettings.maskCombine
                        selectionMaskAsyncSerial += 1
                        let applySerial = selectionMaskAsyncSerial
                        let pointsForMask = refinedPoints
                        editorManager.rasterizeSelectionMaskAsync(
                            fromBrushTrace: pointsForMask,
                            stroke: stroke,
                            post: post,
                            gradient: grad,
                            combine: combine
                        ) { mask in
                            guard applySerial == selectionMaskAsyncSerial else { return }
                            guard let mask else { return }
                            var s = editorManager.selection
                            s.mask = mask
                            editorManager.selection = s
                            editorManager.appendFreeformBrushOutline(pointsForMask)
                        }
                    }
                    // ストローク終了でスナップショット解除
                    activeBrushStrokeSnapshot = nil
                    activeMaskPostSnapshot = nil
                    activeGradientSnapshot = nil
                    activeMaskCombineSnapshot = nil
                    activeBrushRadiusSnapshot = nil
                } else if let screenPoint = lastPointerScreenPoint {
                    // クリックだけでも小さな選択を作れるようにする
                    let pt = viewport.screenToCanvas(screenPoint)
                    var s = editorManager.selection
                    s.brushTracePoints = [pt, pt]
                    editorManager.selection = s
                    if editorManager.penToolKind == .magneticPen {
                        let combine = editorManager.toolSettings.maskCombine
                        let clickPoints = editorManager.selection.brushTracePoints
                        selectionMaskAsyncSerial += 1
                        let applySerial = selectionMaskAsyncSerial
                        editorManager.buildMagneticSelectionMaskAsync(
                            seedCanvasPoints: clickPoints,
                            tolerance01: 0.12,
                            combineMode: combine
                        ) { mask in
                            guard applySerial == selectionMaskAsyncSerial else { return }
                            guard let mask else { return }
                            var sel = editorManager.selection
                            sel.mask = mask
                            editorManager.selection = sel
                            editorManager.appendFreeformBrushOutline(clickPoints)
                        }
                    } else {
                        let stroke = editorManager.toolSettings.stroke
                        let post = editorManager.toolSettings.maskPost
                        let grad = editorManager.toolSettings.gradient
                        let combine = editorManager.toolSettings.maskCombine
                        let clickPoints = editorManager.selection.brushTracePoints
                        selectionMaskAsyncSerial += 1
                        let applySerial = selectionMaskAsyncSerial
                        editorManager.rasterizeSelectionMaskAsync(
                            fromBrushTrace: clickPoints,
                            stroke: stroke,
                            post: post,
                            gradient: grad,
                            combine: combine
                        ) { mask in
                            guard applySerial == selectionMaskAsyncSerial else { return }
                            guard let mask else { return }
                            var sel = editorManager.selection
                            sel.mask = mask
                            editorManager.selection = sel
                            editorManager.appendFreeformBrushOutline(clickPoints)
                        }
                    }
                }
                return
            }

            if editorManager.penToolKind == .pathSelect || editorManager.penToolKind == .directSelect {
                pathSelectDragging = false
                pathSelectLastCanvas = .zero
                directSelectAnchorIndex = nil
                editorManager.isInteracting = false
                resetVectorPenGesture()
                return
            }

            handleVectorPenDragEnded(value)
            return
        }

        // クリック判定（ドラッグなしで終了）
        if !isDraggingLayer && activeHandle == nil && !isPanning {
            // 何もドラッグしていない場合はクリック → 選択 or 選択解除
        }

        // インタラクションモード終了 → デバウンスモードに復帰
        let wasInteracting = isDraggingLayer || activeHandle != nil || isPanning
        isDraggingLayer = false
        activeHandle = nil
        isPanning = false
        dragVelocity = .zero

        if wasInteracting {
            editorManager.isInteracting = false
            editorManager.finalizeTransformInteraction()
        }
    }

    /// ビューポート（パン・ズーム）操作開始／継続時に呼び出して、高FPSレンダリングモードを一時的に有効化する
    private func beginViewportInteraction() {
        if !isViewportInteracting {
            isViewportInteracting = true
            editorManager.isInteracting = true
        }

        viewportInteractionWorkItem?.cancel()
        let work = DispatchWorkItem {
            // ビューポート操作が一定時間途切れたら通常モードに戻す
            isViewportInteracting = false
            editorManager.isInteracting = false
            editorManager.requestRender()
        }
        viewportInteractionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: - レイヤー移動

    private func performMove(value: DragGesture.Value) {
        guard let layer = editorManager.selectedLayer else { return }

        // 速度予測：現在位置に速度ベクトルを加算して「先読み」位置を計算
        // 入力レイテンシを補償し、体感的な追従性を向上させる
        let predictedScreenPoint = CGPoint(
            x: value.location.x + dragVelocity.x * predictionFactor,
            y: value.location.y + dragVelocity.y * predictionFactor
        )

        let currentCanvasPoint = viewport.screenToCanvas(predictedScreenPoint)
        let deltaX = Float(currentCanvasPoint.x - dragStartCanvasPoint.x)
        let deltaY = Float(currentCanvasPoint.y - dragStartCanvasPoint.y)

        var newTransform = dragStartTransform
        newTransform.offsetX = dragStartTransform.offsetX + deltaX
        newTransform.offsetY = dragStartTransform.offsetY + deltaY

        editorManager.setLayerTransform(layer.id, transform: newTransform)
    }

    // MARK: - レイヤーリサイズ

    private func performResize(value: DragGesture.Value, handle: CanvasHitTester.HandlePosition) {
        guard let layer = editorManager.selectedLayer else { return }

        // リサイズにも速度予測を適用
        let predictedScreenPoint = CGPoint(
            x: value.location.x + dragVelocity.x * predictionFactor,
            y: value.location.y + dragVelocity.y * predictionFactor
        )

        let currentCanvasPoint = viewport.screenToCanvas(predictedScreenPoint)
        let deltaX = Float(currentCanvasPoint.x - dragStartCanvasPoint.x)
        let deltaY = Float(currentCanvasPoint.y - dragStartCanvasPoint.y)

        // ドラッグ開始時に確定した1倍あたりの基本サイズを使用（ドラッグ中に変動しない）
        let baseW = Float(dragStartBaseSize.width)
        let baseH = Float(dragStartBaseSize.height)
        guard baseW > 0, baseH > 0 else { return }

        var newTransform = dragStartTransform

        // 対角固定リサイズ：操作中のハンドルの対角にある点を不動にする
        // スケール変更後、対角の点が同じキャンバス座標に留まるようオフセットを補正

        // X方向のリサイズ
        switch handle {
        case .topLeft, .bottomLeft, .middleLeft:
            // 左ハンドル → 右辺を固定
            let newScaleX = max(0.01, dragStartTransform.scaleX - deltaX / baseW)
            let oldHalfW = baseW * dragStartTransform.scaleX / 2
            let newHalfW = baseW * newScaleX / 2
            // 右辺固定: center + oldHalfW == newCenter + newHalfW
            newTransform.scaleX = newScaleX
            newTransform.offsetX = dragStartTransform.offsetX + (oldHalfW - newHalfW)
        case .topRight, .bottomRight, .middleRight:
            // 右ハンドル → 左辺を固定
            let newScaleX = max(0.01, dragStartTransform.scaleX + deltaX / baseW)
            let oldHalfW = baseW * dragStartTransform.scaleX / 2
            let newHalfW = baseW * newScaleX / 2
            // 左辺固定: center - oldHalfW == newCenter - newHalfW
            newTransform.scaleX = newScaleX
            newTransform.offsetX = dragStartTransform.offsetX - (oldHalfW - newHalfW)
        default:
            break
        }

        // Y方向のリサイズ
        switch handle {
        case .topLeft, .topCenter, .topRight:
            // 上ハンドル → 下辺を固定
            let newScaleY = max(0.01, dragStartTransform.scaleY - deltaY / baseH)
            let oldHalfH = baseH * dragStartTransform.scaleY / 2
            let newHalfH = baseH * newScaleY / 2
            // 下辺固定: center + oldHalfH == newCenter + newHalfH
            newTransform.scaleY = newScaleY
            newTransform.offsetY = dragStartTransform.offsetY + (oldHalfH - newHalfH)
        case .bottomLeft, .bottomCenter, .bottomRight:
            // 下ハンドル → 上辺を固定
            let newScaleY = max(0.01, dragStartTransform.scaleY + deltaY / baseH)
            let oldHalfH = baseH * dragStartTransform.scaleY / 2
            let newHalfH = baseH * newScaleY / 2
            // 上辺固定: center - oldHalfH == newCenter - newHalfH
            newTransform.scaleY = newScaleY
            newTransform.offsetY = dragStartTransform.offsetY - (oldHalfH - newHalfH)
        default:
            break
        }

        editorManager.setLayerTransform(layer.id, transform: newTransform)
    }

    // MARK: - 選択ブラシ表示

    private func brushMarkerOverlay(points: [CGPoint], brushRadius: CGFloat) -> some View {
        return Canvas { context, _ in
            guard points.count >= 1 else { return }

            var p = Path()
            p.move(to: viewport.canvasToScreen(points[0]))
            if points.count >= 2 {
                for pt in points.dropFirst() {
                    p.addLine(to: viewport.canvasToScreen(pt))
                }
            }

            let strokeWidth = max(1.0, brushRadius * viewport.totalScale * 2.0)
            // なぞり中は酔いを避けるため、単色マーカーのみ表示する
            context.stroke(
                p,
                with: .color(Color.white.opacity(0.35)),
                style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private func brushTraceOverlay(points: [CGPoint], brushRadius: CGFloat) -> some View {
        return Canvas { context, _ in
            guard points.count >= 1 else { return }

            var p = Path()
            p.move(to: viewport.canvasToScreen(points[0]))
            if points.count >= 2 {
                for pt in points.dropFirst() {
                    p.addLine(to: viewport.canvasToScreen(pt))
                }
            }

            let strokeWidth = max(1.0, brushRadius * viewport.totalScale * 2.0)
            // なぞった「太さ」から境界ラインを作る
            let outline = p.strokedPath(
                StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
            )

            // marching ants（白のみ）
            let dash: [CGFloat] = [6, 6]
            context.stroke(
                outline,
                with: .color(Color.white),
                style: StrokeStyle(lineWidth: 1.2, lineCap: .butt, lineJoin: .round, dash: dash, dashPhase: marchingAntsPhase)
            )
        }
    }

    // MARK: - ベクターペン（Photoshop 風）

    private func resetVectorPenGesture() {
        vectorPenGestureActive = false
        vectorPenDidDrag = false
        vectorPenStartScreen = .zero
        vectorPenCurrentScreen = .zero
        pathSelectDragging = false
        pathSelectLastCanvas = .zero
        directSelectAnchorIndex = nil
    }

    private func handlePathSelectDragChanged(_ value: DragGesture.Value) {
        let hitR = max(4, viewport.screenLengthToCanvas(10))
        let startCanvas = viewport.screenToCanvas(value.startLocation)
        let curCanvas = viewport.screenToCanvas(value.location)
        let dist = hypot(
            value.location.x - value.startLocation.x,
            value.location.y - value.startLocation.y
        )

        if !pathSelectDragging {
            if dist < minDragDistance { return }
            let path = editorManager.selection.penPath
            guard !path.points.isEmpty else { return }
            let hit = path.points.contains {
                hypot($0.point.x - startCanvas.x, $0.point.y - startCanvas.y) <= hitR
            }
            guard hit else { return }
            pathSelectDragging = true
            pathSelectLastCanvas = startCanvas
            editorManager.isInteracting = true
        }

        if pathSelectDragging {
            let d = CGSize(
                width: curCanvas.x - pathSelectLastCanvas.x,
                height: curCanvas.y - pathSelectLastCanvas.y
            )
            if abs(d.width) > 0.001 || abs(d.height) > 0.001 {
                editorManager.translatePenPath(by: d)
                pathSelectLastCanvas = curCanvas
            }
        }
    }

    private func handleDirectSelectDragChanged(_ value: DragGesture.Value) {
        let hitR = max(4, viewport.screenLengthToCanvas(10))
        let startCanvas = viewport.screenToCanvas(value.startLocation)
        let curCanvas = viewport.screenToCanvas(value.location)
        let dist = hypot(
            value.location.x - value.startLocation.x,
            value.location.y - value.startLocation.y
        )

        if directSelectAnchorIndex == nil {
            if dist < minDragDistance { return }
            if let i = editorManager.hitTestPenAnchorIndex(at: startCanvas, radius: hitR) {
                directSelectAnchorIndex = i
                editorManager.isInteracting = true
            } else {
                return
            }
        }

        if let idx = directSelectAnchorIndex {
            editorManager.setPenAnchorCanvasPosition(at: idx, point: curCanvas)
        }
    }

    private func handleVectorPenDragChanged(_ value: DragGesture.Value) {
        switch editorManager.penToolKind {
        case .standard, .curvature, .polygonal:
            if !vectorPenGestureActive {
                vectorPenGestureActive = true
                vectorPenStartScreen = value.startLocation
            }
            vectorPenCurrentScreen = value.location
            let dist = hypot(
                value.location.x - value.startLocation.x,
                value.location.y - value.startLocation.y
            )
            if dist >= minDragDistance {
                vectorPenDidDrag = true
            }
        case .freeform, .magneticPen, .addAnchor, .deleteAnchor, .convertPoint, .pathSelect, .directSelect:
            break
        }
    }

    private func handleVectorPenDragEnded(_ value: DragGesture.Value) {
        defer { resetVectorPenGesture() }

        let startCanvas = viewport.screenToCanvas(value.startLocation)
        let endCanvas = viewport.screenToCanvas(value.location)
        let hitR = max(4, viewport.screenLengthToCanvas(10))
        let didDrag = hypot(
            value.location.x - value.startLocation.x,
            value.location.y - value.startLocation.y
        ) >= minDragDistance

        switch editorManager.penToolKind {
        case .standard, .curvature:
            if editorManager.tryClosePenPath(near: endCanvas, hitRadiusCanvas: hitR) { return }
            if editorManager.tryClosePenPath(near: startCanvas, hitRadiusCanvas: hitR) { return }

            if didDrag {
                if editorManager.selection.penPath.points.isEmpty {
                    editorManager.appendPenAnchor(at: startCanvas, isCorner: true, outHandleOffset: nil)
                } else {
                    editorManager.appendPenAnchor(
                        at: startCanvas,
                        isCorner: false,
                        outHandleOffset: CGPoint(x: endCanvas.x - startCanvas.x, y: endCanvas.y - startCanvas.y)
                    )
                }
            } else {
                if editorManager.penToolKind == .standard {
                    editorManager.appendPenAnchor(at: startCanvas, isCorner: true, outHandleOffset: nil)
                } else {
                    editorManager.appendCurvaturePenAnchorClick(at: startCanvas)
                }
            }

        case .polygonal:
            if editorManager.tryClosePenPath(near: endCanvas, hitRadiusCanvas: hitR) { return }
            if editorManager.tryClosePenPath(near: startCanvas, hitRadiusCanvas: hitR) { return }

            if didDrag {
                if editorManager.selection.penPath.points.isEmpty {
                    editorManager.appendPenAnchor(at: startCanvas, isCorner: true, outHandleOffset: nil)
                    editorManager.appendPenAnchor(at: endCanvas, isCorner: true, outHandleOffset: nil)
                } else {
                    editorManager.appendPenAnchor(at: endCanvas, isCorner: true, outHandleOffset: nil)
                }
            } else {
                editorManager.appendPenAnchor(at: startCanvas, isCorner: true, outHandleOffset: nil)
            }

        case .addAnchor:
            _ = editorManager.insertPenAnchorOnNearestSegment(at: endCanvas, maxDistance: hitR * 2.5)

        case .deleteAnchor:
            if let i = editorManager.hitTestPenAnchorIndex(at: endCanvas, radius: hitR) {
                editorManager.removePenAnchor(at: i)
            }

        case .convertPoint:
            if let i = editorManager.hitTestPenAnchorIndex(at: endCanvas, radius: hitR) {
                editorManager.togglePenAnchorCorner(at: i)
            }

        case .freeform, .magneticPen, .pathSelect, .directSelect:
            break
        }
    }

    /// 画面座標系のプレビューパス（ベジェを折線で近似）
    private func vectorPenBezierScreenPath(penPath: PenPath, closing: Bool) -> Path {
        var p = Path()
        guard penPath.points.count >= 1 else { return p }
        if penPath.points.count == 1 {
            let s = viewport.canvasToScreen(penPath.points[0].point)
            p.addEllipse(in: CGRect(x: s.x - 3.5, y: s.y - 3.5, width: 7, height: 7))
            return p
        }
        let count = penPath.points.count
        let segmentCount = closing ? count : max(0, count - 1)
        guard segmentCount > 0 else { return p }
        let steps = 20
        for seg in 0..<segmentCount {
            let i = seg % count
            let j = (seg + 1) % count
            let p0 = penPath.points[i]
            let p1 = penPath.points[j]
            for k in 0...steps {
                let t = CGFloat(k) / CGFloat(steps)
                let cpt = PenPath.pointOnSegment(from: p0, to: p1, t: t)
                let sp = viewport.canvasToScreen(cpt)
                if k == 0, seg == 0 {
                    p.move(to: sp)
                } else {
                    p.addLine(to: sp)
                }
            }
        }
        return p
    }

    private func vectorPenEditOverlay() -> some View {
        let penPath = editorManager.selection.penPath
        let showRubber = vectorPenGestureActive
            && (editorManager.penToolKind == .standard
                || editorManager.penToolKind == .curvature
                || editorManager.penToolKind == .polygonal)

        return Canvas { context, _ in
            let pathShape = vectorPenBezierScreenPath(penPath: penPath, closing: penPath.isClosed)
            if penPath.isClosed, penPath.points.count >= 2 {
                let dash: [CGFloat] = [6, 6]
                context.stroke(
                    pathShape,
                    with: .color(Color.white),
                    style: StrokeStyle(
                        lineWidth: 1.2,
                        lineCap: .butt,
                        lineJoin: .round,
                        dash: dash,
                        dashPhase: marchingAntsPhase
                    )
                )
            } else if penPath.points.count >= 2 {
                context.stroke(
                    pathShape,
                    with: .color(Color.white.opacity(0.92)),
                    style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round)
                )
            } else if penPath.points.count == 1 {
                context.stroke(
                    pathShape,
                    with: .color(Color.white.opacity(0.85)),
                    style: StrokeStyle(lineWidth: 1)
                )
            }

            for anchor in penPath.points {
                let s = viewport.canvasToScreen(anchor.point)
                let r: CGFloat = anchor.isCorner ? 4 : 3.5
                let rect = CGRect(x: s.x - r, y: s.y - r, width: r * 2, height: r * 2)
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(Color(white: 0.25))
                )
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(Color.white),
                    style: StrokeStyle(lineWidth: 1)
                )

                if !anchor.isCorner, let off = anchor.outHandleOffset {
                    let h = CGPoint(x: anchor.point.x + off.x, y: anchor.point.y + off.y)
                    let hs = viewport.canvasToScreen(h)
                    var hLine = Path()
                    hLine.move(to: s)
                    hLine.addLine(to: hs)
                    context.stroke(hLine, with: .color(Color.cyan.opacity(0.65)), style: StrokeStyle(lineWidth: 0.8))
                    context.fill(
                        Path(ellipseIn: CGRect(x: hs.x - 2.5, y: hs.y - 2.5, width: 5, height: 5)),
                        with: .color(Color.cyan.opacity(0.9))
                    )
                }
            }

            if showRubber {
                var rb = Path()
                rb.move(to: vectorPenStartScreen)
                rb.addLine(to: vectorPenCurrentScreen)
                context.stroke(
                    rb,
                    with: .color(Color.white.opacity(0.45)),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
            }
        }
    }

    // MARK: - Phase 1.3+: BrushEngine 連携ヘルパ

    /// 直前の NSEvent サイドチャネル値と前回サンプルから BrushInputSample を組み立てる。
    private func makeBrushInputSample(at canvasPoint: CGPoint) -> BrushInputSample {
        let now = CACurrentMediaTime()
        let velocity: CGVector
        if let prev = lastBrushInputSample {
            let dt = max(now - prev.timestamp, 0.001)
            velocity = CGVector(
                dx: (canvasPoint.x - prev.position.x) / CGFloat(dt),
                dy: (canvasPoint.y - prev.position.y) / CGFloat(dt)
            )
        } else {
            velocity = .zero
        }
        let sample = BrushInputSample(
            position: canvasPoint,
            pressure: max(0.0, min(1.0, lastNSEventPressure)),
            tiltDegrees: lastNSEventTiltDegrees,
            azimuthDegrees: lastNSEventAzimuthDegrees,
            velocity: velocity,
            timestamp: now
        )
        lastBrushInputSample = sample
        return sample
    }

    /// ストローク開始: 現在の penToolKind から Engine を解決し、Context を初期化。
    private func beginBrushEngineStroke(at sample: BrushInputSample) {
        let engineID = editorManager.penToolKind.brushEngineID ?? .circle
        let engine = BrushEngineRegistry.shared.engineOrFallback(for: engineID)
        var context = BrushStrokeContext(
            stroke: activeBrushStrokeSnapshot ?? editorManager.toolSettings.stroke,
            post: activeMaskPostSnapshot ?? editorManager.toolSettings.maskPost,
            gradient: activeGradientSnapshot ?? editorManager.toolSettings.gradient,
            combine: activeMaskCombineSnapshot ?? editorManager.toolSettings.maskCombine,
            canvas: editorManager.project.canvasSize
        )
        _ = engine.beginStroke(context: &context, sample: sample)
        activeBrushEngine = engine
        activeBrushEngineContext = context
    }

    /// ストローク継続: Engine に追加サンプルを流し込む。
    private func continueBrushEngineStroke(with sample: BrushInputSample) {
        guard let engine = activeBrushEngine,
              var context = activeBrushEngineContext else { return }
        _ = engine.continueStroke(context: &context, sample: sample)
        activeBrushEngineContext = context
    }

    /// ストローク終了: Engine を確定させ Context を破棄。
    private func endBrushEngineStroke(with sample: BrushInputSample) {
        if let engine = activeBrushEngine,
           var context = activeBrushEngineContext {
            _ = engine.endStroke(context: &context, sample: sample)
            // Phase 1.4 で engine.commit(context:into:) によりラスタ化に渡す予定。
        }
        activeBrushEngine = nil
        activeBrushEngineContext = nil
        lastBrushInputSample = nil
    }

    /// 右クリックなどでストロークを破棄する場合のクリーンアップ。
    private func cancelBrushEngineStroke() {
        activeBrushEngine = nil
        activeBrushEngineContext = nil
        lastBrushInputSample = nil
    }

    // 指を離したタイミングでのみ輪郭を軽量に整形（近接点統合 + RDP）
    private func finalizeBrushOutlinePoints(_ points: [CGPoint], brushRadius: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let nearDistance = max(1.0, brushRadius * 0.35)
        let reduced = mergeNearbyPoints(points, minDistance: nearDistance)
        guard reduced.count > 2 else { return reduced }
        // 短いストロークで RDP すると境界が大きく変わり「あとから動いた」ように見えるためスキップ
        if reduced.count <= 24 {
            return reduced
        }
        let epsilon = max(0.8, brushRadius * 0.45)
        let simplified = simplifyPathRDP(reduced, epsilon: epsilon)
        return simplified.count >= 2 ? simplified : reduced
    }

    private func mergeNearbyPoints(_ points: [CGPoint], minDistance: CGFloat) -> [CGPoint] {
        guard let first = points.first else { return [] }
        var merged: [CGPoint] = [first]
        var last = first
        for p in points.dropFirst() {
            if hypot(p.x - last.x, p.y - last.y) >= minDistance {
                merged.append(p)
                last = p
            }
        }
        if let lastOriginal = points.last, let lastMerged = merged.last,
           hypot(lastOriginal.x - lastMerged.x, lastOriginal.y - lastMerged.y) > 0.01 {
            merged.append(lastOriginal)
        }
        return merged
    }

    private func simplifyPathRDP(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var maxDistance: CGFloat = 0
        var index = 0
        let start = points[0]
        let end = points[points.count - 1]
        for i in 1..<(points.count - 1) {
            let d = perpendicularDistance(points[i], lineStart: start, lineEnd: end)
            if d > maxDistance {
                maxDistance = d
                index = i
            }
        }
        if maxDistance > epsilon {
            let left = simplifyPathRDP(Array(points[0...index]), epsilon: epsilon)
            let right = simplifyPathRDP(Array(points[index...]), epsilon: epsilon)
            return Array(left.dropLast()) + right
        }
        return [start, end]
    }

    private func perpendicularDistance(_ point: CGPoint, lineStart: CGPoint, lineEnd: CGPoint) -> CGFloat {
        let dx = lineEnd.x - lineStart.x
        let dy = lineEnd.y - lineStart.y
        let len = hypot(dx, dy)
        guard len > 0.0001 else {
            return hypot(point.x - lineStart.x, point.y - lineStart.y)
        }
        let num = abs(dy * point.x - dx * point.y + lineEnd.x * lineStart.y - lineEnd.y * lineStart.x)
        return num / len
    }

    private func startMarchingAnts() {
        stopMarchingAnts()
        marchingAntsTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            marchingAntsPhase += 1.5
        }
    }

    private func stopMarchingAnts() {
        marchingAntsTimer?.invalidate()
        marchingAntsTimer = nil
    }

    private func dragStartLocationSafeFallback() -> CGPoint {
        // DragGesture.onEnded には value が来ないので、直前の mouse location を使うのが理想だが、
        // MVPでは startLocation を持っていない場合があるため、現在のNSWindow座標から取得できる時はそれを使う。
        if let window = canvasNSView?.window {
            let loc = window.mouseLocationOutsideOfEventStream
            let viewLoc = canvasNSView?.convert(loc, from: nil) ?? loc
            let flippedY = (canvasNSView?.bounds.height ?? 0) - viewLoc.y
            return CGPoint(x: viewLoc.x, y: flippedY)
        }
        return .zero
    }

    // MARK: - NSEventモニター

    private func setupEventMonitors() {
        // スペースキー押下検出（パンモード用）
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 49 && !event.isARepeat {
                DispatchQueue.main.async {
                    isSpaceHeld = true
                }
            }

            // ベクターペン: Esc でパス破棄、Return で閉じて選択化
            if !event.isARepeat, editorManager.currentTool == .pen, !editorManager.penToolKind.isFreeformBrushLike {
                if event.keyCode == 53 {
                    DispatchQueue.main.async {
                        resetVectorPenGesture()
                        editorManager.clearVectorPenState()
                    }
                } else if event.keyCode == 36 || event.keyCode == 76 {
                    // Return / テンキー Enter でパスを閉じる
                    DispatchQueue.main.async {
                        editorManager.closePenPathIfPossible()
                    }
                } else if event.keyCode == 51 || event.keyCode == 117 {
                    // Delete / Forward Delete で最終アンカーを戻す
                    DispatchQueue.main.async {
                        editorManager.removeLastPenAnchorIfOpenPath()
                    }
                }
            }

            // ツールショートカット（MVP）
            if !event.isARepeat {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "v":
                    DispatchQueue.main.async { editorManager.currentTool = .move }
                case "p":
                    DispatchQueue.main.async { editorManager.currentTool = .pen }
                default:
                    break
                }
            }

            // 選択→レイヤー化（MVP）
            if event.modifierFlags.contains(.command), !event.isARepeat {
                // Cmd+J / Shift+Cmd+J
                if event.charactersIgnoringModifiers == "j" || event.charactersIgnoringModifiers == "J" {
                    if event.modifierFlags.contains(.shift) {
                        DispatchQueue.main.async { editorManager.layerViaCutFromSelection() }
                    } else {
                        DispatchQueue.main.async { editorManager.layerViaCopyFromSelection() }
                    }
                }
                // Cmd+D（選択解除）
                if event.charactersIgnoringModifiers == "d" || event.charactersIgnoringModifiers == "D" {
                    DispatchQueue.main.async { editorManager.clearSelection() }
                }
            }
            return event
        }

        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
            if event.keyCode == 49 {
                DispatchQueue.main.async {
                    isSpaceHeld = false
                    isPanning = false
                }
            }
            return event
        }

        // 2本指トラックパッドスクロールでパン（キャンバス移動）
        // ズームはピンチジェスチャー（magnify）のみで行う
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [self] event in
            guard isWindowActive else { return event }
            guard isEventOverCanvasView(event: event) else { return event }

            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            guard abs(dx) > 0.01 || abs(dy) > 0.01 else { return event }

            DispatchQueue.main.async {
                beginViewportInteraction()
                viewport.panOffset = CGPoint(
                    x: viewport.panOffset.x + dx,
                    y: viewport.panOffset.y + dy
                )
            }

            return event
        }

        // トラックパッドのピンチジェスチャーでズーム（カーソル中心）
        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [self] event in
            guard isWindowActive else { return event }
            guard isEventOverCanvasView(event: event) else { return event }

            let zoomFactor: CGFloat = 1.0 + event.magnification

            if let localPoint = cursorPointInCanvasView(event: event) {
                DispatchQueue.main.async {
                    beginViewportInteraction()
                    viewport.zoomBy(zoomFactor, center: localPoint)
                }
            }

            return event
        }

        // Phase 1.3+: ブラシストローク中の NSEvent から圧力／傾きをサイドチャネルで取得。
        // Why: SwiftUI の DragGesture.Value には pressure / tilt が含まれないため、
        // mouseDragged の NSEvent をローカルモニタで覗いて lastNSEvent* に保持し、
        // 直後の handleDragChanged が組み立てる BrushInputSample に反映する。
        brushPressureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseDown]) { [self] event in
            guard isWindowActive else { return event }
            guard editorManager.currentTool == .pen,
                  editorManager.penToolKind.brushEngineID != nil else { return event }
            // NSEvent.pressure は 0..1 (タブレット非対応マウスでも 1.0 が入る)
            lastNSEventPressure = CGFloat(event.pressure)
            if event.subtype == .tabletPoint {
                let tx = CGFloat(event.tilt.x)
                let ty = CGFloat(event.tilt.y)
                let mag = sqrt(tx * tx + ty * ty)
                lastNSEventTiltDegrees = min(1.0, mag) * 90.0
                lastNSEventAzimuthDegrees = atan2(ty, tx) * 180.0 / .pi
            } else {
                lastNSEventTiltDegrees = 0
                lastNSEventAzimuthDegrees = 0
            }
            return event  // event 自体は SwiftUI に流して DragGesture を壊さない
        }

        // 自由ペン: 右クリックで選択のみ解除（マスクモード・リセット・Cmd+D と同系）
        rightMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [self] event in
            guard isWindowActive else { return event }
            guard isEventOverCanvasView(event: event) else { return event }
            guard editorManager.currentTool == .pen,
                  editorManager.penToolKind.brushEngineID != nil else { return event }
            DispatchQueue.main.async {
                isTracingSelectionBrush = false
                liveFreeformBrushTrace = []
                finalizedBrushOutlinePoints = []
                activeBrushStrokeSnapshot = nil
                cancelBrushEngineStroke()
                activeMaskPostSnapshot = nil
                activeGradientSnapshot = nil
                activeMaskCombineSnapshot = nil
                activeBrushRadiusSnapshot = nil
                editorManager.clearSelection()
            }
            return nil
        }

        // ウィンドウ非アクティブ監視：他のウィンドウが前面に来たらズーム等を停止
        windowDidResignMonitor = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignMainNotification,
            object: nil,
            queue: .main
        ) { [self] notification in
            guard let window = notification.object as? NSWindow,
                  window == canvasNSView?.window else { return }
            isWindowActive = false
            // スペースキー等のモード状態もリセット
            isSpaceHeld = false
            isPanning = false
        }

        windowDidBecomeMonitor = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [self] notification in
            guard let window = notification.object as? NSWindow,
                  window == canvasNSView?.window else { return }
            isWindowActive = true
        }
    }

    /// イベントがキャンバスのウィンドウで発生したかを判定する
    /// ファイル追加ダイアログ等のモーダルウィンドウやシートのイベントを除外
    private func isEventInCanvasWindow(event: NSEvent) -> Bool {
        guard let eventWindow = event.window,
              let canvasWindow = canvasNSView?.window else { return false }
        return eventWindow === canvasWindow
    }

    /// イベントのカーソル位置がキャンバスビューの領域内かを判定する
    /// プロパティパネルやレイヤーパネル上のスクロール/ズームを除外
    private func isEventOverCanvasView(event: NSEvent) -> Bool {
        guard isEventInCanvasWindow(event: event),
              let nsView = canvasNSView else { return false }
        let viewLocation = nsView.convert(event.locationInWindow, from: nil)
        return nsView.bounds.contains(viewLocation)
    }

    /// NSEventのウィンドウ座標をキャンバスビューのローカル座標に変換する
    private func cursorPointInCanvasView(event: NSEvent) -> CGPoint? {
        guard let nsView = canvasNSView else {
            // フォールバック: contentViewからの変換
            guard let window = event.window,
                  let contentView = window.contentView else { return nil }
            let viewLocation = contentView.convert(event.locationInWindow, from: nil)
            let flippedY = contentView.bounds.height - viewLocation.y
            return CGPoint(x: viewLocation.x, y: flippedY)
        }

        // キャンバスビューのローカル座標に正確に変換
        let viewLocation = nsView.convert(event.locationInWindow, from: nil)
        // AppKit座標系（Y上向き）→ SwiftUI座標系（Y下向き）に反転
        let flippedY = nsView.bounds.height - viewLocation.y
        return CGPoint(x: viewLocation.x, y: flippedY)
    }

    private func removeEventMonitors() {
        if let monitor = keyDownMonitor {
            NSEvent.removeMonitor(monitor)
            keyDownMonitor = nil
        }
        if let monitor = keyUpMonitor {
            NSEvent.removeMonitor(monitor)
            keyUpMonitor = nil
        }
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
        if let monitor = magnifyMonitor {
            NSEvent.removeMonitor(monitor)
            magnifyMonitor = nil
        }
        if let monitor = rightMouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            rightMouseDownMonitor = nil
        }
        if let monitor = brushPressureMonitor {
            NSEvent.removeMonitor(monitor)
            brushPressureMonitor = nil
        }
        if let observer = windowDidResignMonitor {
            NotificationCenter.default.removeObserver(observer)
            windowDidResignMonitor = nil
        }
        if let observer = windowDidBecomeMonitor {
            NotificationCenter.default.removeObserver(observer)
            windowDidBecomeMonitor = nil
        }
    }
}

// MARK: - 水流ブラシハンドラ

extension CanvasInteractionOverlay {
    /// ドラッグ中: 水流ブラシのストロークをサンプリングし、FlowBrushManager 経由で Rust へ反映する
    fileprivate func handleFlowBrushDragChanged(_ value: DragGesture.Value) {
        // 対象レイヤー（選択中レイヤーの Rust ID）
        guard let layer = editorManager.selectedLayer,
              let rustId = layer.rustLayerID else {
            return
        }

        // スクリーン座標 → キャンバス座標 → レイヤー座標
        // 簡易実装: レイヤーがキャンバス原点に等倍配置されている前提
        // （回転/スケールがある場合は editor_transform の逆変換を考慮する必要があるが、MVPでは未対応）
        let canvasPoint = viewport.screenToCanvas(value.location)
        let layerPoint = canvasPoint

        if !isFlowBrushStroking {
            isFlowBrushStroking = true
            activeFlowBrushLayerId = rustId
            lastFlowBrushCanvasPoint = nil
            FlowBrushManager.shared.beginStroke(layerId: rustId)
        }

        // 過密サンプリング抑制: 直前点との距離がスクリーン上 2.5px 以下なら間引く
        if let last = lastFlowBrushCanvasPoint {
            let minDist = viewport.screenLengthToCanvas(2.5)
            if hypot(layerPoint.x - last.x, layerPoint.y - last.y) < minDist {
                return
            }
        }
        lastFlowBrushCanvasPoint = layerPoint
        FlowBrushManager.shared.addPoint(layerPoint)
    }

    /// ドラッグ終了: ストロークをフラッシュし、フロー有効化する
    fileprivate func handleFlowBrushDragEnded(_ value: DragGesture.Value) {
        guard isFlowBrushStroking else { return }
        FlowBrushManager.shared.endStroke()
        isFlowBrushStroking = false
        activeFlowBrushLayerId = nil
        lastFlowBrushCanvasPoint = nil
    }
}

// MARK: - NSView参照取得ヘルパー

/// SwiftUIビュー階層から対応するNSViewの参照を取得する
struct CanvasNSViewFinder: NSViewRepresentable {
    @Binding var nsView: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            self.nsView = view
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
