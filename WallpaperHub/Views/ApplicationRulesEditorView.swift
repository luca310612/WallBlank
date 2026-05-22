import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Phase 7B: アプリ連動ルールエディタ。
/// SettingsView 内で展開され、追加/削除/有効切り替えができる。
struct ApplicationRulesEditorView: View {
    @ObservedObject var manager: ApplicationRulesManager
    @State private var showingAdder = false
    @State private var newRuleName: String = ""
    @State private var newBundleIDs: [String] = []
    @State private var newAction: ApplicationRuleActionPickerValue = .pauseWallpaper

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("アプリ連動ルール")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    showingAdder.toggle()
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
            }

            if manager.rules.isEmpty {
                Text("ルールはまだありません")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                ForEach(manager.rules) { rule in
                    ruleRow(rule: rule)
                }
            }

            if showingAdder {
                adderRow
            }
        }
    }

    @ViewBuilder
    private func ruleRow(rule: ApplicationRule) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { newValue in
                    var updated = rule
                    updated.isEnabled = newValue
                    manager.updateRule(updated)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name).font(.system(size: 12, weight: .medium))
                Text(rule.bundleIDs.joined(separator: ", "))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                manager.removeRule(id: rule.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(.red.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
    }

    private var adderRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("ルール名", text: $newRuleName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text("Bundle ID:")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(newBundleIDs.joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("追加") {
                    pickApp()
                }
            }

            Picker("アクション", selection: $newAction) {
                ForEach(ApplicationRuleActionPickerValue.allCases, id: \.self) { v in
                    Text(v.displayName).tag(v)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Spacer()
                Button("キャンセル") {
                    resetAdderState()
                }
                Button("保存") {
                    let rule = ApplicationRule(
                        name: newRuleName.isEmpty ? "未設定" : newRuleName,
                        bundleIDs: newBundleIDs,
                        action: newAction.toAction()
                    )
                    manager.addRule(rule)
                    resetAdderState()
                }
                .disabled(newBundleIDs.isEmpty)
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.06))
        .cornerRadius(6)
    }

    private func resetAdderState() {
        showingAdder = false
        newRuleName = ""
        newBundleIDs = []
        newAction = .pauseWallpaper
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK,
           let url = panel.url,
           let bundle = Bundle(url: url),
           let id = bundle.bundleIdentifier {
            if !newBundleIDs.contains(id) {
                newBundleIDs.append(id)
            }
        }
    }
}

/// Picker 用の中間値 (associated value enum を SwiftUI Picker で扱いにくいため)
enum ApplicationRuleActionPickerValue: String, CaseIterable, Hashable {
    case pauseWallpaper
    case lowProfile
    case balancedProfile

    var displayName: String {
        switch self {
        case .pauseWallpaper:    return "壁紙を一時停止"
        case .lowProfile:        return "省電力プリセット"
        case .balancedProfile:   return "バランスプリセット"
        }
    }

    func toAction() -> ApplicationRuleAction {
        switch self {
        case .pauseWallpaper:    return .pauseWallpaper
        case .lowProfile:        return .switchProfile(presetID: 0)
        case .balancedProfile:   return .switchProfile(presetID: 1)
        }
    }
}
