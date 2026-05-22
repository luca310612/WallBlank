// 水流ブラシ用オプションバー
// 上部のオプションバーに表示し、半径・流速・フォールオフ・ループ周期を調整する

import SwiftUI

struct FlowBrushOptionsBar: View {
    @ObservedObject var editorManager: ImageEditorManager
    @ObservedObject var flowBrush: FlowBrushManager

    var body: some View {
        HStack(spacing: 12) {
            sliderField(
                label: "サイズ",
                unit: "px",
                value: Binding(
                    get: { Double(flowBrush.radius) },
                    set: { flowBrush.radius = Float($0) }
                ),
                range: 4...400,
                width: 96
            )

            sliderField(
                label: "流速",
                unit: nil,
                value: Binding(
                    get: { Double(flowBrush.strength) },
                    set: { flowBrush.strength = Float($0) }
                ),
                range: 0.01...0.6,
                width: 88,
                fractionDigits: 2
            )

            sliderField(
                label: "硬さ",
                unit: nil,
                value: Binding(
                    get: { Double(flowBrush.softness) },
                    set: { flowBrush.softness = Float($0) }
                ),
                range: 0.05...1.0,
                width: 80,
                fractionDigits: 2
            )

            sliderField(
                label: "周期",
                unit: "s",
                value: Binding(
                    get: { Double(flowBrush.loopDuration) },
                    set: {
                        flowBrush.loopDuration = Float($0)
                        applyParamsToSelected()
                    }
                ),
                range: 0.5...8.0,
                width: 80,
                fractionDigits: 1
            )

            sliderField(
                label: "倍率",
                unit: nil,
                value: Binding(
                    get: { Double(flowBrush.speedScale) },
                    set: {
                        flowBrush.speedScale = Float($0)
                        applyParamsToSelected()
                    }
                ),
                range: 0.005...0.3,
                width: 80,
                fractionDigits: 3
            )

            Divider().frame(height: 22)

            Button {
                if let id = editorManager.selectedLayer?.rustLayerID {
                    flowBrush.clear(layerId: id)
                }
            } label: {
                Label("クリア", systemImage: "trash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(white: 0.78))
            .help("選択中レイヤーの水流フィールドを消去")

            Button {
                if let id = editorManager.selectedLayer?.rustLayerID {
                    flowBrush.setEnabled(layerId: id, enabled: false)
                }
            } label: {
                Label("無効化", systemImage: "pause.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(white: 0.78))
            .help("水流効果を停止（ベクトル場は保持）")
        }
        .padding(.horizontal, 4)
    }

    /// 周期・倍率変更時に即座に選択中レイヤーへ反映する
    private func applyParamsToSelected() {
        guard let id = editorManager.selectedLayer?.rustLayerID else { return }
        flowBrush.applyParams(layerId: id)
    }

    /// ラベル + スライダー + 数値表示の共通行
    private func sliderField(
        label: String,
        unit: String?,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        width: CGFloat,
        fractionDigits: Int = 0
    ) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.55))
                .frame(width: 36, alignment: .leading)
            Slider(value: value, in: range)
                .frame(width: width)
                .controlSize(.small)
            Text(formatted(value.wrappedValue, fractionDigits: fractionDigits))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(Color(white: 0.45))
                .frame(width: 40, alignment: .trailing)
            if let unit {
                Text(unit)
                    .font(.system(size: 9))
                    .foregroundColor(Color(white: 0.4))
            }
        }
    }

    private func formatted(_ x: Double, fractionDigits: Int) -> String {
        if fractionDigits <= 0 {
            return "\(Int(x.rounded()))"
        }
        return String(format: "%.\(fractionDigits)f", x)
    }
}
