import SwiftUI

// MARK: - 0.1 刻み（太さ・濃さの数値入力用）

private func brushClampedTenth(_ x: Double, _ range: ClosedRange<Double>) -> Double {
    let stepped = (x * 10).rounded() / 10
    return Swift.min(Swift.max(stepped, range.lowerBound), range.upperBound)
}

// MARK: - オプションバー（自由ペン＝ブラシ選択時・Photoshop 風）

struct FreeformBrushOptionsBar: View {
    @ObservedObject var editorManager: ImageEditorManager

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.9), Color.white.opacity(0.15)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 10
                        )
                    )
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))

                VStack(alignment: .leading, spacing: 2) {
                    Text("サイズ")
                        .font(.system(size: 9))
                        .foregroundColor(Color(white: 0.5))
                    HStack(spacing: 6) {
                        Slider(value: diameterBinding, in: 0.1...600)
                            .frame(width: 96)
                            .controlSize(.small)
                        TextField("", value: diameterBinding, format: .number.precision(.fractionLength(1)))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(width: 48)
                            .multilineTextAlignment(.trailing)
                        Text("px")
                            .font(.system(size: 9))
                            .foregroundColor(Color(white: 0.45))
                    }
                }
            }

            optionSlider(label: "硬さ", value: hardnessBinding, width: 88)
            opacityOptionRow
            optionSlider(label: "流量", value: flowBinding, width: 88, percent: true)
            smoothingBar

            Picker("", selection: paintModeBinding) {
                ForEach(BrushMaskPaintMode.allCases) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 88)
            .labelsHidden()

            Picker("", selection: maskCombineBinding) {
                ForEach(EditorMaskCombineMode.allCases) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 100)
            .labelsHidden()
            .help("既存の選択マスクとの合成")
        }
    }

    private var hardnessBinding: Binding<Double> {
        Binding(
            get: { editorManager.toolSettings.stroke.hardness },
            set: { v in editorManager.mutateToolSettings { $0.stroke.hardness = brushClampedTenth(v, 0.1...1) } }
        )
    }

    private var opacityBinding: Binding<Double> {
        Binding(
            get: { editorManager.toolSettings.stroke.opacity },
            set: { v in
                let c = brushClampedTenth(v, 0.1...1)
                editorManager.mutateToolSettings { $0.stroke.opacity = c }
            }
        )
    }

    /// 濃さ（不透明度）を 0.1% 刻みで表示・入力（10.0〜100.0）
    private var opacityPercentTenthBinding: Binding<Double> {
        Binding(
            get: { editorManager.toolSettings.stroke.opacity * 100 },
            set: { v in
                let p = brushClampedTenth(v, 10...100)
                editorManager.mutateToolSettings { $0.stroke.opacity = p / 100 }
            }
        )
    }

    private var opacityOptionRow: some View {
        HStack(spacing: 4) {
            Text("不透明度")
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.55))
                .frame(width: 44, alignment: .leading)
            Slider(value: opacityBinding, in: 0.1...1)
                .frame(width: 72)
                .controlSize(.small)
            TextField("", value: opacityPercentTenthBinding, format: .number.precision(.fractionLength(1)))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 9, design: .monospaced))
                .frame(width: 44)
                .multilineTextAlignment(.trailing)
            Text("%")
                .font(.system(size: 9))
                .foregroundColor(Color(white: 0.45))
        }
    }

    private var flowBinding: Binding<Double> {
        Binding(
            get: { editorManager.toolSettings.stroke.flow },
            set: { v in
                let c = brushClampedTenth(v, 0.1...1)
                editorManager.mutateToolSettings { $0.stroke.flow = Swift.max(0.1, c) }
            }
        )
    }

    private var diameterBinding: Binding<Double> {
        Binding(
            get: { editorManager.toolSettings.stroke.diameterPixels },
            set: { v in
                let c = brushClampedTenth(v, 0.1...600)
                editorManager.mutateToolSettings { $0.stroke.diameterPixels = c }
            }
        )
    }

    private var smoothingBar: some View {
        HStack(spacing: 4) {
            Text("滑らかさ")
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.55))
                .frame(width: 44, alignment: .leading)
            Slider(value: Binding(
                get: { editorManager.toolSettings.stroke.smoothingPercent },
                set: { v in editorManager.mutateToolSettings { $0.stroke.smoothingPercent = v } }
            ), in: 0.1...100)
            .frame(width: 88)
            .controlSize(.small)
            Text("\(Int(editorManager.toolSettings.stroke.smoothingPercent.rounded()))%")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(Color(white: 0.45))
                .frame(width: 30, alignment: .trailing)
        }
    }

    private var paintModeBinding: Binding<BrushMaskPaintMode> {
        Binding(
            get: { editorManager.toolSettings.stroke.paintMode },
            set: { v in editorManager.mutateToolSettings { $0.stroke.paintMode = v } }
        )
    }

    private var maskCombineBinding: Binding<EditorMaskCombineMode> {
        Binding(
            get: { editorManager.toolSettings.maskCombine },
            set: { v in editorManager.mutateToolSettings { $0.maskCombine = v } }
        )
    }

    private func optionSlider(label: String, value: Binding<Double>, width: CGFloat, percent: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.55))
                .frame(width: 44, alignment: .leading)
            Slider(value: value, in: 0.1...1)
                .frame(width: width)
            Text(percent ? "\(Int((value.wrappedValue * 100).rounded()))%" : "\(Int((value.wrappedValue * 100).rounded()))")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(Color(white: 0.45))
                .frame(width: 30, alignment: .trailing)
        }
    }
}

