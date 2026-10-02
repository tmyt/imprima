import Foundation

/// Blocking HTTP/1.1 server on POSIX sockets, one thread per connection. FROZEN INTERFACE.
/// Supports keep-alive, Content-Length and chunked request bodies, "Expect: 100-continue"
/// (100 Continue is sent before the handler runs), always emits Content-Length + Connection.
/// Handler errors become 500. port 0 = ephemeral (see `boundPort`).
public final class HttpServer {
    public init(port: UInt16, handler: @escaping HttpHandler) { fatalError("TODO unit swift-http") }
    /// Actual bound port after start().
    public var boundPort: UInt16 { fatalError("TODO unit swift-http") }
    /// Binds (IPv6 dual-stack or IPv4 fallback, all interfaces) and starts accepting on a background thread. Throws on bind failure.
    public func start() throws { fatalError("TODO unit swift-http") }
    /// Closes the listener and all open connections. Idempotent.
    public func stop() { fatalError("TODO unit swift-http") }
}
