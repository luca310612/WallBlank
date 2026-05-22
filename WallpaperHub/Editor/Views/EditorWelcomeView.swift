import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Security

private enum EditorWelcomeSecurityScope {
    static let scanPathKey = "artia.editor.userLibraryScanPath"
    static let scanBookmarkKey = "artia.editor.userLibraryScanBookmark"
}

/// Xcode ウェルカム風のエディター起動ハブ（最近の `.artia` プロジェクト一覧）
struct EditorWelcomeView: View {
    @ObservedObject var editorManager: ImageEditorManager
    var onDismissWelcome: () -> Void

    @State private var recentProjects: [ArtiaProjectListEntry] = []
    @State private var scanError: String?
    @State private var isScanning = false

    var body: some View {
        HStack(spacing: 0) {
            welcomeLeftPane
                .frame(minWidth: 420, maxWidth: .infinity)
            welcomeRightPane
                .frame(minWidth: 280, maxWidth: 360)
        }
        .frame(minWidth: 760, minHeight: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            refreshProjectList()
            promptForDocumentsAccessIfNeeded()
        }
    }

    // MARK: - Left

    private var welcomeLeftPane: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.16, blue: 0.17),
                    Color(red: 0.11, green: 0.11, blue: 0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 28) {
                Spacer(minLength: 24)
                VStack(spacing: 8) {
                    Image(systemName: "paintbrush.pointed.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.white.opacity(0.92))
                    Text("WallBlank")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("エディター")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
                Spacer()
                VStack(spacing: 12) {
                    welcomeActionButton(
                        title: "新規プロジェクトを作成…",
                        systemImage: "plus.square.dashed"
                    ) {
                        editorManager.newProject()
                        onDismissWelcome()
                    }
                    welcomeActionButton(
                        title: "プロジェクトを開く…",
                        systemImage: "folder"
                    ) {
                        editorManager.showLoadDialog()
                        onDismissWelcome()
                    }
                    welcomeActionButton(
                        title: "一覧を再スキャン",
                        systemImage: "arrow.clockwise"
                    ) {
                        refreshProjectList()
                    }
                }
                .padding(.horizontal, 48)
                .padding(.bottom, 36)
            }
        }
    }

    private func welcomeActionButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: 520)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Right

    private var welcomeRightPane: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.14, blue: 0.22),
                    Color(red: 0.12, green: 0.10, blue: 0.18)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 0) {
                Text("最近のプロジェクト")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 10)

                if isScanning {
                    ProgressView()
                        .scaleEffect(0.85)
                        .padding(.horizontal, 16)
                } else if let scanError {
                    Text(scanError)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.orange.opacity(0.9))
                        .padding(.horizontal, 16)
                } else if recentProjects.isEmpty {
                    Text("見つかりませんでした。\n書類フォルダやデスクトップに `.artia` を保存するとここに表示されます。")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.42))
                        .padding(.horizontal, 16)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(recentProjects) { entry in
                                welcomeRecentRow(entry: entry)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 12)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func welcomeRecentRow(entry: ArtiaProjectListEntry) -> some View {
        Button {
            do {
                try editorManager.loadProject(from: entry.url)
                onDismissWelcome()
            } catch {
                scanError = error.localizedDescription
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(entry.pathLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.cyan.opacity(0.55))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Scan

    private func refreshProjectList() {
        isScanning = true
        scanError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let found = ArtiaProjectDiscovery.recentPackages(maxItems: 24)
            DispatchQueue.main.async {
                recentProjects = found
                isScanning = false
            }
        }
    }

    /// 初回のみ案内: ユーザーがフォルダを選ぶと TCC に「書類」利用が記録される
    private func promptForDocumentsAccessIfNeeded() {
        let key = "artia.editor.didPromptDocumentsFolderAccess"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let alert = NSAlert()
            alert.messageText = "ローカルフォルダへのアクセス"
            alert.informativeText = "WallBlank は「書類」やデスクトップなどから `.artia` プロジェクトを検索します。次のダイアログで「書類」フォルダ（またはよく使う場所）を選択すると、macOS のプライバシー設定に利用が記録され、一覧表示が安定します。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "フォルダを選択")
            alert.addButton(withTitle: "あとで")
            if alert.runModal() == .alertFirstButtonReturn {
                let p = NSOpenPanel()
                p.canChooseFiles = false
                p.canChooseDirectories = true
                p.allowsMultipleSelection = false
                p.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
                p.prompt = "選択"
                p.title = "スキャン対象のフォルダ"
                p.begin { r in
                    guard r == .OK, let url = p.url else { return }
                    UserDefaults.standard.set(url.path, forKey: EditorWelcomeSecurityScope.scanPathKey)
                    if ArtiaProjectDiscovery.supportsSecurityScopedBookmarks,
                       let bookmark = try? url.bookmarkData(
                           options: [.withSecurityScope],
                           includingResourceValuesForKeys: nil,
                           relativeTo: nil
                       ) {
                        UserDefaults.standard.set(bookmark, forKey: EditorWelcomeSecurityScope.scanBookmarkKey)
                    } else {
                        UserDefaults.standard.removeObject(forKey: EditorWelcomeSecurityScope.scanBookmarkKey)
                    }
                    refreshProjectList()
                }
            }
        }
    }
}

