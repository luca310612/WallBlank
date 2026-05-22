import Foundation

/// Wallpaper Engine 形式のローカル Web 壁紙（`project.json` + エントリ HTML）を解決する。
enum WallpaperEngineWebResolver {

    /// Finder / テキスト / JSON などで Unicode 表記（NFC/NFD）が違っても、親ディレクトリを列挙して実在パスに揃える。
    static func canonicalFilesystemURL(matching url: URL) -> URL? {
        let std = url.standardizedFileURL
        if FileManager.default.fileExists(atPath: std.path) {
            return std
        }
        let parent = std.deletingLastPathComponent()
        let name = std.lastPathComponent
        guard !name.isEmpty, parent.path != std.path else { return nil }

        let normalizedTarget = name.precomposedStringWithCanonicalMapping
        let lowerTarget = normalizedTarget.lowercased()

        guard let items = try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for item in items {
            let n = item.lastPathComponent
            if n == name { return item.standardizedFileURL }
            let nn = n.precomposedStringWithCanonicalMapping
            if nn == normalizedTarget || nn.lowercased() == lowerTarget {
                return item.standardizedFileURL
            }
        }
        return nil
    }

    struct Resolved {
        /// 壁紙プロジェクトのルート（`allowingReadAccessTo` に使う）
        let rootDirectory: URL
        /// `loadFileURL` で開く HTML
        let entryFile: URL
    }

    /// フォルダが Web 壁紙として読めるか判定し、エントリファイルを返す。
    /// - `project.json` があり `type` が `web` なら `file` キーを使用。
    /// - 無い／解釈できない場合はルートの `index.html` があればそれを使う。
    static func resolve(rootDirectory: URL) -> Resolved? {
        let fm = FileManager.default
        guard let root = canonicalFilesystemURL(matching: rootDirectory) else {
            debugLog("[WallpaperEngineWeb] ルートが見つかりません: \(rootDirectory.path)")
            return nil
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }

        let projectURL = root.appendingPathComponent("project.json")
        let projectResolved = canonicalFilesystemURL(matching: projectURL) ?? projectURL
        if fm.fileExists(atPath: projectResolved.path),
           let data = try? Data(contentsOf: projectResolved),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let typeRaw = obj["type"] as? String ?? ""
            let type = typeRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let file = obj["file"] as? String
            let fileTrimmed = file?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Workshop 由来で type に揺れがある／空白付きのケースを吸収
            let treatAsWeb = type == "web"
                || type == "html"
                || (type.isEmpty && fileTrimmed.lowercased().hasSuffix(".html"))
            if treatAsWeb, !fileTrimmed.isEmpty {
                let entry = url(root, appendingProjectRelativeFile: fileTrimmed)
                let entryResolved = canonicalFilesystemURL(matching: entry) ?? entry
                if fm.fileExists(atPath: entryResolved.path) {
                    return Resolved(rootDirectory: root, entryFile: entryResolved)
                }
                debugLog("[WallpaperEngineWeb] project.json の file が見つかりません: \(fileTrimmed) → \(entryResolved.path)")
            }
        }

        let indexURL = root.appendingPathComponent("index.html")
        let indexResolved = canonicalFilesystemURL(matching: indexURL) ?? indexURL
        if fm.fileExists(atPath: indexResolved.path) {
            return Resolved(rootDirectory: root, entryFile: indexResolved)
        }

        return nil
    }

    static func isWebWallpaperRoot(_ url: URL) -> Bool {
        resolve(rootDirectory: url) != nil
    }

    private static func url(_ root: URL, appendingProjectRelativeFile file: String) -> URL {
        let norm = file.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if norm.isEmpty {
            return root
        }
        var out = root
        for part in norm.split(separator: "/") where !part.isEmpty {
            out = out.appendingPathComponent(String(part))
        }
        return out
    }
}
