import SwiftUI

/// 設定画面
struct SettingsView: View {
    @ObservedObject var displayManager: DisplayManager
    @ObservedObject var performanceMonitor: PerformanceMonitor
    @ObservedObject var appDelegate: AppDelegate
    @State private var selectedPreset: PerformancePreset = .balanced
    @State private var performanceFrameRate: Double = Double(PerformancePreset.balanced.frameRate)
    @State private var performanceResolutionPercent: Double = Double(Int(PerformancePreset.balanced.resolutionScale * 100))
    @State private var webWallpaperScale: Double = 1.0
    @State private var desktopItemsClickable: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // ディスプレイ選択セクション
                displaySelectionSection

                Divider()

                // パフォーマンスプリセットセクション
                performancePresetSection

                Divider()

                webWallpaperSection

                Divider()

                // 壁紙ローテーションセクション
                ScheduleSettingsSection()

                Divider()

                // 自動一時停止セクション
                performanceControlsSection

                Divider()

                // Phase 7A: パフォーマンス自動制御セクション
                environmentControlsSection

                Divider()

                // Phase 7B: スパニング壁紙 + アプリ連動ルール
                spanningWallpaperSection

                Divider()

                applicationRulesSection

                Divider()

                // Phase 8: ハードウェア連携 (Razer / Corsair / LED Boost)
                hardwareIntegrationSection

                Divider()

                macOSDesktopIntegrationSection

                Divider()

                // Phase 1.4+: 実験的なエディタ設定
                editorExperimentalSection

                Divider()

                // ステータス表示セクション
                statusIndicatorsSection

