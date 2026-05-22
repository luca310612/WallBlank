import SwiftUI
import MetalKit

/// 中央パネル：Metalプレビューキャンバス（ビューポート制御付き）
/// WGPUエンジンがウィンドウ全体を描画する（背景・チェッカーボード・レイヤー全てRust側）
struct EditorCanvasView: View {
    @ObservedObject var editorManager: ImageEditorManager
    @StateObject private var viewport = CanvasViewport()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // WGPUエンジンがビュー全体を描画（背景・チェッカーボード・レイヤー）
                if editorManager.wgpuEngine != nil || editorManager.renderer != nil {
                    MetalCanvasRepresentable(
                        editorManager: editorManager,
                        viewport: viewport,
                        renderVersion: editorManager.renderVersion
                    )
                } else {
                    Color(nsColor: NSColor(white: 0.2, alpha: 1.0))
                    Text("描画エンジンを初期化できません")
                        .foregroundColor(.secondary)
                }

                // インタラクションオーバーレイ（選択枠・ハンドル・ジェスチャー）
                CanvasInteractionOverlay(
                    editorManager: editorManager,
                    viewport: viewport
                )

                // ズーム率・サイズ表示バッジ（右下）
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        zoomBadge
                            .padding(8)
                    }
                }
            }
            .onAppear {
                // エディタ使用中は壁紙エンジンを一時停止してGPUリソースを優先的に割り当てる
                if let appDelegate = NSApp.delegate as? AppDelegate {
                    appDelegate.wallpaperEngine?.pauseAll()
                }

                editorManager.setEditorCanvasVisible(true)
                viewport.viewSize = geometry.size
                viewport.updateCanvasSize(
                    width: CGFloat(editorManager.project.canvasWidth),
                    height: CGFloat(editorManager.project.canvasHeight)
                )
                viewport.fitToView()
                // 初期ビューポートパラメータをRust側に同期
                syncViewportToRust(viewSize: geometry.size)
            }
            .onDisappear {
                // エディタを閉じたら壁紙エンジンを再開
                if let appDelegate = NSApp.delegate as? AppDelegate {
                    appDelegate.wallpaperEngine?.resumeAll()
                }

                editorManager.setEditorCanvasVisible(false)
            }
            .onChange(of: geometry.size) { _, newSize in
                viewport.viewSize = newSize
                // ビューサイズ変更時にビューポートパラメータを再同期
                syncViewportToRust(viewSize: newSize)
            }
            .onChange(of: viewport.zoomLevel) { _, _ in
                syncViewportParamsToRust()
            }
            .onChange(of: viewport.panOffset) { _, _ in
                syncViewportParamsToRust()
            }
            .onChange(of: editorManager.lastWakeTrigger) { _, _ in
                // スリープ復帰後：レイアウト・解像度が安定するまで待ってからビューポート再同期
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    syncViewportToRust(viewSize: viewport.viewSize)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - ビューポート同期

    /// ビューポート全体をRust側に同期（サイズ + パラメータ + 再描画）
    private func syncViewportToRust(viewSize: CGSize) {
        // RetinaスケールファクターでPoints→Pixelsに変換
        let scaleFactor = NSScreen.main?.backingScaleFactor ?? 2.0
        let pixelWidth = viewSize.width * scaleFactor
        let pixelHeight = viewSize.height * scaleFactor
        editorManager.updateViewportSize(width: pixelWidth, height: pixelHeight)
        editorManager.updateViewportParams(from: viewport, scaleFactor: scaleFactor)
        editorManager.requestRender()
    }

    /// ビューポートパラメータのみRust側に同期 + 再描画
    private func syncViewportParamsToRust() {
        let scaleFactor = NSScreen.main?.backingScaleFactor ?? 2.0
        editorManager.updateViewportParams(from: viewport, scaleFactor: scaleFactor)
        editorManager.requestRender()
    }

    // MARK: - ズームバッジ

    private var zoomBadge: some View {
        HStack(spacing: 8) {
            // フィットボタン
            Button(action: { viewport.fitToView() }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("ビューにフィット")

            // 100%ボタン
            Button(action: { viewport.zoom100Percent() }) {
                Text("1:1")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
            }
            .buttonStyle(.plain)
            .help("100%表示")

            // ズーム率表示
            Text("\(viewport.zoomPercent)%")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)

            // キャンバスサイズ表示
            Text("\(editorManager.project.canvasWidth) × \(editorManager.project.canvasHeight)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.6))
        .cornerRadius(4)
    }

    // MARK: - ドラッグ＆ドロップ

    /// ファイルのドラッグ＆ドロップ処理
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                let supportedExtensions = [
                    "png", "jpg", "jpeg", "heic", "tiff", "bmp",
                    "mp4", "mov", "m4v"
                ]
                if supportedExtensions.contains(url.pathExtension.lowercased()) {
                    DispatchQueue.main.async {
                        editorManager.addLayers(from: [url])
                    }
                }
            }
        }
        return true
    }
}