// MARK: - 右パネル（詳細）

/// 自由ペン用のブラシ・マスク仕上げ・拡張パラメータ（折りたたみセクション）
struct EditorBrushToolPropertySections: View {
    @ObservedObject var editorManager: ImageEditorManager
    @ObservedObject private var presetLibrary: BrushPresetLibrary = .shared
    var sectionCardFill: Color
    var inspectorCompact: Bool

    var body: some View {
        VStack(spacing: 16) {
            BrushPresetStripView(
                editorManager: editorManager,
                presetLibrary: presetLibrary,
                cardBackground: sectionCardFill
            )
            PropertySectionView(title: "ブラシストローク", icon: "paintbrush.pointed", cardBackground: sectionCardFill) {
                VStack(spacing: 12) {
                    HStack(alignment: inspectorCompact ? .top : .center, spacing: 10) {
                        EditorSlider(
                            label: "直径（px）",
                            value: diameterSliderBinding,
                            range: 0.1...800,
                            stackValueUnderLabel: inspectorCompact
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("0.1 単位")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                            HStack(spacing: 4) {
                                TextField("", value: diameterTenthFieldBinding, format: .number.precision(.fractionLength(1)))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 64)
                                    .multilineTextAlignment(.trailing)
                                Text("px")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(width: 118, alignment: .trailing)
                    }
                    EditorSlider(
                        label: "硬さ",
                        value: hardnessBinding,
                        range: 0.1...1,
                        showPercent: true,
                        stackValueUnderLabel: inspectorCompact
                    )
                    HStack(alignment: inspectorCompact ? .top : .center, spacing: 10) {
                        EditorSlider(
                            label: "不透明度",
                            value: opacityBinding,
                            range: 0.1...1,
                            showPercent: true,
                            stackValueUnderLabel: inspectorCompact
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("0.1 単位")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                            HStack(spacing: 4) {
                                TextField("", value: opacityPercentTenthFieldBinding, format: .number.precision(.fractionLength(1)))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 56)
                                    .multilineTextAlignment(.trailing)
                                Text("%")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(width: 104, alignment: .trailing)
                    }
                    EditorSlider(
                        label: "流量",
                        value: flowBinding,
                        range: 0.1...1,
                        showPercent: true,
                        stackValueUnderLabel: inspectorCompact
                    )
                    EditorSlider(
                        label: "スムージング",
                        value: smoothingBinding,
                        range: 0.1...100,
                        suffix: "%",
                        stackValueUnderLabel: inspectorCompact
                    )
                    HStack {
                        Text("描画モード")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Picker("", selection: paintModeBinding) {
                            ForEach(BrushMaskPaintMode.allCases) { m in
                                Text(m.displayName).tag(m)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 160)
                    }
                    HStack {
                        Text("マスク合成")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Picker("", selection: maskCombineBinding) {
                            ForEach(EditorMaskCombineMode.allCases) { m in
                                Text(m.displayName).tag(m)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 160)
                    }
                }
            }

            PropertySectionView(title: "マスク仕上げ", icon: "camera.filters", cardBackground: sectionCardFill) {
                VStack(spacing: 12) {
                    EditorSlider(
                        label: "ぼかし（ストローク後）",
                        value: postBlurBinding,
                        range: 0.1...24,
                        stackValueUnderLabel: inspectorCompact
                    )
                    EditorSlider(
                        label: "エッジ調整（拡張＋／収縮−）",
                        value: edgeBinding,
                        range: -12...24,
                        stackValueUnderLabel: inspectorCompact
                    )
                    EditorSlider(
                        label: "レベル 入力黒点",
                        value: inBlackBinding,
                        range: 0.1...254,
                        stackValueUnderLabel: inspectorCompact
                    )
                    EditorSlider(
                        label: "レベル 入力白点",
                        value: inWhiteBinding,
                        range: 1...255,
                        stackValueUnderLabel: inspectorCompact
                    )
                    EditorSlider(
                        label: "ノイズ",
                        value: noiseBinding,
                        range: 0.1...1,
                        showPercent: true,
                        stackValueUnderLabel: inspectorCompact
                    )
                    HStack {
                        Text("グラデーション")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Picker("", selection: gradientKindBinding) {
                            ForEach(BrushMaskGradientKind.allCases) { k in
                                Text(k.displayName).tag(k)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 140)
                    }
                    EditorSlider(
                        label: "グラデ強度",
                        value: gradientStrengthBinding,
                        range: 0.1...1,
                        showPercent: true,
                        stackValueUnderLabel: inspectorCompact
                    )
                }
            }

            PropertySectionView(title: "パーティクル（壁紙エンジン連携予定）", icon: "sparkles", cardBackground: sectionCardFill) {
                particlePlaceholder
            }

            PropertySectionView(title: "画面エフェクト・駆動（予定）", icon: "wand.and.stars", cardBackground: sectionCardFill) {
                proceduralAndInputPlaceholder
            }

            PropertySectionView(title: "アセット・入出力", icon: "square.and.arrow.down", cardBackground: sectionCardFill) {
                assetToggles
            }
        }
    }

    private var diameterSliderBinding: Binding<Float> {
        Binding(
            get: { Float(editorManager.toolSettings.stroke.diameterPixels) },
            set: { v in
                let c = brushClampedTenth(Double(v), 0.1...800)
                editorManager.mutateToolSettings { $0.stroke.diameterPixels = c }
            }
        )
    }

    private var diameterTenthFieldBinding: Binding<Double> {
        Binding(
            get: { editorManager.toolSettings.stroke.diameterPixels },
            set: { v in editorManager.mutateToolSettings { $0.stroke.diameterPixels = brushClampedTenth(v, 0.1...800) } }
        )
    }

    private var hardnessBinding: Binding<Float> {
        Binding(
            get: { Float(editorManager.toolSettings.stroke.hardness) },
            set: { v in
                let c = max(0.1, min(1, Double(v)))
                editorManager.mutateToolSettings { $0.stroke.hardness = c }
            }
        )
    }

    private var opacityBinding: Binding<Float> {
        Binding(
            get: { Float(editorManager.toolSettings.stroke.opacity) },
            set: { v in
                let c = brushClampedTenth(Double(v), 0.1...1)
                editorManager.mutateToolSettings { $0.stroke.opacity = c }
            }
        )
    }

    private var opacityPercentTenthFieldBinding: Binding<Double> {
        Binding(
            get: { editorManager.toolSettings.stroke.opacity * 100 },
            set: { v in
                let p = brushClampedTenth(v, 10...100)
                editorManager.mutateToolSettings { $0.stroke.opacity = p / 100 }
            }
        )
    }

    private var flowBinding: Binding<Float> {
        Binding(
            get: { Float(editorManager.toolSettings.stroke.flow) },
            set: { v in
                let c = brushClampedTenth(Double(v), 0.1...1)
                editorManager.mutateToolSettings { $0.stroke.flow = Swift.max(0.1, c) }
            }
        )
    }

    private var smoothingBinding: Binding<Float> {
        Binding(
            get: { Float(editorManager.toolSettings.stroke.smoothingPercent) },
            set: { v in editorManager.mutateToolSettings { $0.stroke.smoothingPercent = Double(v) } }
        )
    }

    private var paintModeBinding: Binding<BrushMaskPaintMode> {
        Binding(
            get: { editorManager.toolSettings.stroke.paintMode },
            set: { v in editorManager.mutateToolSettings { $0.stroke.paintMode = v } }
        )
    }

    private var maskCombineBinding: Binding<EditorMaskCombineMode> {
        Binding(
            get: { editorManager.toolSettings.maskCombine },
            set: { v in editorManager.mutateToolSettings { $0.maskCombine = v } }
        )
    }

    private var postBlurBinding: Binding<Float> {
        Binding(
            get: { Float(editorManager.toolSettings.maskPost.postBlurRadius) },
            set: { v in editorManager.mutateToolSettings { $0.maskPost.postBlurRadius = Double(v) } }
        )
    }

    private var edgeBinding: Binding<Float> {
        Binding(
            get: { Float(editorManager.toolSettings.maskPost.edgeAdjustPixels) },
            set: { v in editorManager.mutateToolSettings { $0.maskPost.edgeAdjustPixels = Int(v.rounded()) } }
        )
    }

    private var inBlackBinding: Binding<Float> {
        Binding(
            get: { Float(editorManager.toolSettings.maskPost.levelsInBlack) },
            set: { v in editorManager.mutateToolSettings { $0.maskPost.levelsInBlack = Double(v) } }
        )
    }

    private var inWhiteBinding: Binding<Float> {
        Binding(
            get: { Float(editorManager.toolSettings.maskPost.levelsInWhite) },
            set: { v in editorManager.mutateToolSettings { $0.maskPost.levelsInWhite = Double(v) } }
        )
    }

    private var noiseBinding: Binding<Float> {
        Binding(
            get: { Float(editorManager.toolSettings.maskPost.noiseAmount) },
            set: { v in editorManager.mutateToolSettings { $0.maskPost.noiseAmount = Double(v) } }
        )
    }

    private var gradientKindBinding: Binding<BrushMaskGradientKind> {
        Binding(
            get: { editorManager.toolSettings.gradient.kind },
            set: { v in editorManager.mutateToolSettings { $0.gradient.kind = v } }
        )
    }

    private var gradientStrengthBinding: Binding<Float> {
        Binding(
            get: { Float(editorManager.toolSettings.gradient.strength) },
            set: { v in editorManager.mutateToolSettings { $0.gradient.strength = Double(v) } }
        )
    }

    private var particlePlaceholder: some View {
        VStack(spacing: 10) {
            Text("発生数・ライフ・サイズ・速度・重力・風・ランダム・加算合成などを保持します。壁紙エンジン側のパーティクルに接続予定です。")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            EditorSlider(
                label: "発生レート",
                value: Binding(
                    get: { Float(editorManager.toolSettings.particle.emissionRate) },
                    set: { v in editorManager.mutateToolSettings { $0.particle.emissionRate = Double(v) } }
                ),
                range: 0.1...200,
                stackValueUnderLabel: inspectorCompact
            )
            EditorSlider(
                label: "ライフ（秒）",
                value: Binding(
                    get: { Float(editorManager.toolSettings.particle.lifetimeSeconds) },
                    set: { v in editorManager.mutateToolSettings { $0.particle.lifetimeSeconds = Double(v) } }
                ),
                range: 0.1...20,
                stackValueUnderLabel: inspectorCompact
            )
            EditorSlider(
                label: "開始サイズ",
                value: Binding(
                    get: { Float(editorManager.toolSettings.particle.startSize) },
                    set: { v in editorManager.mutateToolSettings { $0.particle.startSize = Double(v) } }
                ),
                range: 1...200,
                stackValueUnderLabel: inspectorCompact
            )
            EditorSlider(
                label: "終了サイズ",
                value: Binding(
                    get: { Float(editorManager.toolSettings.particle.endSize) },
                    set: { v in editorManager.mutateToolSettings { $0.particle.endSize = Double(v) } }
                ),
                range: 0.1...200,
                stackValueUnderLabel: inspectorCompact
            )
            EditorSlider(
                label: "速度",
                value: Binding(
                    get: { Float(editorManager.toolSettings.particle.speed) },
                    set: { v in editorManager.mutateToolSettings { $0.particle.speed = Double(v) } }
                ),
                range: 0.1...400,
                stackValueUnderLabel: inspectorCompact
            )
            EditorSlider(
                label: "方向（度）",
                value: Binding(
                    get: { Float(editorManager.toolSettings.particle.directionDegrees) },
                    set: { v in editorManager.mutateToolSettings { $0.particle.directionDegrees = Double(v) } }
                ),
                range: (-180)...180,
                stackValueUnderLabel: inspectorCompact
            )
            EditorSlider(
                label: "重力",
                value: Binding(
                    get: { Float(editorManager.toolSettings.particle.gravity) },
                    set: { v in editorManager.mutateToolSettings { $0.particle.gravity = Double(v) } }
                ),
                range: (-200)...200,
                stackValueUnderLabel: inspectorCompact
            )
            EditorSlider(
                label: "風 X / Y",
                value: Binding(
                    get: { Float(editorManager.toolSettings.particle.windX) },
                    set: { v in editorManager.mutateToolSettings { $0.particle.windX = Double(v) } }
                ),
                range: (-200)...200,
                stackValueUnderLabel: inspectorCompact
            )
            EditorSlider(
                label: "風 Y（別軸）",
                value: Binding(
                    get: { Float(editorManager.toolSettings.particle.windY) },
                    set: { v in editorManager.mutateToolSettings { $0.particle.windY = Double(v) } }
                ),
                range: (-200)...200,
                stackValueUnderLabel: inspectorCompact
            )
            EditorSlider(
                label: "サイズランダム",
                value: Binding(
                    get: { Float(editorManager.toolSettings.particle.sizeRandom) },
                    set: { v in editorManager.mutateToolSettings { $0.particle.sizeRandom = Double(v) } }
                ),
                range: 0.1...1,
                showPercent: true,
                stackValueUnderLabel: inspectorCompact
            )
            EditorSlider(
                label: "位置ランダム",
                value: Binding(
                    get: { Float(editorManager.toolSettings.particle.positionRandom) },
                    set: { v in editorManager.mutateToolSettings { $0.particle.positionRandom = Double(v) } }
                ),
                range: 0.1...1,
                showPercent: true,
                stackValueUnderLabel: inspectorCompact
            )
            HStack {
                Text("加算合成")
                    .font(.system(size: 11))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { editorManager.toolSettings.particle.additiveBlend },
                    set: { v in editorManager.mutateToolSettings { $0.particle.additiveBlend = v } }
                ))
                .labelsHidden()
            }
        }
    }

    private var proceduralAndInputPlaceholder: some View {
        VStack(spacing: 12) {
            Text("波形・発光・ぼかし・色調・フェード・音声反応・スクリプト等はプロジェクトに保存され、エフェクトパイプライン実装時に参照されます。")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            EditorSlider(
                label: "エフェクト強度",
                value: Binding(
                    get: { Float(editorManager.toolSettings.procedural.effectIntensity) },
                    set: { v in editorManager.mutateToolSettings { $0.procedural.effectIntensity = Double(v) } }
                ),
                range: 0.1...2,
                stackValueUnderLabel: inspectorCompact
            )
            EditorSlider(
                label: "波形 Wave",
                value: Binding(
                    get: { Float(editorManager.toolSettings.procedural.waveAmplitude) },
                    set: { v in editorManager.mutateToolSettings { $0.procedural.waveAmplitude = Double(v) } }
                ),
                range: 0...1,
                stackValueUnderLabel: inspectorCompact
            )
            Toggle("マウス追従", isOn: Binding(
                get: { editorManager.toolSettings.input.mouseFollow },
                set: { v in editorManager.mutateToolSettings { $0.input.mouseFollow = v } }
            ))
            Toggle("音楽反応（Audio）", isOn: Binding(
                get: { editorManager.toolSettings.input.audioResponsive },
                set: { v in editorManager.mutateToolSettings { $0.input.audioResponsive = v } }
            ))
            Toggle("スクリプト制御", isOn: Binding(
                get: { editorManager.toolSettings.input.scriptEnabled },
                set: { v in editorManager.mutateToolSettings { $0.input.scriptEnabled = v } }
            ))
        }
    }

    private var assetToggles: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("PNG 透過を優先", isOn: Binding(
                get: { editorManager.toolSettings.assets.preferPNGTransparency },
                set: { v in editorManager.mutateToolSettings { $0.assets.preferPNGTransparency = v } }
            ))
            Toggle("JPEG 背景を許可", isOn: Binding(
                get: { editorManager.toolSettings.assets.allowJPEGBackground },
                set: { v in editorManager.mutateToolSettings { $0.assets.allowJPEGBackground = v } }
            ))
            Toggle("アルファをマスクに利用", isOn: Binding(
                get: { editorManager.toolSettings.assets.useAlphaAsMask },
                set: { v in editorManager.mutateToolSettings { $0.assets.useAlphaAsMask = v } }
            ))
            Toggle("外部ブラシ PNG", isOn: Binding(
                get: { editorManager.toolSettings.assets.useExternalBrushPNG },
                set: { v in editorManager.mutateToolSettings { $0.assets.useExternalBrushPNG = v } }
            ))
        }
    }
}

// MARK: - プリセット選択帯
// Why: 「ブラシA・B・C」を瞬時に切り替える UX を提供。プリセット未保存の編集状態は
// 黄色のドットで可視化し、ユーザーに「現在の状態を保存」を促す。

struct BrushPresetStripView: View {
    @ObservedObject var editorManager: ImageEditorManager
    @ObservedObject var presetLibrary: BrushPresetLibrary
    var cardBackground: Color

