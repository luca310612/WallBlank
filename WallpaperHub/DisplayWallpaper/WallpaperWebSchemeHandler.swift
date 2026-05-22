import Foundation
import WebKit

// MARK: - Web 壁紙用カスタムスキーム配信
// Why: Wallpaper Engine 形式の Web 壁紙を `WKURLSchemeHandler` から直接供給する。
// `file://` 制限を避けつつ、ローカルHTTPサーバーを常時起動しない。

/// Wallpaper Engine 形式の Web 壁紙を `WKURLSchemeHandler` から直接供給する。
/// `file://` 制限を避けつつ、ローカルHTTPサーバーを常時起動しない。
final class WallpaperWebSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "artia-web"

    private struct ByteRange {
        var start: Int
        var endInclusive: Int
    }

    private let rootDirectory: URL
    private let routeHost: String
    private let workQueue = DispatchQueue(label: "com.artia.web-scheme-handler", qos: .userInitiated)
    private let taskLock = NSLock()
    private let workshopHintLock = NSLock()

    private var stoppedTaskIDs: Set<ObjectIdentifier> = []
    private var workshopHintEmitted: Set<String> = []

    private static let transparentPNG1x1 = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89,
        0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63,
        0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4,
        0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
    ])

    private static let cacheControlStaticAsset = "public, max-age=31536000"
    private static let cacheControlNoStore = "no-store"
    private static let maxMemoryCacheBytes = 2 * 1024 * 1024
    private static let memoryCacheTotalCostLimit = 32 * 1024 * 1024
    private static let sharedMemoryCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = memoryCacheTotalCostLimit
        return cache
    }()

    init(rootDirectory: URL) {
        let canonical = WallpaperEngineWebResolver.canonicalFilesystemURL(matching: rootDirectory) ?? rootDirectory.standardizedFileURL
        self.rootDirectory = canonical
        self.routeHost = "wallpaper-\(UUID().uuidString.lowercased())"
        super.init()
    }

    func makeURL(path: String) -> URL? {
        var normalized = path
        if !normalized.hasPrefix("/") {
            normalized = "/" + normalized
        }

        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = routeHost
        if normalized == "/" {
            components.percentEncodedPath = "/"
        } else {
            let segments = normalized.split(separator: "/").map(String.init)
            let encoded = segments.map { segment in
                segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? segment
            }
            components.percentEncodedPath = "/" + encoded.joined(separator: "/")
        }
        return components.url
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        taskLock.lock()
        stoppedTaskIDs.remove(taskID)
        taskLock.unlock()

        workQueue.async { [weak self] in
            self?.respond(to: urlSchemeTask)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        taskLock.lock()
        stoppedTaskIDs.insert(taskID)
        taskLock.unlock()
    }

    private func respond(to task: WKURLSchemeTask) {
        guard let requestURL = task.request.url else {
            finish(task, statusCode: 400, contentType: "text/plain; charset=utf-8", body: Data("bad request".utf8))
            return
        }

        guard requestURL.scheme?.lowercased() == Self.scheme,
              requestURL.host?.lowercased() == routeHost else {
            finish(task, statusCode: 404, contentType: "text/plain; charset=utf-8", body: Data("not found".utf8))
            return
        }

        let method = (task.request.httpMethod ?? "GET").uppercased()
        guard method == "GET" || method == "HEAD" else {
            finish(task, statusCode: 405, contentType: "text/plain; charset=utf-8", body: Data("method not allowed".utf8))
            return
        }

        let sanitized = sanitizePath(requestURL.path.removingPercentEncoding ?? requestURL.path)
        guard let mapped = mapToFileURL(sanitized),
              let resolved = resolveUnderRoot(mapped: mapped) else {
            artiaWebLog("[WebScheme] 404 path outside root: \(sanitized)")
            finish(task, statusCode: 404, contentType: "text/plain; charset=utf-8", body: Data("not found".utf8))
            return
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let indexURL = resolved.appendingPathComponent("index.html")
            if FileManager.default.fileExists(atPath: indexURL.path) {
                serveFile(indexURL, for: task, method: method)
            } else {
                finish(task, statusCode: 403, contentType: "text/plain; charset=utf-8", body: Data("forbidden".utf8))
            }
            return
        }

        if FileManager.default.fileExists(atPath: resolved.path) {
            serveFile(resolved, for: task, method: method)
        } else if shouldServeImagePlaceholder(forSanitizedPath: sanitized) {
            servePlaceholder(for: task, method: method)
        } else {
            emitWorkshopHintIfNeeded(forMissingPath: sanitized)
            artiaWebLog("[WebScheme] 404 missing file: \(sanitized)")
            finish(task, statusCode: 404, contentType: "text/plain; charset=utf-8", body: Data("not found".utf8))
        }
    }

    private func servePlaceholder(for task: WKURLSchemeTask, method: String) {
        let fileLength = Self.transparentPNG1x1.count
        let requestedRange = parseSingleByteRange(from: task.request.value(forHTTPHeaderField: "Range"), fileLength: fileLength)
        if let range = requestedRange, (range.start >= fileLength || range.start < 0 || range.endInclusive < range.start) {
            finish416(task, totalLength: fileLength)
            return
        }

        let byteStart = requestedRange?.start ?? 0
        let byteEnd = requestedRange?.endInclusive ?? (fileLength - 1)
        let responseData = Self.transparentPNG1x1.subdata(in: byteStart..<(byteEnd + 1))
        let headers = responseHeaders(
            contentType: "image/png",
            contentLength: responseData.count,
            contentRange: requestedRange.map { _ in "bytes \(byteStart)-\(byteEnd)/\(fileLength)" },
            acceptRanges: true,
            extraHeaders: ["X-Artia-Placeholder": "1"],
            cacheControl: Self.cacheControlStaticAsset
        )
        let statusCode = requestedRange == nil ? 200 : 206
        finish(task, statusCode: statusCode, contentType: "image/png", body: method == "HEAD" ? nil : responseData, headers: headers)
    }

    private func serveFile(_ fileURL: URL, for task: WKURLSchemeTask, method: String) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let sizeNum = attrs[.size] as? NSNumber else {
            finish(task, statusCode: 500, contentType: "text/plain; charset=utf-8", body: Data("failed to stat".utf8))
            return
        }

        let fileLength = sizeNum.intValue
        let requestedRange = parseSingleByteRange(from: task.request.value(forHTTPHeaderField: "Range"), fileLength: fileLength)
        if let range = requestedRange, (range.start >= fileLength || range.start < 0 || range.endInclusive < range.start) {
            finish416(task, totalLength: fileLength)
            return
        }

        let byteStart = requestedRange?.start ?? 0
        let byteEnd = requestedRange?.endInclusive ?? (fileLength - 1)
        let bodyLength = max(0, byteEnd - byteStart + 1)
        let mime = mimeType(for: fileURL)

        let responseBody: Data?
        if method == "HEAD" {
            responseBody = nil
        } else if requestedRange == nil,
                  fileLength <= Self.maxMemoryCacheBytes,
                  let cacheKey = cacheKey(for: fileURL, attrs: attrs),
                  let cached = Self.sharedMemoryCache.object(forKey: cacheKey as NSString) {
            responseBody = cached as Data
        } else {
            guard let loaded = readFileSlice(at: fileURL, start: byteStart, length: bodyLength) else {
                finish(task, statusCode: 500, contentType: "text/plain; charset=utf-8", body: Data("failed to read".utf8))
                return
            }
            if requestedRange == nil,
               loaded.count == fileLength,
               fileLength <= Self.maxMemoryCacheBytes,
               let cacheKey = cacheKey(for: fileURL, attrs: attrs) {
                Self.sharedMemoryCache.setObject(loaded as NSData, forKey: cacheKey as NSString, cost: loaded.count)
            }
            responseBody = loaded
        }

        let headers = responseHeaders(
            contentType: mime,
            contentLength: bodyLength,
            contentRange: requestedRange.map { _ in "bytes \(byteStart)-\(byteEnd)/\(fileLength)" },
            acceptRanges: true,
            extraHeaders: [:],
            cacheControl: Self.cacheControlStaticAsset
        )
        let statusCode = requestedRange == nil ? 200 : 206
        finish(task, statusCode: statusCode, contentType: mime, body: responseBody, headers: headers)
    }

    private func cacheKey(for fileURL: URL, attrs: [FileAttributeKey: Any]) -> String? {
        guard let sizeNum = attrs[.size] as? NSNumber else { return nil }
        let modTime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(fileURL.path)#\(sizeNum.int64Value)#\(modTime)"
    }

    private func readFileSlice(at fileURL: URL, start: Int, length: Int) -> Data? {
        if start == 0,
           let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let sizeNum = attrs[.size] as? NSNumber,
           sizeNum.intValue == length,
           length <= Self.maxMemoryCacheBytes,
           let mapped = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) {
            return mapped
        }
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? fileHandle.close() }

        do {
            try fileHandle.seek(toOffset: UInt64(start))
        } catch {
            return nil
        }

        let data = fileHandle.readData(ofLength: length)
        return data.count == length ? data : nil
    }

    private func finish416(_ task: WKURLSchemeTask, totalLength: Int) {
        finish(
            task,
            statusCode: 416,
            contentType: "text/plain; charset=utf-8",
            body: nil,
            headers: responseHeaders(
                contentType: "text/plain; charset=utf-8",
                contentLength: 0,
                contentRange: "bytes */\(totalLength)",
                acceptRanges: true,
                extraHeaders: [:],
                cacheControl: Self.cacheControlNoStore
            )
        )
    }

    private func finish(
        _ task: WKURLSchemeTask,
        statusCode: Int,
        contentType: String,
        body: Data?,
        headers: [String: String]? = nil
    ) {
        guard !isStopped(task) else { return }
        guard let url = task.request.url else { return }

        var responseHeaders = headers ?? [:]
        responseHeaders["Content-Type"] = responseHeaders["Content-Type"] ?? contentType
        responseHeaders["Content-Length"] = responseHeaders["Content-Length"] ?? "\(body?.count ?? 0)"

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: responseHeaders
        ) else {
            task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown))
            markStopped(task)
            return
        }

        task.didReceive(response)
        if let body, !body.isEmpty, !isStopped(task) {
            task.didReceive(body)
        }
        if !isStopped(task) {
            task.didFinish()
        }
        markStopped(task)
    }

    private func isStopped(_ task: WKURLSchemeTask) -> Bool {
        let taskID = ObjectIdentifier(task as AnyObject)
        taskLock.lock()
        defer { taskLock.unlock() }
        return stoppedTaskIDs.contains(taskID)
    }

    private func markStopped(_ task: WKURLSchemeTask) {
        let taskID = ObjectIdentifier(task as AnyObject)
        taskLock.lock()
        stoppedTaskIDs.insert(taskID)
        taskLock.unlock()
    }

    private func sanitizePath(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        var output: [Substring] = []
        for component in components {
            if component == "." { continue }
            if component == ".." {
                _ = output.popLast()
                continue
            }
            output.append(component)
        }
        return "/" + output.joined(separator: "/")
    }

    private func mapToFileURL(_ sanitizedPath: String) -> URL? {
        let relative = sanitizedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let target = relative.isEmpty ? rootDirectory : rootDirectory.appendingPathComponent(relative)
        let standardized = target.standardizedFileURL
        let rootPath = rootDirectory.path.hasSuffix("/") ? rootDirectory.path : rootDirectory.path + "/"
        if standardized.path == rootDirectory.path || standardized.path.hasPrefix(rootPath) {
            return standardized
        }
        return nil
    }

    private func resolveUnderRoot(mapped: URL) -> URL? {
        let candidate = WallpaperEngineWebResolver.canonicalFilesystemURL(matching: mapped) ?? mapped
        let standardized = candidate.standardizedFileURL
        let rootPath = rootDirectory.path.hasSuffix("/") ? rootDirectory.path : rootDirectory.path + "/"
        guard standardized.path == rootDirectory.path || standardized.path.hasPrefix(rootPath) else { return nil }
        return standardized
    }

    private func shouldServeImagePlaceholder(forSanitizedPath sanitized: String) -> Bool {
        let relative = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let lower = relative.lowercased()
        guard lower.hasPrefix("thumb/") || lower.hasPrefix("background/") else { return false }
        let ext = (relative as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "webp", "gif"].contains(ext)
    }

    private func emitWorkshopHintIfNeeded(forMissingPath sanitized: String) {
        let relative = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix: String? = {
            if relative.hasPrefix("music/") { return "music/" }
            if relative.hasPrefix("mv/") { return "mv/" }
            if relative.hasPrefix("cover/") { return "cover/" }
            return nil
        }()
        guard let prefix else { return }

        workshopHintLock.lock()
        defer { workshopHintLock.unlock() }
        guard !workshopHintEmitted.contains(prefix) else { return }
        workshopHintEmitted.insert(prefix)
        artiaWebLog("[WebScheme] \(prefix) が見つかりません。Steam Workshop でこのアイテムを完全にダウンロードし、壁紙フォルダ直下に music・mv・cover（および thumb・background）を置いてください。")
    }

    private func parseSingleByteRange(from header: String?, fileLength: Int) -> ByteRange? {
        guard fileLength > 0,
              let header = header?.trimmingCharacters(in: .whitespaces),
              header.lowercased().hasPrefix("bytes=") else {
            return nil
        }

        var spec = String(header.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        if let comma = spec.firstIndex(of: ",") {
            spec = String(spec[..<comma])
        }

        if spec.hasPrefix("-") {
            let suffixLength = Int(spec.dropFirst()) ?? 0
            guard suffixLength > 0 else { return nil }
            let start = max(0, fileLength - suffixLength)
            return ByteRange(start: start, endInclusive: fileLength - 1)
        }

        let halves = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }

        let startString = String(halves[0])
        let endString = String(halves[1])
        let start = Int(startString) ?? 0
        let endInclusive = endString.isEmpty ? (fileLength - 1) : (Int(endString) ?? -1)
        guard start >= 0, start <= endInclusive, start < fileLength else { return nil }
        return ByteRange(start: start, endInclusive: min(endInclusive, fileLength - 1))
    }

    private func responseHeaders(
        contentType: String,
        contentLength: Int,
        contentRange: String?,
        acceptRanges: Bool,
        extraHeaders: [String: String],
        cacheControl: String
    ) -> [String: String] {
        var headers: [String: String] = [
            "Content-Type": contentType,
            "Content-Length": "\(contentLength)",
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": cacheControl,
        ]
        if acceptRanges {
            headers["Accept-Ranges"] = "bytes"
        }
        if let contentRange {
            headers["Content-Range"] = contentRange
        }
        for (key, value) in extraHeaders {
            headers[key] = value
        }
        return headers
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "opus": return "audio/opus"
        case "ogg": return "audio/ogg"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "srt": return "application/x-subrip; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
