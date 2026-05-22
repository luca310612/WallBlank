import SwiftUI

/// Phase 7B: プレイリストエディタ。
/// MainHubWindow の "プレイリスト" タブから表示される。
struct PlaylistEditorView: View {
    @ObservedObject var manager: PlaylistManager
    @ObservedObject var library: WallpaperLibrary
    @State private var selectedPlaylistID: UUID?
    @State private var newName: String = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 240)
                .background(Color(NSColor.windowBackgroundColor))

            Divider()

            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("プレイリスト")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    let p = manager.createPlaylist()
                    selectedPlaylistID = p.id
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
            }
            .padding(12)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(manager.playlists) { playlist in
                        playlistRow(playlist)
                    }
                }
            }
        }
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        Button(action: { selectedPlaylistID = playlist.id }) {
            HStack {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading) {
                    Text(playlist.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    Text("\(playlist.items.count) 件 / \(playlist.mode.displayName)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if manager.activePlaylistID == playlist.id {
                    Image(systemName: "play.circle.fill")
                        .foregroundColor(.green)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selectedPlaylistID == playlist.id ? Color.accentColor.opacity(0.12) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detailContent: some View {
        if let id = selectedPlaylistID,
           let idx = manager.playlists.firstIndex(where: { $0.id == id }) {
            playlistDetail(manager.playlists[idx])
        } else {
            VStack {
                Spacer()
                Text("左のリストから選ぶか、+ で新しく作成します")
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
    }

    private func playlistDetail(_ playlist: Playlist) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField("プレイリスト名", text: Binding(
                        get: { playlist.name },
                        set: { newValue in
                            var updated = playlist
                            updated.name = newValue
                            manager.updatePlaylist(updated)
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Spacer()
                    if manager.activePlaylistID == playlist.id {
                        Button("停止") { manager.stop() }
                    } else {
                        Button("再生") { manager.start(playlist.id) }
                            .disabled(playlist.items.isEmpty)
                    }
                    Button {
                        manager.deletePlaylist(id: playlist.id)
                        selectedPlaylistID = nil
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }

                HStack {
                    Picker("再生モード", selection: Binding(
                        get: { playlist.mode },
                        set: { newValue in
                            var updated = playlist
                            updated.mode = newValue
                            manager.updatePlaylist(updated)
                        }
                    )) {
                        ForEach(PlaylistMode.allCases, id: \.self) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Text("間隔: ")
                        TextField("秒", value: Binding(
                            get: { playlist.intervalSeconds },
                            set: { newValue in
                                var updated = playlist
                                updated.intervalSeconds = max(5, newValue)
                                manager.updatePlaylist(updated)
                            }
                        ), format: .number)
                        .frame(width: 60)
                        Text("秒")
                    }
                }

                Text("壁紙アイテム (\(playlist.items.count))")
                    .font(.system(size: 12, weight: .semibold))

                if playlist.items.isEmpty {
                    Text("壁紙はまだありません。ギャラリーからプレイリスト ID をコピーして追加してください")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(playlist.items.indices, id: \.self) { index in
                        HStack {
                            Image(systemName: "line.3.horizontal")
                                .foregroundColor(.secondary)
                            Text(playlist.items[index])
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                            Button {
                                var updated = playlist
                                updated.items.remove(at: index)
                                manager.updatePlaylist(updated)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(20)
        }
    }
}