                Spacer()
            }
            .padding(24)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            selectedPreset = appDelegate.settings.performancePreset
            performanceFrameRate = Double(appDelegate.settings.performanceFrameRate)
            performanceResolutionPercent = Double(Int(appDelegate.settings.performanceResolutionScale * 100))
            webWallpaperScale = Double(appDelegate.settings.webWallpaperScale)
            desktopItemsClickable = appDelegate.settings.desktopItemsClickable
        }
    }

    // MARK: - Performance Preset Section

    private var frameRateText: String {
        "\(Int(performanceFrameRate)) FPS"
    }

    private var resolutionText: String {
        "解像度 \(Int(performanceResolutionPercent))%"
    }

    private var integerFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 0
        formatter.maximumFractionDigits = 0
        return formatter
    }

    private func performanceDetailLabel(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(text)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
        }
    }

    private var performancePresetSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // セクションヘッダー
            HStack(spacing: 8) {
                Image(systemName: "speedometer")
                    .font(.system(size: 16))
                    .foregroundColor(.accentColor)
                Text("パフォーマンス設定")
                    .font(.system(size: 15, weight: .semibold))
            }

            Text("GPU負荷と視覚品質のバランスを選択してください")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            // プリセットカード
            HStack(spacing: 12) {
                ForEach(PerformancePreset.allCases, id: \.rawValue) { preset in
                    PerformancePresetCard(
                        preset: preset,
                        isSelected: isPresetCurrentlyApplied(preset),
                        onSelect: {
                            applyPerformancePreset(preset)
                        }
                    )
                }
            }

            performanceTuningControls

            // 現在の設定詳細
            HStack(spacing: 20) {
                performanceDetailLabel(icon: "film", text: frameRateText)
                performanceDetailLabel(icon: "square.resize", text: resolutionText)
            }
            .padding(.top, 4)

            hardwareRecommendationCard
        }
    }

    /// CPU モデルと物理メモリからプリセットを提案（ローカルのみ・送信なし）
    private var hardwareRecommendationCard: some View {
        let snapshot = HardwarePerformanceAdvisor.currentSnapshot()
        let advice = HardwarePerformanceAdvisor.recommendedAdvice(for: snapshot)
        let matches = isPresetCurrentlyApplied(advice.preset)
        let adviceFpsLabel = advice.preset == .ultra
            ? "最大 \(advice.preset.frameRate) FPS"
            : "\(advice.preset.frameRate) FPS"

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 14))
                    .foregroundColor(.accentColor)
                Text("この Mac への推奨")
                    .font(.system(size: 13, weight: .semibold))
            }

            Text("\(snapshot.cpuBrandString) ・ メモリ \(snapshot.formattedMemoryGB)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: advice.preset.icon)
                    .font(.system(size: 14))
                    .foregroundColor(.accentColor)
                    .frame(width: 20, alignment: .center)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(advice.preset.displayName)（\(adviceFpsLabel)・解像度 \(Int(advice.preset.resolutionScale * 100))%）")
                        .font(.system(size: 12, weight: .medium))
                    Text(advice.rationale)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                Button("推奨を適用") {
                    applyPerformancePreset(advice.preset)
                }
                .buttonStyle(.borderedProminent)
                .disabled(matches)

                if matches {
                    Text("現在の設定と一致")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    private var performanceTuningControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            performanceSliderRow(
                title: "FPS",
                value: Binding(
                    get: { performanceFrameRate },
                    set: { setPerformanceFrameRate($0) }
                ),
                range: 15...144,
                step: 1,
                numberBinding: Binding(
                    get: { Int(performanceFrameRate) },
                    set: { setPerformanceFrameRate(Double($0)) }
                ),
                suffix: "fps"
            )

            performanceSliderRow(
                title: "解像度",
                value: Binding(
                    get: { performanceResolutionPercent },
                    set: { setPerformanceResolutionPercent($0) }
                ),
                range: 1...100,
                step: 1,
                numberBinding: Binding(
                    get: { Int(performanceResolutionPercent) },
                    set: { setPerformanceResolutionPercent(Double($0)) }
                ),
                suffix: "%"
            )
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    private func performanceSliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        numberBinding: Binding<Int>,
        suffix: String
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 54, alignment: .leading)

            Slider(value: value, in: range, step: step)

            HStack(spacing: 4) {
                TextField("", value: numberBinding, formatter: integerFormatter)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 62)
                Text(suffix)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 28, alignment: .leading)
            }
        }
    }

    private func applyPerformancePreset(_ preset: PerformancePreset) {
        selectedPreset = preset
        performanceFrameRate = Double(preset.frameRate)
        performanceResolutionPercent = Double(Int(preset.resolutionScale * 100))
        appDelegate.settings.performancePreset = preset
    }

    private func isPresetCurrentlyApplied(_ preset: PerformancePreset) -> Bool {
        selectedPreset == preset
            && Int(performanceFrameRate) == preset.frameRate
            && Int(performanceResolutionPercent) == Int(preset.resolutionScale * 100)
    }

    private func setPerformanceFrameRate(_ value: Double) {
        let clamped = max(15, min(144, Int(value.rounded())))
        performanceFrameRate = Double(clamped)
        appDelegate.settings.performanceFrameRate = clamped
    }

    private func setPerformanceResolutionPercent(_ value: Double) {
        let clamped = max(1, min(100, Int(value.rounded())))
        performanceResolutionPercent = Double(clamped)
        appDelegate.settings.performanceResolutionScale = Float(clamped) / 100
    }

    // MARK: - Display Selection Section

    private var webWallpaperScaleLabel: String {
        "\(Int(webWallpaperScale * 100))%"
    }

    private var webWallpaperSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 16))
                    .foregroundColor(.accentColor)
                Text("Web壁紙")
                    .font(.system(size: 15, weight: .semibold))
            }

            Text("Web壁紙の背景画像・背景動画の表示倍率を調整します")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("表示倍率")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text(webWallpaperScaleLabel)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Slider(
                    value: Binding(
                        get: { webWallpaperScale },
                        set: { newValue in
                            let stepped = (newValue * 20).rounded() / 20
                            webWallpaperScale = stepped
                            appDelegate.settings.webWallpaperScale = Float(stepped)
                        }
                    ),
                    in: 0.5...2.0,
                    step: 0.05
                )

                Text("100% で等倍。16:9前提の壁紙を 16:10 画面で使う場合は 100% 前後から調整")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
        }
    }

    private var displaySelectionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // セクションヘッダー
            HStack(spacing: 8) {
                Image(systemName: "display.2")
                    .font(.system(size: 16))
                    .foregroundColor(.accentColor)
                Text("ディスプレイ選択")
                    .font(.system(size: 15, weight: .semibold))
            }

            Text("壁紙を表示するディスプレイを選択してください")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            // ディスプレイリスト
            VStack(spacing: 8) {
                if displayManager.connectedDisplays.isEmpty {
                    Text("ディスプレイが見つかりません")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                } else {
                    ForEach(displayManager.connectedDisplays) { display in
                        DisplaySelectionRow(
                            display: display,
                            isEnabled: displayManager.isDisplayEnabled(display.id),
                            onToggle: { enabled in
                                displayManager.setDisplayEnabled(display.id, enabled: enabled)
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Performance Controls Section

    private var performanceControlsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // セクションヘッダー
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: 16))
                    .foregroundColor(.accentColor)
                Text("自動一時停止")
                    .font(.system(size: 15, weight: .semibold))
            }

            Text("以下の条件でアニメーションを自動的に一時停止します")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            // 一時停止条件
            VStack(spacing: 12) {
                // 他のアプリがアクティブな時
                PerformanceToggleRow(
                    icon: "app.badge",
                    title: "他のアプリがアクティブな時",
                    description: "各ディスプレイごとに判定して停止",
                    isOn: $performanceMonitor.pauseWhenOtherAppActive
                )

                // フルスクリーンアプリ使用時
                PerformanceToggleRow(
                    icon: "rectangle.inset.filled",
                    title: "フルスクリーンアプリ使用時",
                    description: "各ディスプレイごとに判定して停止",
                    isOn: $performanceMonitor.pauseWhenFullscreen
                )

                // バッテリー駆動時
                PerformanceToggleRow(
                    icon: "battery.50",
                    title: "バッテリー駆動時",
                    description: "MacBookのバッテリーを節約",
                    isOn: $performanceMonitor.pauseOnBattery
                )

                // GPU使用率
                VStack(alignment: .leading, spacing: 8) {
                    PerformanceToggleRow(
                        icon: "cpu",
                        title: "GPU使用率が閾値を超えた時",
                        description: "重い作業中にリソースを節約",
                        isOn: $performanceMonitor.pauseOnHighGPU
                    )

                    if performanceMonitor.pauseOnHighGPU {
                        HStack(spacing: 12) {
                            Text("閾値:")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)

                            Slider(
                                value: $performanceMonitor.gpuThreshold,
                                in: 50...95,
                                step: 5
                            )
                            .frame(maxWidth: 200)

                            Text("\(Int(performanceMonitor.gpuThreshold))%")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .frame(width: 40)
                        }
                        .padding(.leading, 36)
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    // MARK: - Phase 7A: Performance Auto-Control Section

    /// EnvironmentMonitor 連動の自動制御設定。既存「自動一時停止」とは責務分離している。
    /// Why: 既存セクションは GPU/手動 pause 中心、こちらは外部環境 (排他フルスクリーン / 最大化 / 他音 / バッテリー)
    ///      に対する自動応答を扱う。
    private var environmentControlsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles.tv")
                    .font(.system(size: 16))
                    .foregroundColor(.accentColor)
                Text("パフォーマンス自動制御")
                    .font(.system(size: 15, weight: .semibold))
            }

            Text("外部環境を検知し、ディスプレイごとに壁紙の再生/停止を自動切り替えします")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            VStack(spacing: 12) {
                EnvironmentToggleRow(
                    icon: "rectangle.fill.on.rectangle.fill",
                    title: "排他フルスクリーン時に停止",
                    description: "ゲームや動画の全画面再生中は壁紙を一時停止",
                    binding: Binding(
                        get: { appDelegate.settings.pauseOnExclusiveFullscreen },
                        set: {
                            appDelegate.settings.pauseOnExclusiveFullscreen = $0
                            EnvironmentMonitor.shared.pauseOnExclusiveFullscreen = $0
                            EnvironmentMonitor.shared.refreshNow()
                        }
                    )
                )

                EnvironmentToggleRow(
                    icon: "macwindow",
                    title: "最大化ウィンドウ時に停止",
                    description: "ディスプレイ全域を覆うウィンドウがあれば停止 (要アクセシビリティ権限)",
                    binding: Binding(
                        get: { appDelegate.settings.pauseOnMaximizedWindow },
                        set: {
                            appDelegate.settings.pauseOnMaximizedWindow = $0
                            EnvironmentMonitor.shared.pauseOnMaximizedWindow = $0
                            if $0 && !EnvironmentMonitor.isAccessibilityTrusted() {
                                EnvironmentMonitor.requestAccessibilityPermission()
                            }
                            EnvironmentMonitor.shared.refreshNow()
                        }
                    )
                )

                if !EnvironmentMonitor.isAccessibilityTrusted()
                    && appDelegate.settings.pauseOnMaximizedWindow {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("アクセシビリティ権限が必要です")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Button("システム設定を開く") {
                            EnvironmentMonitor.requestAccessibilityPermission()
                        }
                        .buttonStyle(.link)
                    }
                    .padding(.leading, 36)
                }

                EnvironmentToggleRow(
                    icon: "speaker.wave.2.fill",
                    title: "他アプリ再生時に停止",
                    description: "他アプリが音を鳴らしている間は壁紙を一時停止",
                    binding: Binding(
                        get: { appDelegate.settings.pauseOnOtherAudio },
                        set: {
                            appDelegate.settings.pauseOnOtherAudio = $0
                            EnvironmentMonitor.shared.pauseOnOtherAudio = $0
                            EnvironmentMonitor.shared.refreshNow()
                        }
                    )
                )

                HStack(spacing: 12) {
                    Image(systemName: "battery.50")
                        .frame(width: 24)
                        .foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("バッテリー駆動時の動作")
                            .font(.system(size: 13, weight: .medium))
                        Text("AC 電源時は AC 設定を維持します")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { appDelegate.settings.batteryStrategy },
                        set: {
                            appDelegate.settings.batteryStrategy = $0
                            EnvironmentMonitor.shared.batteryStrategy = $0
                            EnvironmentMonitor.shared.refreshNow()
                        }
                    )) {
                        ForEach(BatteryStrategy.allCases) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 200)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Phase 7B: Spanning Wallpaper Section

    /// スパニング壁紙トグル。ON で 1 枚の仮想キャンバスを全ディスプレイにまたがって描画する。
    /// Why: 既存 spanWallpaperAcrossDisplays は controller↔engine IPC 用フラグだけだったため、
    ///      新しい spanningEnabled キーで Rust 側 SpanningCanvas 経路を有効化する。
    private var spanningWallpaperSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 16))
                    .foregroundColor(.accentColor)
                Text("スパニング壁紙")
                    .font(.system(size: 15, weight: .semibold))
            }

            Toggle(isOn: Binding(
                get: { appDelegate.settings.spanningEnabled },
                set: { newValue in
                    appDelegate.settings.spanningEnabled = newValue
                    if newValue {
                        SpanningCanvasController.shared.apply()
                    } else {
                        SpanningCanvasController.shared.clear()
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ディスプレイをまたいで 1 枚で描画")
                        .font(.system(size: 13, weight: .medium))
                    Text("OFF の場合は各ディスプレイ独立 (既存挙動)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
    }

    // MARK: - Phase 7B: Application Rules Section

    private var applicationRulesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "app.connected.to.app.below.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.accentColor)
                Text("アプリ連動ルール")
                    .font(.system(size: 15, weight: .semibold))
            }

            Text("特定のアプリが起動したら壁紙を切替/停止します")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            ApplicationRulesEditorView(manager: ApplicationRulesManager.shared)
        }
    }

    // MARK: - Phase 8: Hardware Integration Section

    private var hardwareIntegrationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.system(size: 16))
                    .foregroundColor(.accentColor)
                Text("ハードウェア連携")
                    .font(.system(size: 15, weight: .semibold))
            }

            Text("壁紙の色をキーボード/マウス/ヘッドセット LED に反映します")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            // Razer Chroma Toggle
            Toggle(isOn: Binding(
                get: { appDelegate.settings.razerChromaEnabled },
                set: { newValue in
                    appDelegate.settings.razerChromaEnabled = newValue
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Razer Chroma 連動")
                        .font(.system(size: 13, weight: .medium))
                    Text("Razer Synapse 3 が起動している必要があります")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)

            // Corsair iCUE Toggle (macOS 非対応のため disabled)
            Toggle(isOn: Binding(
                get: { appDelegate.settings.corsairCueEnabled },
                set: { newValue in
                    appDelegate.settings.corsairCueEnabled = newValue
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Corsair iCUE 連動")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("macOS では未対応 (SDK が提供されていません)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(true)

            // LED Boost 強度 Slider
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("LED Boost 強度")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text(String(format: "%.0f%%", appDelegate.settings.ledBoostIntensity * 100))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Slider(value: Binding(
                    get: { Double(appDelegate.settings.ledBoostIntensity) },
                    set: { newValue in
                        appDelegate.settings.ledBoostIntensity = Float(newValue)
                    }
                ), in: 0...1)
                Text("彩度ブースト (0% = そのまま, 100% = +20%)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - macOS Desktop Integration Section

    private var macOSDesktopIntegrationSection: some View {
        let clickToRevealAlwaysOn = MacOSDesktopClickRevealAdvice.isClickWallpaperRevealEffectivelyAlwaysOn()

        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 16))
                    .foregroundColor(.accentColor)
                Text("macOS 連携")
                    .font(.system(size: 15, weight: .semibold))
            }

            Text("デスクトップ項目のクリック挙動と、macOS 側の表示設定を調整します")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { desktopItemsClickable },
                    set: { enabled in
                        desktopItemsClickable = enabled
                        appDelegate.settings.desktopItemsClickable = enabled
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("デスクトップ項目をクリック可能にする")
                            .font(.system(size: 13, weight: .medium))
                        Text("壁紙ウィンドウがマウスイベントを透過し、Finder のデスクトップ項目を直接操作できます")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)

                if clickToRevealAlwaysOn {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("macOS の「壁紙をクリックしてデスクトップを表示」が常に有効です")
                                .font(.system(size: 12, weight: .medium))
                            Text("壁紙クリック時にウィンドウが退いて見える場合があります。「ステージマネージャ使用時のみ」への変更を推奨します。")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                }

                HStack(spacing: 10) {
                    Button("デスクトップと Dock を開く") {
                        MacOSDesktopClickRevealAdvice.openDesktopDockSystemSettings()
                    }
                    .buttonStyle(.bordered)

                    if clickToRevealAlwaysOn {
                        Text("推奨: 「ステージマネージャ使用時のみ」")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
        }
    }
    
    // MARK: - Editor Experimental Section (Phase 1.4+)
    // Why: Strategy パターン化したブラシマスクラスタライザの GPU 経路を
    // 実験的トグルとして公開する。OFF (デフォルト) なら従来 Rust 経路と完全互換。

    @State private var useGPUBrush: Bool = false

    private var editorExperimentalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "paintbrush.pointed.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.accentColor)
                Text("エディタ (実験的)")
                    .font(.system(size: 15, weight: .semibold))
            }

            Text("Phase 1.4+: ブラシマスクのラスタライズを Metal compute (GPU) 経路で実行します")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Toggle(isOn: Binding(
                get: { useGPUBrush },
                set: { enabled in
                    useGPUBrush = enabled
                    appDelegate.settings.useGPUBrush = enabled
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("GPU ブラシラスタライズ")
                        .font(.system(size: 13, weight: .medium))
                    Text("実験的: OFF で従来 Rust 経路、ON で MetalBrushMaskRasterizer に切替")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .onAppear {
                useGPUBrush = appDelegate.settings.useGPUBrush
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
        }
    }

    // MARK: - Status Indicators Section

    private var truncatedAppName: String {
        let maxLength = 12
        let appName = performanceMonitor.frontmostAppName
        return appName.count > maxLength ? appName.prefix(maxLength) + "..." : appName
    }

    private var statusIndicatorsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // セクションヘッダー
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 16))
                    .foregroundColor(.accentColor)
                Text("現在の状態")
                    .font(.system(size: 15, weight: .semibold))
            }

            // ステータスバッジ
            HStack(spacing: 12) {
                // 電源状態
                StatusBadge(
                    icon: performanceMonitor.isOnBattery ? "battery.25" : "battery.100.bolt",
                    label: performanceMonitor.isOnBattery ? "バッテリー" : "電源接続",
                    isWarning: performanceMonitor.isOnBattery && performanceMonitor.pauseOnBattery
                )

                // GPU使用率
                StatusBadge(
                    icon: "cpu",
                    label: "GPU: \(Int(performanceMonitor.currentGPUUsage))%",
                    isWarning: performanceMonitor.pauseOnHighGPU &&
                              performanceMonitor.currentGPUUsage > performanceMonitor.gpuThreshold
                )

                // フルスクリーン
                StatusBadge(
                    icon: performanceMonitor.isFullscreenAppRunning ? "rectangle.inset.filled" : "rectangle",
                    label: performanceMonitor.isFullscreenAppRunning ? "フルスクリーン検出" : "通常表示",
                    isWarning: performanceMonitor.isFullscreenAppRunning && performanceMonitor.pauseWhenFullscreen
                )

                // フォアグラウンドアプリ
                if performanceMonitor.pauseWhenOtherAppActive {
                    StatusBadge(
                        icon: "app",
                        label: truncatedAppName,
                        isWarning: performanceMonitor.isOtherAppActive
                    )
                }
            }

            // 自動一時停止中の警告
            if performanceMonitor.isPausedByMonitor {
                HStack(spacing: 8) {
                    Image(systemName: "pause.circle.fill")
                        .foregroundColor(.orange)
                    Text("壁紙は自動的に一時停止中")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

                    if let reason = performanceMonitor.pauseReasonText {
                        Text("(\(reason))")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }
        }
    }
}

// MARK: - Display Selection Row

struct DisplaySelectionRow: View {
    let display: DisplayInfo
    let isEnabled: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(
                get: { isEnabled },
                set: { onToggle($0) }
            )) {
                HStack(spacing: 12) {
                    // アイコン
                    Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                        .font(.system(size: 20))
                        .foregroundColor(.accentColor)
                        .frame(width: 28)

                    // 名前と解像度
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(display.localizedName)
                                .font(.system(size: 13, weight: .medium))

                            if display.isMain {
                                Text("メイン")
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15))
                                    .foregroundColor(.accentColor)
                                    .cornerRadius(4)
                            }
                        }

                        Text("\(Int(display.resolution.width)) × \(Int(display.resolution.height))")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }
            }
            .toggleStyle(.switch)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

