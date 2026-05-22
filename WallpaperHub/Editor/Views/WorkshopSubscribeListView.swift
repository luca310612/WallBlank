import SwiftUI

/// Workshop 購読一覧。Steam 接続時は GetSubscribedItems / GetItemInstallInfo で一覧表示し、選択で loadProject する。
struct WorkshopSubscribeListView: View {
    @ObservedObject private var steamManager = SteamManager.shared
    @Environment(\.dismiss) private var dismiss

    /// 表示用の購読アイテム（steamworks 実装時に GetSubscribedItems + GetItemInstallInfo で取得）
    private var subscribedItems: [WorkshopSubscribeItem] { [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Workshop の壁紙")
                    .font(.headline)
                Spacer()
                Button("閉じる") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal)

            if !steamManager.isAvailable {
                Text(steamManager.statusMessage)
                    .foregroundColor(.secondary)
                    .padding()
                Spacer()
            } else if subscribedItems.isEmpty {
                Text("購読しているアイテムはありません。Steam Workshop で壁紙を購読するとここに表示されます。")
                    .foregroundColor(.secondary)
                    .padding()
                Spacer()
            } else {
                List(subscribedItems, id: \.id) { item in
                    Button(action: { openItem(item) }) {
                        HStack {
                            Text(item.title)
                            Spacer()
                            Image(systemName: "folder")
                        }
                    }
                }
            }
        }
        .frame(minWidth: 320, minHeight: 240)
    }

    private func openItem(_ item: WorkshopSubscribeItem) {
        let projectURL = item.installPath.appendingPathComponent("project.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: projectURL.path) else { return }
        try? ImageEditorManager.shared.loadProject(from: projectURL)
        dismiss()
    }
}

/// 購読アイテム表示用（steamworks 実装時に GetItemInstallInfo 等で取得）
struct WorkshopSubscribeItem {
    let id: String
    let title: String
    let installPath: URL
}
