import XCTest
import Darwin
@testable import ImprimaCore

/// Raw POSIX TCP client used by the tests.
private final class RawClient {
    let fd: Int32
    private var buf: [UInt8] = []

    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc != 0 {
            let e = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(e))
        }
    }

    func close() { Darwin.close(fd) }

    func send(_ text: String) { send(Array(text.utf8)) }
    func send(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.send(fd, raw.baseAddress! + off, raw.count - off, 0)
                if n <= 0 { return }
                off += n
            }
        }
    }

    /// Returns nil at EOF.
    func readByte() -> UInt8? {
        if buf.isEmpty {
            var tmp = [UInt8](repeating: 0, count: 64 * 1024)
            let n = recv(fd, &tmp, tmp.count, 0)
            if n <= 0 { return nil }
            buf = Array(tmp[0..<n])
        }
        return buf.removeFirst()
    }

    func readLine() -> String {
        var bytes: [UInt8] = []
        while let c = readByte(), c != 0x0A { if c != 0x0D { bytes.append(c) } }
        return String(decoding: bytes, as: UTF8.self)
    }

    struct Resp { let status: Int; let headers: [String: String]; let body: [UInt8] }

    func readResponse() -> Resp {
        let statusLine = readLine()
        let parts = statusLine.split(separator: " ")
        let status = parts.count > 1 ? Int(parts[1]) ?? -1 : -1
        var h: [String: String] = [:]
        while true {
            let l = readLine()
            if l.isEmpty { break }
            guard let idx = l.firstIndex(of: ":") else { continue }
            h[l[..<idx].lowercased()] = l[l.index(after: idx)...].trimmingCharacters(in: .whitespaces)
        }
        let len = Int(h["content-length"] ?? "0") ?? 0
        var body: [UInt8] = []
        while body.count < len, let b = readByte() { body.append(b) }
        return Resp(status: status, headers: h, body: body)
    }
}

final class HttpServerTests: XCTestCase {
    private var server: HttpServer!
    private let stateLock = NSLock()
    private var _lastRequest: (method: String, path: String, headers: [String: String])?
    private var _lastBody = Data()
    private var _handler: (HttpRequest) -> HttpResponse = { _ in .text(200, "hi") }