// MARK: - Performance Toggle Row

struct PerformanceToggleRow: View {
    let icon: String
    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13))
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let icon: String
    let label: String
    let isWarning: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text(label)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isWarning ? Color.orange.opacity(0.15) : Color(NSColor.controlBackgroundColor))
        .foregroundColor(isWarning ? .orange : .primary)
        .cornerRadius(6)
    }
}

// MARK: - Performance Preset Card

struct PerformancePresetCard: View {
    let preset: PerformancePreset
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 8) {
                Image(systemName: preset.icon)
                    .font(.system(size: 24))
                    .foregroundColor(isSelected ? .white : .accentColor)

                Text(preset.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isSelected ? .white : .primary)

                Text(preset.description)
                    .font(.system(size: 10))
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.accentColor : Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Phase 7A: Environment Toggle Row

/// EnvironmentMonitor 用の Settings 行 (Bool バインディング版)。
/// Why: 既存 PerformanceToggleRow は @ObservedObject の Bool プロパティ前提で書かれているため、
///      設定ストアに直接書く Binding<Bool> 用の薄いラッパを別途用意する。
private struct EnvironmentToggleRow: View {
    let icon: String
    let title: String
    let description: String
    let binding: Binding<Bool>

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: binding)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview {
    SettingsView(
        displayManager: DisplayManager.shared,
        performanceMonitor: PerformanceMonitor.shared,
        appDelegate: AppDelegate()
    )
    .frame(width: 500, height: 600)
}
