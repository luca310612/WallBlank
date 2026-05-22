import SwiftUI

/// エフェクトエディタービュー
struct EffectsEditorView: View {
    @ObservedObject var effectManager: EffectManager
    let backgroundImage: NSImage?
    let onClose: () -> Void
    let onExport: (() -> Void)?

    @State private var showMaskEditor = false
    @State private var selectedEffectType: EffectType?

    init(effectManager: EffectManager = .shared,
         backgroundImage: NSImage? = nil,
         onClose: @escaping () -> Void,
         onExport: (() -> Void)? = nil) {
        self.effectManager = effectManager
        self.backgroundImage = backgroundImage
        self.onClose = onClose
        self.onExport = onExport
    }

    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー
            effectsHeader

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    // パーティクルエフェクト
                    particleEffectSection

                    Divider()

                    // ぼかしエフェクト
                    blurEffectSection

                    Divider()

                    // ウェーブエフェクト
                    waveEffectSection

                    Divider()

                    // 色収差エフェクト
                    chromaticEffectSection

                    Divider()

                    // グリッチエフェクト
                    glitchEffectSection

                    Divider()

                    // ビネットエフェクト
                    vignetteEffectSection

                    Divider()

                    // ピクセレートエフェクト
                    pixelateEffectSection

                    Divider()

                    // ブルームエフェクト
                    bloomEffectSection

                    Divider()

                    // 陽炎エフェクト
                    heatHazeEffectSection

                    Divider()

                    // 水面波紋エフェクト
                    waterRippleEffectSection

                    Divider()

