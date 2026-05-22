import SwiftUI

/// スケジュール設定セクション（SettingsView内に埋め込み）
struct ScheduleSettingsSection: View {
    @ObservedObject var scheduleManager = ScheduleManager.shared
    @ObservedObject var library = WallpaperLibrary.shared

    @State private var showingEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // セクションヘッダー
            HStack {
                Image(systemName: "clock.arrow.2.circlepath")
                    .font(.system(size: 14))
                    .foregroundColor(.accentColor)
                Text("壁紙ローテーション")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }

            if scheduleManager.schedules.isEmpty {
                // スケジュールがない場合
                Button(action: createDefaultSchedule) {
                    HStack {
                        Image(systemName: "plus.circle")
                        Text("スケジュールを作成")
                    }
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
            } else {
                // スケジュール一覧
                ForEach(scheduleManager.schedules) { schedule in
                    ScheduleRow(
                        schedule: schedule,
                        isActive: scheduleManager.activeScheduleID == schedule.id,
                        nextRotation: scheduleManager.activeScheduleID == schedule.id ? scheduleManager.nextRotationDate : nil,
                        onToggle: { enabled in
                            var updated = schedule
                            updated.isEnabled = enabled
                            scheduleManager.updateSchedule(updated)
                            if enabled {
                                scheduleManager.startSchedule(schedule.id)
                            } else {
                                scheduleManager.stopSchedule()
                            }
                        },
                        onEdit: { showingEditor = true },
                        onDelete: { scheduleManager.deleteSchedule(id: schedule.id) }
                    )
                }

                // アクティブ時のコントロール
                if scheduleManager.isScheduleActive {
                    HStack(spacing: 12) {
                        Button(action: { scheduleManager.previousWallpaper() }) {
                            Image(systemName: "backward.fill")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)

                        Button(action: { scheduleManager.advanceNow() }) {
                            HStack(spacing: 4) {
                                Image(systemName: "forward.fill")
                                    .font(.system(size: 11))
                                Text("次の壁紙")
                                    .font(.system(size: 12))
                            }
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button(action: { scheduleManager.stopSchedule() }) {
                            HStack(spacing: 4) {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 11))
                                Text("停止")
                                    .font(.system(size: 12))
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }

                // 新規追加ボタン
                if scheduleManager.schedules.count < 5 {
                    Button(action: createDefaultSchedule) {
                        Label("追加", systemImage: "plus")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .sheet(isPresented: $showingEditor) {
            if let schedule = scheduleManager.schedules.first(where: { $0.id == scheduleManager.activeScheduleID })
                ?? scheduleManager.schedules.first {
                ScheduleEditorSheet(schedule: schedule, isPresented: $showingEditor)
            }
        }
    }

    private func createDefaultSchedule() {
        _ = scheduleManager.createSchedule(
            name: "スケジュール \(scheduleManager.schedules.count + 1)",
            collectionID: "favorites"
        )
        showingEditor = true
    }
}

// MARK: - スケジュール行

struct ScheduleRow: View {
    let schedule: WallpaperSchedule
    let isActive: Bool
    let nextRotation: Date?
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // ステータスインジケーター
                Circle()
                    .fill(isActive ? Color.green : Color.gray.opacity(0.3))
                    .frame(width: 8, height: 8)

                Text(schedule.name)
                    .font(.system(size: 13, weight: .medium))

                Spacer()

                Toggle("", isOn: Binding(
                    get: { schedule.isEnabled },
                    set: { onToggle($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            HStack(spacing: 16) {
                // 間隔表示
                Label(intervalLabel, systemImage: "clock")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                // シャッフル表示
                if schedule.shuffleOrder {
                    Label("シャッフル", systemImage: "shuffle")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                // ソース表示
                Label(sourceLabel, systemImage: "folder")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Spacer()

                // 編集ボタン
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }

            // 次のローテーション表示
            if let next = nextRotation, isActive {
                Text("次の切り替え: \(next, style: .relative)")
                    .font(.system(size: 10))
                    .foregroundColor(.accentColor)
            }
        }
        .padding(10)
        .background(isActive ? Color.accentColor.opacity(0.05) : Color.clear)
        .cornerRadius(8)
        .contextMenu {
            Button("編集", action: onEdit)
            Divider()
            Button("削除", role: .destructive, action: onDelete)
        }
    }

    private var intervalLabel: String {
        for preset in AppConstants.Schedule.presets {
            if preset.interval == schedule.interval {
                return preset.label
            }
        }
        let minutes = Int(schedule.interval / 60)
        if minutes < 60 { return "\(minutes)分" }
        return "\(minutes / 60)時間"
    }

    private var sourceLabel: String {
        if let collectionID = schedule.collectionID {
            return WallpaperLibrary.shared.collections.first(where: { $0.id == collectionID })?.name ?? "コレクション"
        }
        return "\(schedule.wallpaperIDs.count)枚"
    }
}

// MARK: - スケジュール編集シート

struct ScheduleEditorSheet: View {
    @State var schedule: WallpaperSchedule
    @Binding var isPresented: Bool

    @ObservedObject private var library = WallpaperLibrary.shared
    @ObservedObject private var scheduleManager = ScheduleManager.shared

    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー
            HStack {
                Text("スケジュール設定")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("完了") {
                    scheduleManager.updateSchedule(schedule)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 名前
                    VStack(alignment: .leading, spacing: 6) {
                        Text("名前")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        TextField("スケジュール名", text: $schedule.name)
                            .textFieldStyle(.roundedBorder)
                    }

                    // ソース選択
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ソース")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)

                        Picker("", selection: $schedule.collectionID) {
                            Text("すべての壁紙").tag(nil as String?)
                            ForEach(library.collections) { collection in
                                HStack {
                                    Image(systemName: collection.icon)
                                    Text(collection.name)
                                }
                                .tag(collection.id as String?)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    // 間隔選択
                    VStack(alignment: .leading, spacing: 8) {
                        Text("切り替え間隔")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)

                        LazyVGrid(columns: [
                            GridItem(.adaptive(minimum: 70), spacing: 6)
                        ], spacing: 6) {
                            ForEach(AppConstants.Schedule.presets, id: \.interval) { preset in
                                Button(action: { schedule.interval = preset.interval }) {
                                    Text(preset.label)
                                        .font(.system(size: 12))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                        .background(
                                            schedule.interval == preset.interval
                                                ? Color.accentColor
                                                : Color(NSColor.controlBackgroundColor)
                                        )
                                        .foregroundColor(
                                            schedule.interval == preset.interval ? .white : .primary
                                        )
                                        .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // シャッフル
                    Toggle("シャッフル再生", isOn: $schedule.shuffleOrder)
                        .font(.system(size: 13))

                    // アクティブ時間（オプション）
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("アクティブ時間を制限", isOn: Binding(
                            get: { schedule.activeHours != nil },
                            set: { enabled in
                                if enabled {
                                    schedule.activeHours = .init(startHour: 8, startMinute: 0, endHour: 22, endMinute: 0)
                                } else {
                                    schedule.activeHours = nil
                                }
                            }
                        ))
                        .font(.system(size: 13))

                        if let activeHours = schedule.activeHours {
                            HStack(spacing: 8) {
                                Text("開始:")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                Picker("", selection: Binding(
                                    get: { activeHours.startHour },
                                    set: { schedule.activeHours?.startHour = $0 }
                                )) {
                                    ForEach(0..<24, id: \.self) { h in
                                        Text(String(format: "%02d:00", h)).tag(h)
                                    }
                                }
                                .frame(width: 80)

                                Text("終了:")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                Picker("", selection: Binding(
                                    get: { activeHours.endHour },
                                    set: { schedule.activeHours?.endHour = $0 }
                                )) {
                                    ForEach(0..<24, id: \.self) { h in
                                        Text(String(format: "%02d:00", h)).tag(h)
                                    }
                                }
                                .frame(width: 80)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 450, height: 500)
    }
}