    @State private var isShowingNamePrompt: Bool = false
    @State private var newPresetName: String = ""
    @State private var saveErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("プリセット")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                if hasUnsavedChanges {
                    Circle()
                        .fill(Color.yellow)
                        .frame(width: 6, height: 6)
                        .help("現在のブラシ設定は選択中プリセットと異なります")
                }
                Spacer()
                Button {
                    newPresetName = defaultNewName()
                    isShowingNamePrompt = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("現在のブラシ設定をプリセットとして保存")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(presetLibrary.presets) { preset in
                        BrushPresetChip(
                            preset: preset,
                            isActive: presetLibrary.activePresetID == preset.id,
                            onSelect: { applyPreset(preset) },
                            onDelete: preset.isBuiltIn ? nil : { deletePreset(preset) }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(cardBackground)
        )
        .sheet(isPresented: $isShowingNamePrompt) {
            namePromptSheet
        }
        .alert("プリセット保存エラー", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "")
        }
    }

    // MARK: - 名前入力シート
    private var namePromptSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("プリセットを保存")
                .font(.headline)
            TextField("プリセット名", text: $newPresetName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
            HStack {
                Spacer()
                Button("キャンセル") { isShowingNamePrompt = false }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { savePreset() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    // MARK: - 状態判定
    private var hasUnsavedChanges: Bool {
        guard let id = presetLibrary.activePresetID,
              let active = presetLibrary.presets.first(where: { $0.id == id }) else {
            return false
        }
        return !active.matches(editorManager.toolSettings)
    }

    private func defaultNewName() -> String {
        "マイプリセット \(presetLibrary.presets.filter { !$0.isBuiltIn }.count + 1)"
    }

    // MARK: - 操作
    private func applyPreset(_ preset: BrushPreset) {
        editorManager.mutateToolSettings { settings in
            preset.apply(to: &settings)
        }
        presetLibrary.activePresetID = preset.id
    }

    private func savePreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            let saved = try presetLibrary.captureAndSave(from: editorManager.toolSettings, name: name)
            presetLibrary.activePresetID = saved.id
            isShowingNamePrompt = false
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }

    private func deletePreset(_ preset: BrushPreset) {
        do {
            try presetLibrary.delete(preset.id)
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - プリセットチップ（横スクロール内の1要素）
private struct BrushPresetChip: View {
    let preset: BrushPreset
    let isActive: Bool
    let onSelect: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 4) {
                Image(systemName: preset.iconSystemName)
                    .font(.system(size: 18))
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isActive ? Color.accentColor.opacity(0.25) : Color.white.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(isActive ? Color.accentColor : Color.white.opacity(0.15), lineWidth: isActive ? 1.5 : 1)
                    )
                Text(preset.name)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 56)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onDelete {
                Button("削除", role: .destructive, action: onDelete)
            } else {
                Text("組み込みプリセット")
                    .foregroundColor(.secondary)
            }
        }
        .help(preset.name + (preset.isBuiltIn ? "（組み込み）" : ""))
    }
}
