import Foundation
import os
#if canImport(Darwin)
import Darwin
#endif

/// Blocking HTTP/1.1 server on POSIX sockets, one thread per connection. FROZEN INTERFACE.
/// Supports keep-alive, Content-Length and chunked request bodies, "Expect: 100-continue"
/// (100 Continue is sent before the handler runs), always emits Content-Length + Connection.
/// Handler errors become 500. port 0 = ephemeral (see `boundPort`).
public final class HttpServer {
    private static let log = Logger(subsystem: "dev.utatane.imprima", category: "http")
    private static let idleTimeoutSeconds = 60
    private static let maxHeaderBytes = 64 * 1024

    private let port: UInt16
    private let handler: HttpHandler
    private let lock = NSLock()
    private var listenFd: Int32 = -1
    private var actualPort: UInt16 = 0
    private var started = false
    private var stopped = false
    private var connections = Set<Int32>()
    private var wakePipe: [Int32] = [-1, -1]
    private var acceptExited: DispatchSemaphore?
    private var connCounter = 0

    public init(port: UInt16, handler: @escaping HttpHandler) {
        self.port = port
        self.handler = handler
    }

    /// Actual bound port after start().
    public var boundPort: UInt16 {
        lock.lock(); defer { lock.unlock() }
        return started ? actualPort : port
    }