// MARK: - Metal キャンバス NSViewRepresentable

struct MetalCanvasRepresentable: NSViewRepresentable {
    @ObservedObject var editorManager: ImageEditorManager
    /// ビューポート状態（ズーム・パン同期用）
    @ObservedObject var viewport: CanvasViewport
    /// SwiftUIにレンダリング更新を認識させるための値（変更されるたびにupdateNSViewが呼ばれる）
    var renderVersion: UInt64

    func makeNSView(context: Context) -> MTKView {
        // WGPUエンジンのIOSurface表示用にMTLDeviceを取得
        let device: MTLDevice? = editorManager.renderer?.metalDevice ?? MTLCreateSystemDefaultDevice()

        guard let dev = device else {
            return MTKView()
        }

        let metalView = MTKView()
        metalView.device = dev
        metalView.colorPixelFormat = .bgra8Unorm
        // WGPUがビュー全体を描画するため不透明（背景色はRust側で描画）
        metalView.clearColor = MTLClearColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1.0)
        metalView.delegate = context.coordinator
        metalView.enableSetNeedsDisplay = true
        metalView.isPaused = true // 手動描画モード（インタラクション中は自動切替）
        metalView.preferredFramesPerSecond = 120 // リアルタイムモード時は高FPSで描画
        metalView.layer?.isOpaque = true

        // Coordinatorにビュー参照を保持（インタラクションモード切替用）
        context.coordinator.metalView = metalView

        // IOSurface表示用パイプラインを初期化
        context.coordinator.setupPipeline(device: dev)

        return metalView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        // インタラクション中はリアルタイムモード（isPaused=false）で自動描画
        // 非インタラクション時は手動描画モードに戻す
        let shouldBeRealtime = editorManager.isInteracting
        if nsView.isPaused == shouldBeRealtime {
            nsView.isPaused = !shouldBeRealtime
            nsView.enableSetNeedsDisplay = !shouldBeRealtime
        }

        if nsView.isPaused {
            // 手動モード時のみ明示的に描画要求
            nsView.setNeedsDisplay(nsView.bounds)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(editorManager: editorManager)
    }

    class Coordinator: NSObject, MTKViewDelegate {
        let editorManager: ImageEditorManager

        /// MTKViewへの弱参照（インタラクションモード切替用）
        weak var metalView: MTKView?

        /// IOSurfaceテクスチャ描画用パイプライン
        private var pipelineState: MTLRenderPipelineState?
        private var samplerState: MTLSamplerState?
        /// コマンドキューを再利用（毎フレーム生成しない）
        private var commandQueue: MTLCommandQueue?

        init(editorManager: ImageEditorManager) {
            self.editorManager = editorManager
        }