                    // 植物揺れエフェクト
                    foliageSwayEffectSection
                }
                .padding(16)
            }

            Divider()

            // フッター
            effectsFooter
        }
        .frame(width: 300)
        .background(Color(NSColor.controlBackgroundColor))
        .sheet(isPresented: $showMaskEditor) {
            MaskEditorDialog(
                viewModel: MaskEditorViewModel(effectManager: effectManager),
                backgroundImage: backgroundImage
            ) {
                showMaskEditor = false
            }
        }
    }

    // MARK: - Header

    private var effectsHeader: some View {
        HStack {
            Label("エフェクト", systemImage: "sparkles")
                .font(.system(size: 14, weight: .semibold))

            Spacer()

            // アクティブエフェクト数バッジ
            if effectManager.configuration.activeEffectCount > 0 {
                Text("\(effectManager.configuration.activeEffectCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor)
                    .cornerRadius(8)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
    }

    // MARK: - Particle Effect Section

    private var particleEffectSection: some View {
        EffectSectionView(
            title: "パーティクル",
            icon: "cloud.rain",
            isEnabled: $effectManager.configuration.particle.enabled
        ) {
            VStack(spacing: 12) {
                // スタイル選択
                HStack {
                    Text("スタイル")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }

                HStack(spacing: 8) {
                    ForEach(ParticleStyle.allCases, id: \.self) { style in
                        Button(action: {
                            effectManager.setParticleStyle(style)
                        }) {
                            VStack(spacing: 4) {
                                Image(systemName: style.icon)
                                    .font(.system(size: 16))
                                Text(style.displayName)
                                    .font(.system(size: 10))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                effectManager.configuration.particle.style == style
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.clear
                            )
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(
                                        effectManager.configuration.particle.style == style
                                            ? Color.accentColor
                                            : Color.gray.opacity(0.3),
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                // 密度
                EffectSlider(
                    label: "密度",
                    value: Binding(
                        get: { effectManager.configuration.particle.density },
                        set: { effectManager.setParticleDensity($0) }
                    ),
                    range: 0...1
                )

                // 速度
                EffectSlider(
                    label: "速度",
                    value: Binding(
                        get: { effectManager.configuration.particle.speed },
                        set: { effectManager.setParticleSpeed($0) }
                    ),
                    range: 0...1
                )

                // 風向き
                EffectSlider(
                    label: "風向き",
                    value: Binding(
                        get: { effectManager.configuration.particle.windAngle },
                        set: { effectManager.setParticleWindAngle($0) }
                    ),
                    range: -1...1
                )

                // サイズ
                EffectSlider(
                    label: "サイズ",
                    value: Binding(
                        get: { effectManager.configuration.particle.size },
                        set: { effectManager.setParticleSize($0) }
                    ),
                    range: 0...1
                )

                // 不透明度
                EffectSlider(
                    label: "不透明度",
                    value: $effectManager.configuration.particle.opacity,
                    range: 0...1
                )
            }
        }
    }

    // MARK: - Blur Effect Section

    private var blurEffectSection: some View {
        EffectSectionView(
            title: "ぼかし",
            icon: "drop.circle",
            isEnabled: $effectManager.configuration.blur.enabled
        ) {
            VStack(spacing: 12) {
                // 強度
                EffectSlider(
                    label: "強度",
                    value: Binding(
                        get: { effectManager.configuration.blur.intensity },
                        set: { effectManager.setBlurIntensity($0) }
                    ),
                    range: 0...1
                )

                // マスク使用
                HStack {
                    Toggle(isOn: Binding(
                        get: { effectManager.configuration.blur.useMask },
                        set: { effectManager.setBlurUseMask($0) }
                    )) {
                        Text("マスク領域のみ")
                            .font(.system(size: 11))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Spacer()

                    if effectManager.configuration.blur.useMask {
                        Button(action: { showMaskEditor = true }) {
                            Label("編集", systemImage: "paintbrush")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                    }
                }
            }
        }
    }

    // MARK: - Wave Effect Section

    private var waveEffectSection: some View {
        EffectSectionView(
            title: "ウェーブ（髪アニメーション）",
            icon: "wind",
            isEnabled: $effectManager.configuration.wave.enabled
        ) {
            VStack(spacing: 12) {
                // 振幅
                EffectSlider(
                    label: "振幅",
                    value: Binding(
                        get: { effectManager.configuration.wave.amplitude },
                        set: { effectManager.setWaveAmplitude($0) }
                    ),
                    range: 0...1
                )

                // 周波数
                EffectSlider(
                    label: "周波数",
                    value: Binding(
                        get: { effectManager.configuration.wave.frequency },
                        set: { effectManager.setWaveFrequency($0) }
                    ),
                    range: 0...1
                )

                // 速度
                EffectSlider(
                    label: "速度",
                    value: Binding(
                        get: { effectManager.configuration.wave.speed },
                        set: { effectManager.setWaveSpeed($0) }
                    ),
                    range: 0...1
                )

                // マスク使用
                HStack {
                    Toggle(isOn: Binding(
                        get: { effectManager.configuration.wave.useMask },
                        set: { effectManager.setWaveUseMask($0) }
                    )) {
                        Text("マスク領域のみ")
                            .font(.system(size: 11))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Spacer()

                    if effectManager.configuration.wave.useMask {
                        Button(action: { showMaskEditor = true }) {
                            Label("編集", systemImage: "paintbrush")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                    }
                }

                // AIで髪を検出ボタン
                if effectManager.configuration.wave.useMask && backgroundImage != nil {
                    Button(action: detectHairWithAI) {
                        HStack {
                            Image(systemName: "wand.and.stars")
                            Text("AIで髪を検出")
                        }
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.1))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Chromatic Aberration Effect Section

    private var chromaticEffectSection: some View {
        EffectSectionView(
            title: "色収差",
            icon: "rainbow",
            isEnabled: $effectManager.configuration.chromatic.enabled
        ) {
            VStack(spacing: 12) {
                // 強度
                EffectSlider(
                    label: "強度",
                    value: Binding(
                        get: { effectManager.configuration.chromatic.intensity },
                        set: { effectManager.setChromaticIntensity($0) }
                    ),
                    range: 0...1
                )

                // 角度
                EffectSlider(
                    label: "角度",
                    value: Binding(
                        get: { effectManager.configuration.chromatic.angle },
                        set: { effectManager.setChromaticAngle($0) }
                    ),
                    range: -1...1
                )
            }
        }
    }

    // MARK: - Glitch Effect Section

    private var glitchEffectSection: some View {
        EffectSectionView(
            title: "グリッチ",
            icon: "tv",
            isEnabled: $effectManager.configuration.glitch.enabled
        ) {
            VStack(spacing: 12) {
                // 強度
                EffectSlider(
                    label: "強度",
                    value: Binding(
                        get: { effectManager.configuration.glitch.intensity },
                        set: { effectManager.setGlitchIntensity($0) }
                    ),
                    range: 0...1
                )

                // 速度
                EffectSlider(
                    label: "速度",
                    value: Binding(
                        get: { effectManager.configuration.glitch.speed },
                        set: { effectManager.setGlitchSpeed($0) }
                    ),
                    range: 0...1
                )

                // ブロックサイズ
                EffectSlider(
                    label: "ブロックサイズ",
                    value: Binding(
                        get: { effectManager.configuration.glitch.blockSize },
                        set: { effectManager.setGlitchBlockSize($0) }
                    ),
                    range: 0...1
                )
            }
        }
    }

    // MARK: - Vignette Effect Section

    private var vignetteEffectSection: some View {
        EffectSectionView(
            title: "ビネット",
            icon: "circle.dashed",
            isEnabled: $effectManager.configuration.vignette.enabled
        ) {
            VStack(spacing: 12) {
                // 強度
                EffectSlider(
                    label: "強度",
                    value: Binding(
                        get: { effectManager.configuration.vignette.intensity },
                        set: { effectManager.setVignetteIntensity($0) }
                    ),
                    range: 0...1
                )

                // 半径
                EffectSlider(
                    label: "半径",
                    value: Binding(
                        get: { effectManager.configuration.vignette.radius },
                        set: { effectManager.setVignetteRadius($0) }
                    ),
                    range: 0...1
                )
            }
        }
    }

    // MARK: - Pixelate Effect Section

    private var pixelateEffectSection: some View {
        EffectSectionView(
            title: "ピクセレート",
            icon: "square.grid.3x3",
            isEnabled: $effectManager.configuration.pixelate.enabled
        ) {
            VStack(spacing: 12) {
                // サイズ
                EffectSlider(
                    label: "ピクセルサイズ",
                    value: Binding(
                        get: { effectManager.configuration.pixelate.size },
                        set: { effectManager.setPixelateSize($0) }
                    ),
                    range: 0...1
                )
            }
        }
    }

    // MARK: - Bloom Effect Section

    private var bloomEffectSection: some View {
        EffectSectionView(
            title: "ブルーム",
            icon: "sun.max",
            isEnabled: $effectManager.configuration.bloom.enabled
        ) {
            VStack(spacing: 12) {
                // 強度
                EffectSlider(
                    label: "強度",
                    value: Binding(
                        get: { effectManager.configuration.bloom.intensity },
                        set: { effectManager.setBloomIntensity($0) }
                    ),
                    range: 0...1
                )

                // 閾値
                EffectSlider(
                    label: "閾値",
                    value: Binding(
                        get: { effectManager.configuration.bloom.threshold },
                        set: { effectManager.setBloomThreshold($0) }
                    ),
                    range: 0...1
                )
            }
        }
    }

    // MARK: - Heat Haze Effect Section

    private var heatHazeEffectSection: some View {
        EffectSectionView(
            title: "陽炎",
            icon: "flame",
            isEnabled: $effectManager.configuration.heatHaze.enabled
        ) {
            VStack(spacing: 12) {
                // 強度
                EffectSlider(
                    label: "強度",
                    value: Binding(
                        get: { effectManager.configuration.heatHaze.intensity },
                        set: { effectManager.setHeatHazeIntensity($0) }
                    ),
                    range: 0...1
                )

                // 速度
                EffectSlider(
                    label: "速度",
                    value: Binding(
                        get: { effectManager.configuration.heatHaze.speed },
                        set: { effectManager.setHeatHazeSpeed($0) }
                    ),
                    range: 0...1
                )

                // スケール
                EffectSlider(
                    label: "スケール",
                    value: Binding(
                        get: { effectManager.configuration.heatHaze.scale },
                        set: { effectManager.setHeatHazeScale($0) }
                    ),
                    range: 0...1
                )
            }
        }
    }

    // MARK: - Water Ripple Effect Section

    private var waterRippleEffectSection: some View {
        EffectSectionView(
            title: "水面波紋",
            icon: "water.waves",
            isEnabled: $effectManager.configuration.waterRipple.enabled
        ) {
            VStack(spacing: 12) {
                // 強度
                EffectSlider(
                    label: "強度",
                    value: Binding(
                        get: { effectManager.configuration.waterRipple.intensity },
                        set: { effectManager.setWaterRippleIntensity($0) }
                    ),
                    range: 0...1
                )

                // 速度
                EffectSlider(
                    label: "速度",
                    value: Binding(
                        get: { effectManager.configuration.waterRipple.speed },
                        set: { effectManager.setWaterRippleSpeed($0) }
                    ),
                    range: 0...1
                )

                // スケール
                EffectSlider(
                    label: "スケール",
                    value: Binding(
                        get: { effectManager.configuration.waterRipple.scale },
                        set: { effectManager.setWaterRippleScale($0) }
                    ),
                    range: 0...1
                )

                // 反射
                EffectSlider(
                    label: "反射",
                    value: Binding(
                        get: { effectManager.configuration.waterRipple.reflection },
                        set: { effectManager.setWaterRippleReflection($0) }
                    ),
                    range: 0...1
                )

                // マスク使用
                HStack {
                    Toggle(isOn: Binding(
                        get: { effectManager.configuration.waterRipple.useMask },
                        set: { effectManager.setWaterRippleUseMask($0) }
                    )) {
                        Text("マスク領域のみ")
                            .font(.system(size: 11))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Spacer()

                    if effectManager.configuration.waterRipple.useMask {
                        Button(action: { showMaskEditor = true }) {
                            Label("編集", systemImage: "paintbrush")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                    }
                }
            }
        }
    }

    // MARK: - Foliage Sway Effect Section

    private var foliageSwayEffectSection: some View {
        EffectSectionView(
            title: "植物揺れ",
            icon: "leaf",
            isEnabled: $effectManager.configuration.foliageSway.enabled
        ) {
            VStack(spacing: 12) {
                // 強度
                EffectSlider(
                    label: "強度",
                    value: Binding(
                        get: { effectManager.configuration.foliageSway.intensity },
                        set: { effectManager.setFoliageSwayIntensity($0) }
                    ),
                    range: 0...1
                )

                // 速度
                EffectSlider(
                    label: "速度",
                    value: Binding(
                        get: { effectManager.configuration.foliageSway.speed },
                        set: { effectManager.setFoliageSwaySpeed($0) }
                    ),
                    range: 0...1
                )

                // 複雑さ
                EffectSlider(
                    label: "複雑さ",
                    value: Binding(
                        get: { effectManager.configuration.foliageSway.complexity },
                        set: { effectManager.setFoliageSwayComplexity($0) }
                    ),
                    range: 0...1
                )

                // マスク使用
                HStack {
                    Toggle(isOn: Binding(
                        get: { effectManager.configuration.foliageSway.useMask },
                        set: { effectManager.setFoliageSwayUseMask($0) }
                    )) {
                        Text("マスク領域のみ")
                            .font(.system(size: 11))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Spacer()

                    if effectManager.configuration.foliageSway.useMask {
                        Button(action: { showMaskEditor = true }) {
                            Label("編集", systemImage: "paintbrush")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var effectsFooter: some View {
        HStack(spacing: 12) {
            Button(action: {
                effectManager.resetConfiguration()
            }) {
                Text("リセット")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)

            Spacer()

            if let onExport = onExport {
                Button(action: onExport) {
                    Label("エクスポート", systemImage: "square.and.arrow.up")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
    }

    // MARK: - Actions

    private func detectHairWithAI() {
        guard let image = backgroundImage else { return }

        HairSegmentation.shared.detectHair(from: image) { result in
            switch result {
            case .success(let segmentationResult):
                effectManager.maskData = segmentationResult.maskData
                print("[EffectsEditor] Hair detection successful, confidence: \(segmentationResult.confidence)")
            case .failure(let error):
                print("[EffectsEditor] Hair detection failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Effect Section View

struct EffectSectionView<Content: View>: View {
    let title: String
    let icon: String
    @Binding var isEnabled: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // セクションヘッダー
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(isEnabled ? .accentColor : .secondary)

                Text(title)
                    .font(.system(size: 12, weight: .medium))

                Spacer()

                Toggle("", isOn: $isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            // コンテンツ（有効時のみ表示）
            if isEnabled {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(10)
        .animation(.easeInOut(duration: 0.2), value: isEnabled)
    }
}

// MARK: - Effect Slider

struct EffectSlider: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", (value - range.lowerBound) / (range.upperBound - range.lowerBound) * 100))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(width: 35, alignment: .trailing)
            }
            Slider(value: $value, in: range)
        }
    }
}

// MARK: - Preview

#Preview {
    EffectsEditorView(
        effectManager: .shared,
        backgroundImage: nil,
        onClose: {},
        onExport: {}
    )
}
