import XCTest
import Foundation

@testable import WallBlank

/// Phase 8.1: RazerChromaClient のテスト。
/// URLProtocol を差し込んで REST 通信をオフラインでスタブする。
final class RazerChromaClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ChromaMockProtocol.reset()
    }

    override func tearDown() {
        ChromaMockProtocol.reset()
        super.tearDown()
    }

    // MARK: - 純粋関数

    func test_bgrInt_packsBytesAsBGR() {
        // R=0xAA, G=0xBB, B=0xCC → 0x00CCBBAA
        let packed = RazerChromaClient.bgrInt(red: 0xAA, green: 0xBB, blue: 0xCC)
        XCTAssertEqual(packed, 0x00CCBBAA)
    }

    func test_bgrInt_clampsValuesToUnsignedByte() {
        XCTAssertEqual(RazerChromaClient.bgrInt(red: -10, green: 0, blue: 999), 0x00FF0000)
    }

    // MARK: - REST 接続

    @MainActor
    func test_connect_success_setsSession() async {
        ChromaMockProtocol.responder = { request in
            let body = """
            {"sessionid": 42, "uri": "http://localhost:54236/sid=42"}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (body, response)
        }

        let client = makeClient()
        await client.connect()

        XCTAssertTrue(client.isConnected)
        XCTAssertNil(client.lastError)
        XCTAssertEqual(client.sessionURL?.absoluteString, "http://localhost:54236/sid=42")

        // ハートビートタイマー保護のため、テスト終了前に切断する
        ChromaMockProtocol.responder = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
        await client.disconnect()
        XCTAssertFalse(client.isConnected)
    }

    @MainActor
    func test_connect_serverError_marksDisconnected() async {
        ChromaMockProtocol.responder = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
        let client = makeClient()
        await client.connect()
        XCTAssertFalse(client.isConnected)
        XCTAssertNotNil(client.lastError)
    }

    @MainActor
    func test_sendKeyboardSolidColor_putsToSessionEndpoint() async {
        ChromaMockProtocol.responder = { request in
            if request.httpMethod == "POST" {
                let body = """
                {"sessionid": 1, "uri": "http://localhost:54236/sid=1"}
                """.data(using: .utf8)!
                let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (body, r)
            }
            // PUT keyboard
            ChromaMockProtocol.lastPutBody = request.bodyAsData
            ChromaMockProtocol.lastPutPath = request.url?.path
            let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(), r)
        }
        let client = makeClient()
        await client.connect()
        await client.sendKeyboardSolidColor(bgr: 0x00112233)
        XCTAssertEqual(ChromaMockProtocol.lastPutPath, "/sid=1/keyboard")
        let json = try? JSONSerialization.jsonObject(with: ChromaMockProtocol.lastPutBody ?? Data()) as? [String: Any]
        XCTAssertEqual(json?["effect"] as? String, "CHROMA_STATIC")
        if let param = json?["param"] as? [String: Any] {
            XCTAssertEqual(param["color"] as? Int, 0x00112233)
        } else {
            XCTFail("param なし")
        }
        await client.disconnect()
    }

    // MARK: - Helpers

    @MainActor
    private func makeClient() -> RazerChromaClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChromaMockProtocol.self]
        let session = URLSession(configuration: config)
        return RazerChromaClient(
            baseURL: URL(string: "http://localhost:54235")!,
            session: session
        )
    }
}

/// テスト専用の URLProtocol 差し込み。リクエストごとに `responder` を呼んで応答を組み立てる。
final class ChromaMockProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (Data, HTTPURLResponse))?
    nonisolated(unsafe) static var lastPutBody: Data?
    nonisolated(unsafe) static var lastPutPath: String?

    static func reset() {
        responder = nil
        lastPutBody = nil
        lastPutPath = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { responder != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = ChromaMockProtocol.responder else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "ChromaMock", code: -1))
            return
        }
        let (data, response) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension URLRequest {
    /// httpBodyStream / httpBody の両方に対応した body 取得。テスト用。
    var bodyAsData: Data? {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