    /// Binds (IPv6 dual-stack or IPv4 fallback, all interfaces) and starts accepting on a background thread. Throws on bind failure.
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        precondition(!started, "already started")
        let fd = try Self.bindListener(port: port)
        var pipeFds: [Int32] = [-1, -1]
        guard pipe(&pipeFds) == 0 else {
            let msg = String(cString: strerror(errno))
            Darwin.close(fd)
            throw StreamError.io("pipe: \(msg)")
        }
        listenFd = fd
        actualPort = Self.localPort(fd)
        wakePipe = pipeFds
        stopped = false
        started = true
        let exited = DispatchSemaphore(value: 0)
        acceptExited = exited
        let t = Thread { [self] in
            acceptLoop(fd: fd, wakeFd: pipeFds[0])
            exited.signal()
        }
        t.name = "http-accept"
        t.start()
        Self.log.info("HTTP server listening on port \(self.actualPort)")
    }

    /// Closes the listener and all open connections. Idempotent.
    public func stop() {
        lock.lock()
        if !started || stopped { lock.unlock(); return }
        stopped = true
        let wakeWrite = wakePipe[1]
        let exited = acceptExited
        let snapshot = connections
        lock.unlock()

        var one: UInt8 = 1
        _ = Darwin.write(wakeWrite, &one, 1)
        // The accept thread owns (and closes) the listener; wait so the port is closed when stop() returns.
        if let exited = exited, exited.wait(timeout: .now() + 2) == .timedOut {
            Self.log.error("accept thread did not exit in time")
        }
        // Connection threads own their fds; shutdown wakes blocked recv() and they close.
        for fd in snapshot { _ = shutdown(fd, SHUT_RDWR) }
    }

    deinit { stop() }

    // MARK: - Socket setup

    private static func bindListener(port: UInt16) throws -> Int32 {
        var on: Int32 = 1
        var off: Int32 = 0
        // IPv6 dual-stack first.
        let fd6 = socket(AF_INET6, SOCK_STREAM, 0)
        if fd6 >= 0 {
            setsockopt(fd6, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd6, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            addr.sin6_addr = in6addr_any
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd6, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
            if rc == 0 && listen(fd6, 50) == 0 { return fd6 }
            log.info("IPv6 bind failed (\(String(cString: strerror(errno)))), falling back to IPv4")
            Darwin.close(fd6)
        }
        let fd4 = socket(AF_INET, SOCK_STREAM, 0)
        guard fd4 >= 0 else { throw StreamError.io("socket: \(String(cString: strerror(errno)))") }
        setsockopt(fd4, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd4, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc != 0 || listen(fd4, 50) != 0 {
            let code = errno
            let msg = String(cString: strerror(code))
            Darwin.close(fd4)
            throw StreamError.io(code == EADDRINUSE ? String(localized: "Port \(String(port)) is already in use", bundle: .module) : String(localized: "Cannot bind port \(String(port)): \(msg)", bundle: .module))
        }
        return fd4
    }

    private static func localPort(_ fd: Int32) -> UInt16 {
        var storage = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let rc = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard rc == 0 else { return 0 }
        let family = Int32(storage.ss_family)
        return withUnsafePointer(to: &storage) { p -> UInt16 in
            if family == AF_INET6 {
                return p.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
            }
            return p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
        }
    }

    // MARK: - Accept loop

    private func isStopped() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop(fd: Int32, wakeFd: Int32) {
        defer {
            Darwin.close(fd)
            lock.lock()
            let p = wakePipe
            wakePipe = [-1, -1]
            lock.unlock()
            if p[0] >= 0 { Darwin.close(p[0]) }
            if p[1] >= 0 { Darwin.close(p[1]) }
        }
        while !isStopped() {
            var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: wakeFd, events: Int16(POLLIN), revents: 0)]
            let pr = poll(&fds, 2, -1)
            if pr < 0 {
                if errno == EINTR { continue }
                Self.log.error("poll failed: \(String(cString: strerror(errno)))")
                break
            }
            if fds[1].revents != 0 || isStopped() { break }
            if fds[0].revents & Int16(POLLIN) == 0 { continue }
            let cfd = accept(fd, nil, nil)
            if cfd < 0 {
                let e = errno
                if e == EINTR || e == ECONNABORTED || e == EAGAIN { continue }
                Self.log.warning("accept failed: \(String(cString: strerror(e)))")
                continue
            }
            lock.lock()
            if stopped {
                lock.unlock()
                Darwin.close(cfd)
                break
            }
            connections.insert(cfd)
            connCounter += 1
            let n = connCounter
            lock.unlock()
            let t = Thread { [self] in serve(cfd) }
            t.name = "http-conn-\(n)"
            t.start()
        }
    }

    // MARK: - Connection

    private enum ConnError: Error {
        case badRequest(Int)
        case closed
    }

    private func serve(_ fd: Int32) {
        defer {
            lock.lock()
            connections.remove(fd)
            lock.unlock()
            Darwin.close(fd)
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Self.idleTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        // Re-check after registration: stop() may have snapshotted connections before insert.
        if isStopped() { return }
        let input = SocketInputStream(fd: fd)
        do {
            var keepAlive = true
            while keepAlive && !isStopped() {
                keepAlive = try handleOne(fd: fd, input: input)
            }
        } catch {
            Self.log.debug("connection ended: \(String(describing: error))")
        }
    }

    /// Handles one request. Returns true if the connection should stay open.
    private func handleOne(fd: Int32, input: SocketInputStream) throws -> Bool {
        var budget = Self.maxHeaderBytes
        var headers: [String: String] = [:]
        let requestLine: String
        do {
            guard var line = try readHeaderLine(input, &budget) else { return false }
            while line.isEmpty {
                guard let next = try readHeaderLine(input, &budget) else { return false }
                line = next
            }
            requestLine = line
            while true {
                guard let h = try readHeaderLine(input, &budget) else { throw StreamError.unexpectedEOF }
                if h.isEmpty { break }
                guard let idx = h.firstIndex(of: ":"), idx != h.startIndex else { throw ConnError.badRequest(400) }
                let name = h[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
                let value = h[h.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }
        } catch ConnError.badRequest(let status) {
            try writeResponse(fd, .text(status, "\(Self.reason(status))\n"), keepAlive: false)
            return false
        }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else {
            try writeResponse(fd, .text(400, "Bad Request\n"), keepAlive: false)
            return false
        }
        let method = parts[0]
        let version = parts[2]
        var path = parts[1]
        if path.hasPrefix("http://") || path.hasPrefix("https://"), let r = path.range(of: "://") {
            let rest = path[r.upperBound...]
            if let slash = rest.firstIndex(of: "/") { path = String(rest[slash...]) } else { path = "/" }
        }
        Self.log.debug("\(method, privacy: .public) \(path, privacy: .public)")

        let connHeader = headers["connection"]?.lowercased() ?? ""
        var keepAlive = version == "HTTP/1.0" ? connHeader.contains("keep-alive") : !connHeader.contains("close")

        let body: ByteInputStream
        if let te = headers["transfer-encoding"]?.lowercased(), te.contains("chunked") {
            body = ChunkedInputStream(input)
        } else if let cl = headers["content-length"] {
            guard let len = Int64(cl.trimmingCharacters(in: .whitespaces)), len >= 0 else {
                try writeResponse(fd, .text(400, "Bad Request\n"), keepAlive: false)
                return false
            }
            body = BoundedInputStream(input, limit: len)
        } else {
            body = BoundedInputStream(input, limit: 0)
        }

        if headers["expect"]?.trimmingCharacters(in: .whitespaces).lowercased() == "100-continue" {
            try sendAll(fd, Array("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }

        let response = handler(HttpRequest(method: method, path: path, headers: headers, body: body))

        // The connection may have been shut down (stop()) while the handler ran.
        if isStopped() { return false }

        if keepAlive {
            do { try drain(body) } catch { keepAlive = false }
        }
        try writeResponse(fd, response, keepAlive: keepAlive)
        return keepAlive
    }

    private func drain(_ body: ByteInputStream) throws {
        var buf = [UInt8](repeating: 0, count: 8192)
        while try buf.withUnsafeMutableBufferPointer({ try body.read(into: $0.baseAddress!, maxLength: $0.count) }) > 0 {}
    }

    /// Reads a CRLF/LF-terminated line (ISO-8859-1). nil on clean EOF before any byte.
    private func readHeaderLine(_ input: SocketInputStream, _ budget: inout Int) throws -> String? {
        var bytes: [UInt8] = []
        while true {
            guard let c = try input.nextByte() else {
                if bytes.isEmpty { return nil }
                throw StreamError.unexpectedEOF
            }
            budget -= 1
            if budget < 0 { throw ConnError.badRequest(431) }
            if c == 0x0A { break }
            if c != 0x0D { bytes.append(c) }
        }
        return String(bytes.map { Character(Unicode.Scalar($0)) })
    }

    private func writeResponse(_ fd: Int32, _ r: HttpResponse, keepAlive: Bool) throws {
        var s = "HTTP/1.1 \(r.status) \(Self.reason(r.status))\r\n"
        s += "Content-Type: \(r.contentType)\r\n"
        s += "Content-Length: \(r.body.count)\r\n"
        s += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n"
        s += "Date: \(Self.httpDate())\r\n"
        s += "Server: Imprima/0.1\r\n"
        for (k, v) in r.headers { s += "\(k): \(v)\r\n" }
        s += "\r\n"
        var out = [UInt8](s.utf8)
        out.append(contentsOf: r.body)
        try sendAll(fd, out)
    }

    private func sendAll(_ fd: Int32, _ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = send(fd, raw.baseAddress! + off, raw.count - off, 0)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw StreamError.io("write: \(String(cString: strerror(errno)))")
                }
                if n == 0 { throw StreamError.closed }
                off += n
            }
        }
    }

    private static let dateLock = NSLock()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()

    static func httpDate(_ date: Date = Date()) -> String {
        dateLock.lock(); defer { dateLock.unlock() }
        return dateFormatter.string(from: date)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 100: return "Continue"
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}