        /// IOSurfaceテクスチャ描画用のシンプルなパイプラインを作成
        func setupPipeline(device: MTLDevice) {
            // シンプルなフルスクリーンテクスチャ描画シェーダー
            let shaderSource = """
            #include <metal_stdlib>
            using namespace metal;

            struct VertexOut {
                float4 position [[position]];
                float2 uv;
            };

            vertex VertexOut iosurface_vertex(uint vid [[vertex_id]]) {
                // フルスクリーン三角形
                float2 positions[3] = {
                    float2(-1.0, -1.0),
                    float2( 3.0, -1.0),
                    float2(-1.0,  3.0)
                };
                VertexOut out;
                out.position = float4(positions[vid], 0.0, 1.0);
                out.uv = float2(
                    (positions[vid].x + 1.0) * 0.5,
                    1.0 - (positions[vid].y + 1.0) * 0.5
                );
                return out;
            }

            fragment float4 iosurface_fragment(
                VertexOut in [[stage_in]],
                texture2d<float> tex [[texture(0)]],
                sampler smp [[sampler(0)]]
            ) {
                // IOSurfaceテクスチャはbgra8Unormで作成済みのため変換不要
                return tex.sample(smp, in.uv);
            }
            """

            do {
                let library = try device.makeLibrary(source: shaderSource, options: nil)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "iosurface_vertex")
                descriptor.fragmentFunction = library.makeFunction(name: "iosurface_fragment")
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                // アルファブレンディングを有効化（透明部分を正しく表示するため）
                descriptor.colorAttachments[0].isBlendingEnabled = true
                descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
                descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                debugLog("[EditorCanvasView] IOSurfaceパイプライン作成失敗: \(error)")
            }

            // サンプラー作成
            let samplerDesc = MTLSamplerDescriptor()
            samplerDesc.minFilter = .linear
            samplerDesc.magFilter = .linear
            samplerState = device.makeSamplerState(descriptor: samplerDesc)

            // コマンドキューを事前作成（毎フレーム生成を回避）
            commandQueue = device.makeCommandQueue()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // ドローアブルサイズ変更時 → ビューポートサイズをRust側に通知
            guard size.width > 0 && size.height > 0 else { return }
            editorManager.updateViewportSize(width: size.width, height: size.height)
        }

        func draw(in view: MTKView) {
            // スリープ復帰後などで drawableSizeWillChange が不正値のままになる場合があるため、
            // 描画時に実際の drawableSize でビューポートを同期する（解像度ずれを防ぐ）
            let ds = view.drawableSize
            if ds.width >= 32 && ds.height >= 32 {
                let didUpdate = editorManager.updateViewportSize(width: ds.width, height: ds.height)
                // 解像度を直した直後はもう1フレーム描画して、最初の一瞬のバグを消す
                if didUpdate {
                    editorManager.requestRender()
                }
            }

            // インタラクション中はここで WGPU を毎フレーム同期レンダーし、枠・パンと画像のずれをなくす
            if editorManager.isInteracting, editorManager.wgpuEngine != nil {
                editorManager.renderLatestSync(bumpRenderVersion: false)
            }

            let hasIOTexture = editorManager.ioSurfaceTexture != nil
            let hasPipeline = pipelineState != nil
            let hasSampler = samplerState != nil
            let hasDrawable = view.currentDrawable != nil
            let hasPassDesc = view.currentRenderPassDescriptor != nil
            let hasQueue = commandQueue != nil

            // デバッグ: 描画条件を確認（頻繁に呼ばれるため初回のみ出力）
            struct DrawDebug { static var count = 0 }
            DrawDebug.count += 1
            if DrawDebug.count <= 5 || DrawDebug.count % 100 == 0 {
                debugLog("[EditorCanvas] draw呼び出し #\(DrawDebug.count): ioTex=\(hasIOTexture) pipe=\(hasPipeline) samp=\(hasSampler) draw=\(hasDrawable) pass=\(hasPassDesc) queue=\(hasQueue)")
                if let tex = editorManager.ioSurfaceTexture {
                    debugLog("[EditorCanvas]   IOSurfaceTexture: \(tex.width)x\(tex.height) format=\(tex.pixelFormat.rawValue)")
                }
            }

            // WGPUエンジンのIOSurfaceテクスチャが利用可能な場合はそれを表示
            if let ioTexture = editorManager.ioSurfaceTexture,
               let pipeline = pipelineState,
               let sampler = samplerState,
               let drawable = view.currentDrawable,
               let passDesc = view.currentRenderPassDescriptor,
               let commandBuffer = commandQueue?.makeCommandBuffer() {

                guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
                    return
                }

                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(ioTexture, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()

                commandBuffer.present(drawable)
                commandBuffer.commit()
                return
            }

            // フォールバック: 従来のEditorRendererで描画
            editorManager.renderer?.draw(in: view)
        }
    }
}

