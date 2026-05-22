import SwiftUI
import MetalKit

// MTKViewをSwiftUIで使うためのラッパー
struct MetalPreviewView: NSViewRepresentable {
    let renderer: Renderer
    let device: MTLDevice
    var cornerRadius: CGFloat = 12

    func makeNSView(context: Context) -> MTKView {
        let metalView = MTKView(frame: .zero, device: device)
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.preferredFramesPerSecond = 30  // プレビューは30fpsで十分
        metalView.delegate = renderer

        // 角丸・透過描画のためにレイヤーを設定
        metalView.wantsLayer = true
        metalView.layer?.cornerRadius = cornerRadius
        metalView.layer?.masksToBounds = cornerRadius > 0
        metalView.layer?.isOpaque = false

        return metalView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        // delegateが外れていたら再設定（Viewの再利用時）
        if nsView.delegate == nil {
            nsView.delegate = renderer
        }
        nsView.layer?.cornerRadius = cornerRadius
        nsView.layer?.masksToBounds = cornerRadius > 0
    }

    static func dismantleNSView(_ nsView: MTKView, coordinator: ()) {
        // View破棄時にdelegateを解除してクラッシュを防ぐ
        nsView.isPaused = true
        nsView.delegate = nil
    }
}

struct PreviewWindowContent: View {
    @ObservedObject var appDelegate: AppDelegate
    let previewRenderer: Renderer
    let device: MTLDevice

    @State private var intensityValue: Double = 0.5
    @State private var isExporting = false
    @State private var exportSuccess = false
    @State private var showExportAlert = false
    @State private var exportAlertMessage = ""
    @State private var showImportTagDialog = false
    @State private var exportedTempURL: URL?

    // 画面のアスペクト比に合わせたプレビューサイズを計算
    private var previewSize: CGSize {
        guard let screen = NSScreen.main else {
            return CGSize(width: 480, height: 300)
        }
        let screenAspect = screen.frame.width / screen.frame.height
        let previewWidth: CGFloat = 530
        let previewHeight = previewWidth / screenAspect
        return CGSize(width: previewWidth, height: previewHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            // プレビュー表示エリア（画面のアスペクト比に合わせる）
            MetalPreviewView(renderer: previewRenderer, device: device)
                .frame(width: previewSize.width, height: previewSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            // シェーダー選択
            HStack(spacing: 12) {
                ForEach(ShaderType.allCases, id: \.self) { shader in
                    Button {
                        appDelegate.selectShader(shader)
                        previewRenderer.currentShader = shader
                    } label: {
                        Text(shader.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                appDelegate.currentShader == shader
                                    ? Color.accentColor
                                    : Color.gray.opacity(0.2)
                            )
                            .foregroundColor(
                                appDelegate.currentShader == shader
                                    ? .white
                                    : .primary
                            )
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 16)

            // 背景画像セクション
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Button {
                        appDelegate.selectBackgroundImage()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "photo")
                            Text("背景画像を選択")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.2))
                        .foregroundColor(.blue)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)

                    if appDelegate.backgroundImageURL != nil {
                        Button {
                            appDelegate.clearAndEnableTransparentMode()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark")
                                Text("クリア")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.red.opacity(0.2))
                            .foregroundColor(.red)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // エフェクト強度スライダー（背景画像がある場合のみ表示）
                if appDelegate.backgroundImageURL != nil {
                    VStack(spacing: 4) {
                        HStack {
                            Text("エフェクト強度")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(intensityValue * 100))%")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                        }

                        Slider(value: $intensityValue, in: 0...1) { _ in
                            appDelegate.setEffectIntensity(Float(intensityValue))
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, 20)

            // エクスポートボタン
            HStack(spacing: 12) {
                Button {
                    exportToLibrary()
                } label: {
                    HStack(spacing: 6) {
                        if isExporting {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                        }
                        Text("エクスポート")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.2))
                    .foregroundColor(.green)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(isExporting)
            }
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
        .padding(20)
        .background(VisualEffectView())
        .onAppear {
            intensityValue = Double(appDelegate.effectIntensity)
        }
        .alert(exportSuccess ? "完了" : "エラー", isPresented: $showExportAlert) {
            Button("OK") {}
        } message: {
            Text(exportAlertMessage)
        }
        .sheet(isPresented: $showImportTagDialog) {
            if let tempURL = exportedTempURL {
                ImportTagDialogView(
                    urls: [tempURL],
                    library: WallpaperLibrary.shared,
                    isPresented: $showImportTagDialog
                )
            }
        }
    }

    // MARK: - エクスポート

    /// テンポラリに画像をエクスポートしてタグダイアログを表示 → ギャラリーに追加
    private func exportToLibrary() {
        isExporting = true

        DispatchQueue.global(qos: .userInitiated).async {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ArtiaExport")

            do {
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            } catch {
                DispatchQueue.main.async {
                    isExporting = false
                    exportSuccess = false
                    exportAlertMessage = "一時ディレクトリの作成に失敗しました"
                    showExportAlert = true
                }
                return
            }

            let shaderName = appDelegate.currentShader.displayName
            let timestamp = Int(Date().timeIntervalSince1970)
            let fileName = "自作_\(shaderName)_\(timestamp).png"
            let tempURL = tempDir.appendingPathComponent(fileName)

            let success = previewRenderer.exportToFile(url: tempURL, format: .png)

            DispatchQueue.main.async {
                isExporting = false

                if success {
                    exportedTempURL = tempURL
                    showImportTagDialog = true
                } else {
                    exportSuccess = false
                    exportAlertMessage = "画像のエクスポートに失敗しました"
                    showExportAlert = true
                }
            }
        }
    }
}

// macOSのぼかし効果
struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .hudWindow
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// ShaderTypeに表示名を追加
extension ShaderType {
    var displayName: String {
        switch self {
        case .transparent: return "透過"
        case .gradient: return "Gradient"
        case .plasma: return "Plasma"
        case .noise: return "Noise"
        }
    }
}