// MARK: - Discovery

struct ArtiaProjectListEntry: Identifiable {
    let id: String
    let url: URL
    let displayName: String
    let pathLabel: String
}

enum ArtiaProjectDiscovery {
    private static let fm = FileManager.default

    private struct ScopedRoot {
        let url: URL
        let stopAccessing: Bool
    }

    static let supportsSecurityScopedBookmarks: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let entitlement = SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil)
        return (entitlement as? Bool) == true
    }()

    static func recentPackages(maxItems: Int) -> [ArtiaProjectListEntry] {
        var urls: [URL] = []
        let home = fm.homeDirectoryForCurrentUser
        var scanRoots: [ScopedRoot] = [
            ScopedRoot(url: home.appendingPathComponent("Documents", isDirectory: true), stopAccessing: false),
            ScopedRoot(url: home.appendingPathComponent("Desktop", isDirectory: true), stopAccessing: false),
            ScopedRoot(url: home.appendingPathComponent("WallBlank", isDirectory: true), stopAccessing: false),
            ScopedRoot(url: home.appendingPathComponent("Memory", isDirectory: true), stopAccessing: false)
        ]
        if let extra = resolvedUserSelectedScanRoot() {
            scanRoots.append(extra)
        }
        defer {
            for root in scanRoots where root.stopAccessing {
                root.url.stopAccessingSecurityScopedResource()
            }
        }
        for root in scanRoots {
            if fm.fileExists(atPath: root.url.path) {
                collectArtiaPackages(in: root.url, maxDepth: 6, into: &urls)
            }
        }
        var unique: [URL] = []
        var seen = Set<String>()
        for u in urls {
            let p = u.standardizedFileURL.path
            if seen.insert(p).inserted {
                unique.append(u)
            }
        }
        let sorted = unique.sorted { mtime($0) > mtime($1) }
        return sorted.prefix(maxItems).map { u in
            let name = u.deletingPathExtension().lastPathComponent
            let path = u.path.replacingOccurrences(of: home.path, with: "~")
            return ArtiaProjectListEntry(
                id: u.standardizedFileURL.path,
                url: u,
                displayName: name,
                pathLabel: path
            )
        }
    }

    private static func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func resolvedUserSelectedScanRoot() -> ScopedRoot? {
        let defaults = UserDefaults.standard
        if supportsSecurityScopedBookmarks,
           let data = defaults.data(forKey: EditorWelcomeSecurityScope.scanBookmarkKey) {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                if isStale,
                   let refreshed = try? url.bookmarkData(
                       options: [.withSecurityScope],
                       includingResourceValuesForKeys: nil,
                       relativeTo: nil
                   ) {
                    defaults.set(refreshed, forKey: EditorWelcomeSecurityScope.scanBookmarkKey)
                }
                if url.startAccessingSecurityScopedResource() {
                    defaults.set(url.path, forKey: EditorWelcomeSecurityScope.scanPathKey)
                    return ScopedRoot(url: url, stopAccessing: true)
                }
            }
        }
        if let path = defaults.string(forKey: EditorWelcomeSecurityScope.scanPathKey) {
            return ScopedRoot(url: URL(fileURLWithPath: path, isDirectory: true), stopAccessing: false)
        }
        return nil
    }

    private static func collectArtiaPackages(in root: URL, maxDepth: Int, into out: inout [URL]) {
        guard maxDepth >= 0 else { return }
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        for case let item as URL in e {
            if item.pathExtension.lowercased() == "artia" {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let json = item.appendingPathComponent("project.json")
                guard fm.fileExists(atPath: json.path) else { continue }
                out.append(item)
            }
        }
    }
}
