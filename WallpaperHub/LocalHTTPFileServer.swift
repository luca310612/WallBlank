import Foundation
import Network

/// 1ディレクトリを `127.0.0.1` で配信する簡易 HTTP サーバ（Wallpaper Engine Web 壁紙向け）
/// - `fetch()` / 相対パス・日本語ファイル名・`<video>` / `<audio>` の Range 要求に耐える
final class LocalHTTPFileServer {

    enum ServerError: Error {
        case failedToStart
        case notRunning
    }

    private struct ByteRange {
        var start: Int
        var endInclusive: Int
    }

    private let rootDirectory: URL
    /// 壁紙ごとの URL 空間を分離して、別フォルダ切替時の WebKit キャッシュ混線を防ぐ。
    private let routePrefix: String
    private var listener: NWListener?
    private(set) var port: UInt16?

    /// 1×1 透明 PNG（Workshop 未導入の thumb/・background/ 大量 404 で壁紙の JS が止まるのを避ける）
    private static let transparentPNG1x1 = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89,
        0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63,
        0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4,
        0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
    ])

    private let workshopHintLock = NSLock()
    private var workshopHintEmitted: Set<String> = []

    /// ローカル配信の実体ファイル用。WebKit がディスクキャッシュしやすくする。
    private static let cacheControlStaticAsset = "public, max-age=31536000"
    private static let cacheControlNoStore = "no-store"

    init(rootDirectory: URL) {
        let canonical = WallpaperEngineWebResolver.canonicalFilesystemURL(matching: rootDirectory) ?? rootDirectory.standardizedFileURL
        self.rootDirectory = canonical
        self.routePrefix = "/artia/\(UUID().uuidString.lowercased())"
    }

    func start() throws {
        if listener != nil { return }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // requiredLocalEndpoint は環境によってリスナーが接続を受け付けない事例があるため付けない

        let newListener = try NWListener(using: params, on: .any)
        newListener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }

        let started = DispatchSemaphore(value: 0)
        var startError: Error?

        newListener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                started.signal()
            case .failed(let err):
                startError = err
                started.signal()
            default:
                break
            }
        }

        newListener.start(queue: .global(qos: .userInitiated))
        self.listener = newListener

        started.wait()

        if let startError { throw startError }
        guard case .ready = newListener.state else { throw ServerError.failedToStart }
        guard let p = newListener.port?.rawValue else { throw ServerError.failedToStart }
        self.port = p
        debugLog("[LocalHTTP] started on 127.0.0.1:\(p) root=\(rootDirectory.path)")
        artiaWebLog("[LocalHTTP] started port=\(p) root=\(rootDirectory.path)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    func makeURL(path: String) throws -> URL {
        guard let port else { throw ServerError.notRunning }
        var p = path
        if !p.hasPrefix("/") { p = "/" + p }
        p = routePrefix + p
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = "127.0.0.1"
        comps.port = Int(port)
        // 日本語など非 ASCII セグメントを必ずパーセントエンコード（WKWebView のリクエストと一致させる）
        if p == "/" {
            comps.percentEncodedPath = "/"
        } else {
            let segments = p.split(separator: "/").map { String($0) }
            let encoded = segments.map { seg -> String in
                seg.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? seg
            }
            comps.percentEncodedPath = "/" + encoded.joined(separator: "/")
        }
        guard let url = comps.url else { throw ServerError.notRunning }
        return url
    }

    // MARK: - Connection

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        receiveRequest(on: conn, buffer: Data())
    }

    private func receiveRequest(on conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                debugLog("[LocalHTTP] receive error: \(error)")
                artiaWebLog("[LocalHTTP] receive error: \(String(describing: error))")
                conn.cancel()
                return
            }
            var buf = buffer
            if let data { buf.append(data) }

            if let range = Self.headerDelimiterRange(in: buf) {
                let head = buf.subdata(in: buf.startIndex..<range.lowerBound)
                self.respond(to: head, on: conn)
                return
            }

            if isComplete {
                conn.cancel()
                return
            }

            self.receiveRequest(on: conn, buffer: buf)
        }
    }

    private static func headerDelimiterRange(in buf: Data) -> Range<Data.Index>? {
        if let r = buf.range(of: Data("\r\n\r\n".utf8)) { return r }
        return buf.range(of: Data("\n\n".utf8))
    }

    private func respond(to requestHead: Data, on conn: NWConnection) {
        guard let headStr = String(data: requestHead, encoding: .utf8) else {
            artiaWebLog("[LocalHTTP] 400 bad request (non-utf8 head, \(requestHead.count) bytes)")
            send(status: 400, body: "bad request", type: "text/plain; charset=utf-8", on: conn)
            return
        }
        let normalized = headStr.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else {
            send(status: 400, body: "bad request", type: "text/plain; charset=utf-8", on: conn)
            return
        }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else {
            send(status: 400, body: "bad request", type: "text/plain; charset=utf-8", on: conn)
            return
        }

        let method = String(parts[0]).uppercased()
        let rawPath = String(parts[1])

        guard method == "GET" || method == "HEAD" else {
            send(status: 405, body: "method not allowed", type: "text/plain; charset=utf-8", on: conn)
            return
        }

        let pathPart = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawPath
        let decoded = pathPart.removingPercentEncoding ?? pathPart

        let sanitized = sanitizePath(decoded)
        let routedPath = stripRoutePrefix(fromSanitizedPath: sanitized)
        guard let mapped = mapToFileURL(routedPath) else {
            artiaWebLog("[LocalHTTP] 404 path outside root: \(routedPath)")
            send(status: 404, body: "not found", type: "text/plain; charset=utf-8", on: conn)
            return
        }

        let fileURL = resolveUnderRoot(mapped: mapped)
        guard let fileURL else {
            artiaWebLog("[LocalHTTP] 404 path outside root (resolved): \(routedPath)")
            send(status: 404, body: "not found", type: "text/plain; charset=utf-8", on: conn)
            return
        }

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
            let index = fileURL.appendingPathComponent("index.html")
            if FileManager.default.fileExists(atPath: index.path) {
                sendFile(at: index, method: method, rangeHeaderLines: lines, on: conn)
            } else {
                send(status: 403, body: "forbidden", type: "text/plain; charset=utf-8", on: conn)
            }
            return
        }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            sendFile(at: fileURL, method: method, rangeHeaderLines: lines, on: conn)
        } else if shouldServeImagePlaceholder(forSanitizedPath: routedPath) {
            sendPlaceholderPNG(method: method, rangeHeaderLines: lines, on: conn)
        } else {
            emitWorkshopHintIfNeeded(forMissingPath: routedPath)
            artiaWebLog("[LocalHTTP] 404 missing file: \(routedPath)")
            send(status: 404, body: "not found", type: "text/plain; charset=utf-8", on: conn)
        }
    }

    private func sanitizePath(_ path: String) -> String {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true)
        var out: [Substring] = []
        for c in comps {
            if c == "." { continue }
            if c == ".." {
                _ = out.popLast()
                continue
            }
            out.append(c)
        }
        return "/" + out.joined(separator: "/")
    }

    private func stripRoutePrefix(fromSanitizedPath sanitizedPath: String) -> String {
        if sanitizedPath == routePrefix {
            return "/"
        }
        let prefixWithSlash = routePrefix + "/"
        guard sanitizedPath.hasPrefix(prefixWithSlash) else {
            return sanitizedPath
        }
        let stripped = String(sanitizedPath.dropFirst(routePrefix.count))
        return stripped.isEmpty ? "/" : stripped
    }

    private func mapToFileURL(_ sanitizedPath: String) -> URL? {
        let rel = sanitizedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let target = rel.isEmpty ? rootDirectory : rootDirectory.appendingPathComponent(rel)
        let std = target.standardizedFileURL
        let rootPath = rootDirectory.path.hasSuffix("/") ? rootDirectory.path : rootDirectory.path + "/"
        if std.path == rootDirectory.path || std.path.hasPrefix(rootPath) {
            return std
        }
        return nil
    }

    private func isStrictlyUnderRoot(_ url: URL) -> Bool {
        let std = url.standardizedFileURL
        let rootPath = rootDirectory.path.hasSuffix("/") ? rootDirectory.path : rootDirectory.path + "/"
        return std.path == rootDirectory.path || std.path.hasPrefix(rootPath)
    }

    /// NFC/NFD など実ディレクトリ表記に寄せつつ、ルート外へ出ないことだけ確認する。
    private func resolveUnderRoot(mapped: URL) -> URL? {
        let candidate = WallpaperEngineWebResolver.canonicalFilesystemURL(matching: mapped) ?? mapped
        guard isStrictlyUnderRoot(candidate) else { return nil }
        return candidate.standardizedFileURL
    }

    private func shouldServeImagePlaceholder(forSanitizedPath sanitized: String) -> Bool {
        let rel = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let lower = rel.lowercased()
        guard lower.hasPrefix("thumb/") || lower.hasPrefix("background/") else { return false }
        let ext = (rel as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "webp", "gif"].contains(ext)
    }

    private func emitWorkshopHintIfNeeded(forMissingPath sanitized: String) {
        let rel = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix: String? = {
            if rel.hasPrefix("music/") { return "music/" }
            if rel.hasPrefix("mv/") { return "mv/" }
            if rel.hasPrefix("cover/") { return "cover/" }
            return nil
        }()
        guard let p = prefix else { return }
        workshopHintLock.lock()
        defer { workshopHintLock.unlock() }
        guard !workshopHintEmitted.contains(p) else { return }
        workshopHintEmitted.insert(p)
        artiaWebLog("[LocalHTTP] \(p) が見つかりません。Steam Workshop でこのアイテムを完全にダウンロードし、壁紙フォルダ直下に music・mv・cover（および thumb・background）を置いてください。")
    }

    private func sendPlaceholderPNG(method: String, rangeHeaderLines: [Substring], on conn: NWConnection) {
        let body = Self.transparentPNG1x1
        let fileLength = body.count
        let mime = "image/png"

        let requested = parseSingleByteRange(from: rangeHeaderLines, fileLength: fileLength)
        if let r = requested, (r.start >= fileLength || r.start < 0 || r.endInclusive < r.start) {
            send416(totalLength: fileLength, on: conn)
            return
        }

        let status: Int
        let byteStart: Int
        let bodyLength: Int
        var contentRange: String?

        if let r = requested {
            status = 206
            byteStart = r.start
            bodyLength = r.endInclusive - r.start + 1
            contentRange = "bytes \(byteStart)-\(r.endInclusive)/\(fileLength)"
        } else {
            status = 200
            byteStart = 0
            bodyLength = fileLength
            contentRange = nil
        }

        let extra = ["X-Artia-Placeholder: 1"]
        let headLines = responseLines(
            status: status,
            reason: httpReason(for: status),
            contentType: mime,
            contentLength: bodyLength,
            contentRange: contentRange,
            acceptRanges: true,
            extraHeaders: extra,
            cacheControl: Self.cacheControlStaticAsset
        )
        let headerData = Data((headLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)

        if method == "HEAD" {
            conn.send(content: headerData, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in
                conn.cancel()
            })
            return
        }

        let slice = body.subdata(in: byteStart..<(byteStart + bodyLength))
        var payload = headerData
        payload.append(slice)
        conn.send(content: payload, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    /// `Range: bytes=…`（1 区間のみ）。不正・複数区間は無視して全文応答。
    private func parseSingleByteRange(from lines: [Substring], fileLength: Int) -> ByteRange? {
        guard fileLength > 0 else { return nil }
        for line in lines.dropFirst() {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("range:") else { continue }
            let value = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)
            guard value.lowercased().hasPrefix("bytes=") else { continue }
            var spec = String(value.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            if let comma = spec.firstIndex(of: ",") {
                spec = String(spec[..<comma])
            }
            if spec.hasPrefix("-") {
                let n = Int(spec.dropFirst()) ?? 0
                if n <= 0 { return nil }
                let start = max(0, fileLength - n)
                return ByteRange(start: start, endInclusive: fileLength - 1)
            }
            let halves = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard halves.count == 2 else { continue }
            let startStr = String(halves[0])
            let endStr = String(halves[1])
            let start: Int
            if startStr.isEmpty {
                start = 0
            } else {
                guard let s = Int(startStr) else { continue }
                start = s
            }
            let endInclusive: Int
            if endStr.isEmpty {
                endInclusive = fileLength - 1
            } else {
                guard let e = Int(endStr) else { continue }
                endInclusive = e
            }
            if start > endInclusive || start >= fileLength { return nil }
            return ByteRange(start: start, endInclusive: min(endInclusive, fileLength - 1))
        }
        return nil
    }

    private func send416(totalLength: Int, on conn: NWConnection) {
        let lines = responseLines(
            status: 416,
            reason: "Range Not Satisfiable",
            contentType: "text/plain; charset=utf-8",
            contentLength: 0,
            contentRange: "bytes */\(totalLength)",
            acceptRanges: true,
            extraHeaders: [],
            cacheControl: Self.cacheControlNoStore
        )
        let block = lines.joined(separator: "\r\n") + "\r\n\r\n"
        conn.send(content: Data(block.utf8), contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    /// 1チャンクのサイズ。<video>/<audio> の Range 取得を即座に返しつつ、
    /// メモリピークを 256KB に抑えるバランス値。
    private static let streamChunkSize = 256 * 1024

    private func sendFile(at fileURL: URL, method: String, rangeHeaderLines: [Substring], on conn: NWConnection) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
              let sizeNum = attrs[.size] as? NSNumber else {
            send(status: 500, body: "failed to stat", type: "text/plain; charset=utf-8", on: conn)
            return
        }
        let fileLength = sizeNum.intValue
        let mime = mimeType(for: fileURL)

        let requested = parseSingleByteRange(from: rangeHeaderLines, fileLength: fileLength)
        if let r = requested, (r.start >= fileLength || r.start < 0 || r.endInclusive < r.start) {
            send416(totalLength: fileLength, on: conn)
            return
        }

        let status: Int
        let byteStart: Int
        let bodyLength: Int
        var contentRange: String?

        if let r = requested {
            status = 206
            byteStart = r.start
            bodyLength = r.endInclusive - r.start + 1
            contentRange = "bytes \(byteStart)-\(r.endInclusive)/\(fileLength)"
        } else {
            status = 200
            byteStart = 0
            bodyLength = fileLength
            contentRange = nil
        }

        let headLines = responseLines(
            status: status,
            reason: httpReason(for: status),
            contentType: mime,
            contentLength: bodyLength,
            contentRange: contentRange,
            acceptRanges: true,
            extraHeaders: [],
            cacheControl: Self.cacheControlStaticAsset
        )
        let headerData = Data((headLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)

        if method == "HEAD" {
            conn.send(content: headerData, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in
                conn.cancel()
            })
            return
        }

        // 空ボディ（0 byte ファイル / 空 range）は head のみ返して終了
        if bodyLength == 0 {
            conn.send(content: headerData, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in
                conn.cancel()
            })
            return
        }

        // 大ファイルを丸ごとメモリに展開すると <video> の Range 応答が詰まり、loadeddata が永久に来ないため
        // 256KB チャンクのストリーミング送信に切り替える。
        streamFile(at: fileURL, byteStart: byteStart, bodyLength: bodyLength, headerData: headerData, on: conn)
    }

    private func streamFile(at fileURL: URL, byteStart: Int, bodyLength: Int, headerData: Data, on conn: NWConnection) {
        guard let fh = try? FileHandle(forReadingFrom: fileURL) else {
            send(status: 500, body: "failed to read", type: "text/plain; charset=utf-8", on: conn)
            return
        }
        do {
            try fh.seek(toOffset: UInt64(byteStart))
        } catch {
            try? fh.close()
            send(status: 500, body: "failed to seek", type: "text/plain; charset=utf-8", on: conn)
            return
        }

        // ヘッダ単独で先送りし、完了後に初回チャンクを流す（背圧制御で並列リクエストを詰まらせない）
        conn.send(content: headerData, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { [weak self] error in
            if let error {
                debugLog("[LocalHTTP] header send error: \(error)")
                try? fh.close()
                conn.cancel()
                return
            }
            self?.streamNextChunk(fileHandle: fh, remaining: bodyLength, on: conn)
        })
    }

    private func streamNextChunk(fileHandle fh: FileHandle, remaining: Int, on conn: NWConnection) {
        if remaining <= 0 {
            try? fh.close()
            conn.send(content: nil, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in
                conn.cancel()
            })
            return
        }

        let chunkSize = min(Self.streamChunkSize, remaining)
        let chunk = fh.readData(ofLength: chunkSize)
        if chunk.isEmpty {
            // ファイルが想定より短かった: ここで打ち切る
            try? fh.close()
            conn.send(content: nil, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in
                conn.cancel()
            })
            return
        }

        let nextRemaining = remaining - chunk.count
        let isLast = (nextRemaining <= 0)

        conn.send(content: chunk, contentContext: .defaultMessage, isComplete: isLast, completion: .contentProcessed { [weak self] error in
            if let error {
                debugLog("[LocalHTTP] body send error (remaining=\(nextRemaining)): \(error)")
                try? fh.close()
                conn.cancel()
                return
            }
            if isLast {
                try? fh.close()
                conn.cancel()
                return
            }
            self?.streamNextChunk(fileHandle: fh, remaining: nextRemaining, on: conn)
        })
    }

    private func send(status: Int, body: String, type: String, on conn: NWConnection) {
        let data = Data(body.utf8)
        let lines = responseLines(
            status: status,
            reason: httpReason(for: status),
            contentType: type,
            contentLength: data.count,
            contentRange: nil,
            acceptRanges: false,
            extraHeaders: [],
            cacheControl: Self.cacheControlNoStore
        )
        var payload = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        payload.append(data)
        conn.send(content: payload, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func httpReason(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 416: "Range Not Satisfiable"
        case 500: "Internal Server Error"
        default: "Error"
        }
    }

    private func httpDateRFC9110() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return fmt.string(from: Date())
    }

    /// ディスク上の静的ファイルは長期キャッシュ可（同一セッション内の再読込・サブリソースの再取得を高速化）。
    private func responseLines(
        status: Int,
        reason: String,
        contentType: String,
        contentLength: Int,
        contentRange: String?,
        acceptRanges: Bool,
        extraHeaders: [String],
        cacheControl: String
    ) -> [String] {
        var lines: [String] = [
            "HTTP/1.1 \(status) \(reason)",
            "Date: \(httpDateRFC9110())",
            "Server: ArtiaLocal/1",
            "Connection: close",
            "Content-Type: \(contentType)",
            "Content-Length: \(contentLength)",
            "Access-Control-Allow-Origin: *",
            "Cache-Control: \(cacheControl)",
        ]
        if acceptRanges {
            lines.append("Accept-Ranges: bytes")
        }
        if let contentRange {
            lines.append("Content-Range: \(contentRange)")
        }
        lines.append(contentsOf: extraHeaders)
        return lines
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