    private var lastRequest: (method: String, path: String, headers: [String: String])? {
        stateLock.lock(); defer { stateLock.unlock() }; return _lastRequest
    }
    private var lastBody: Data {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _lastBody }
        set { stateLock.lock(); _lastBody = newValue; stateLock.unlock() }
    }
    private var handlerImpl: (HttpRequest) -> HttpResponse {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _handler }
        set { stateLock.lock(); _handler = newValue; stateLock.unlock() }
    }

    override func setUpWithError() throws {
        server = HttpServer(port: 0) { [unowned self] req in
            stateLock.lock(); _lastRequest = (req.method, req.path, req.headers); stateLock.unlock()
            return handlerImpl(req)
        }
        try server.start()
        XCTAssertNotEqual(server.boundPort, 0)
    }

    override func tearDown() {
        server.stop()
        server = nil
    }

    private func connect() throws -> RawClient { try RawClient(port: server.boundPort) }

    func testGetNoBody() throws {
        handlerImpl = { _ in .text(200, "hello") }
        let c = try connect(); defer { c.close() }
        c.send("GET /a/b?x=1 HTTP/1.1\r\nHost: Example\r\nX-Custom-Header:  Val \r\n\r\n")
        let r = c.readResponse()
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.headers["content-length"], "5")
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "hello")
        XCTAssertEqual(r.headers["connection"], "keep-alive")
        XCTAssertEqual(r.headers["server"], "Imprima/0.1")
        XCTAssertNotNil(r.headers["content-type"])
        let req = try XCTUnwrap(lastRequest)
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/a/b?x=1")
        XCTAssertEqual(req.headers["host"], "Example")
        XCTAssertEqual(req.headers["x-custom-header"], "Val")
    }

    func testAbsoluteFormPathStripped() throws {
        let c = try connect(); defer { c.close() }
        c.send("GET http://printer.local:631/ipp/print HTTP/1.1\r\n\r\n")
        XCTAssertEqual(c.readResponse().status, 200)
        XCTAssertEqual(lastRequest?.path, "/ipp/print")
    }

    func testPostContentLength() throws {
        var rng = SystemRandomNumberGenerator()
        let data = (0..<(100 * 1024)).map { _ in UInt8.random(in: 0...255, using: &rng) }
        handlerImpl = { [unowned self] req in
            lastBody = (try? req.body.readToEnd()) ?? Data()
            return HttpResponse(status: 200)
        }
        let c = try connect(); defer { c.close() }
        c.send("POST /ipp HTTP/1.1\r\nContent-Type: application/ipp\r\nContent-Length: \(data.count)\r\n\r\n")
        c.send(data)
        XCTAssertEqual(c.readResponse().status, 200)
        XCTAssertEqual(lastBody, Data(data))
    }

    func testPostChunked() throws {
        handlerImpl = { [unowned self] req in
            lastBody = (try? req.body.readToEnd()) ?? Data()
            return HttpResponse(status: 200)
        }
        let c = try connect(); defer { c.close() }
        c.send("POST /ipp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" +
               "5\r\nhello\r\n6;foo=bar\r\n world\r\nA\r\n0123456789\r\n0\r\nTrailer: x\r\n\r\n")
        XCTAssertEqual(c.readResponse().status, 200)
        XCTAssertEqual(String(decoding: lastBody, as: UTF8.self), "hello world0123456789")
    }

    func testExpectContinue() throws {
        handlerImpl = { [unowned self] req in
            lastBody = (try? req.body.readToEnd()) ?? Data()
            return HttpResponse(status: 200)
        }
        let c = try connect(); defer { c.close() }
        c.send("POST /ipp HTTP/1.1\r\nExpect: 100-Continue\r\nContent-Length: 4\r\n\r\n")
        XCTAssertEqual(c.readLine(), "HTTP/1.1 100 Continue")
        XCTAssertEqual(c.readLine(), "")
        c.send("abcd")
        XCTAssertEqual(c.readResponse().status, 200)
        XCTAssertEqual(String(decoding: lastBody, as: UTF8.self), "abcd")
    }

    func testKeepAliveDrainsUnreadBody() throws {
        handlerImpl = { req in req.method == "POST" ? .text(200, "first") : .text(200, "second") }
        let c = try connect(); defer { c.close() }
        c.send("POST /x HTTP/1.1\r\nContent-Length: 10\r\n\r\n0123456789")
        XCTAssertEqual(String(decoding: c.readResponse().body, as: UTF8.self), "first")
        c.send("GET /y HTTP/1.1\r\n\r\n")
        XCTAssertEqual(String(decoding: c.readResponse().body, as: UTF8.self), "second")
    }

    func testMalformedRequestLine400() throws {
        let c = try connect(); defer { c.close() }
        c.send("garbage\r\n\r\n")
        let r = c.readResponse()
        XCTAssertEqual(r.status, 400)
        XCTAssertEqual(r.headers["connection"], "close")
        XCTAssertNil(c.readByte(), "connection should be closed after 400")
    }

    func testInvalidContentLength400() throws {
        let c = try connect(); defer { c.close() }
        c.send("POST / HTTP/1.1\r\nContent-Length: abc\r\n\r\n")
        XCTAssertEqual(c.readResponse().status, 400)
    }

    func testHeaderTooLarge431() throws {
        let c = try connect(); defer { c.close() }
        c.send("GET / HTTP/1.1\r\nX-Big: " + String(repeating: "a", count: 70 * 1024) + "\r\n\r\n")
        XCTAssertEqual(c.readResponse().status, 431)
    }

    func testHttp10ClosesByDefault() throws {
        let c = try connect(); defer { c.close() }
        c.send("GET / HTTP/1.0\r\n\r\n")
        let r = c.readResponse()
        XCTAssertEqual(r.headers["connection"], "close")
        XCTAssertNil(c.readByte())
    }

    func testDateHeaderParses() throws {
        let c = try connect(); defer { c.close() }
        c.send("GET / HTTP/1.1\r\n\r\n")
        let date = try XCTUnwrap(c.readResponse().headers["date"])
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let parsed = try XCTUnwrap(f.date(from: date), "unparseable Date: \(date)")
        XCTAssertLessThan(abs(parsed.timeIntervalSinceNow), 60)
    }

    func testStopClosesListenerAndConnections() throws {
        let idle = try connect(); defer { idle.close() }
        Thread.sleep(forTimeInterval: 0.1)
        let start = Date()
        server.stop()
        server.stop()
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0, "stop too slow")
        XCTAssertThrowsError(try RawClient(port: server.boundPort).close(), "connect should fail")
        XCTAssertNil(idle.readByte(), "idle connection should see EOF")
    }
}
