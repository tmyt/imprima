import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Buffered blocking reader over a connected socket fd. Does not own (close) the fd.
/// `read` returns 0 on orderly peer shutdown; throws `StreamError.io` on error or receive timeout.
final class SocketInputStream: ByteInputStream {
    private let fd: Int32
    private var buffer: [UInt8]
    private var start = 0
    private var end = 0

    init(fd: Int32, bufferSize: Int = 16 * 1024) {
        self.fd = fd
        self.buffer = [UInt8](repeating: 0, count: bufferSize)
    }

    /// Refills the internal buffer. Returns false at EOF.
    private func fill() throws -> Bool {
        start = 0
        end = 0
        while true {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n > 0 { end = n; return true }
            if n == 0 { return false }
            let e = errno
            if e == EINTR { continue }
            if e == EAGAIN || e == EWOULDBLOCK { throw StreamError.io("read timeout") }
            throw StreamError.io(String(cString: strerror(e)))
        }
    }

    func read(into out: UnsafeMutablePointer<UInt8>, maxLength: Int) throws -> Int {
        if maxLength <= 0 { return 0 }
        if start == end {
            // Large reads bypass the buffer.
            if maxLength >= buffer.count {
                while true {
                    let n = recv(fd, out, maxLength, 0)
                    if n >= 0 { return n }
                    let e = errno
                    if e == EINTR { continue }
                    if e == EAGAIN || e == EWOULDBLOCK { throw StreamError.io("read timeout") }
                    throw StreamError.io(String(cString: strerror(e)))
                }
            }
            if try !fill() { return 0 }
        }
        let n = min(maxLength, end - start)
        buffer.withUnsafeBufferPointer { src in
            out.update(from: src.baseAddress! + start, count: n)
        }
        start += n
        return n
    }

    /// Buffered single-byte read; nil at EOF.
    func nextByte() throws -> UInt8? {
        if start == end {
            if try !fill() { return nil }
        }
        let b = buffer[start]
        start += 1
        return b
    }
}

/// Reads exactly `limit` bytes from `src`; never reads past the limit. EOF before the limit throws.
final class BoundedInputStream: ByteInputStream {
    private let src: ByteInputStream
    private var remaining: Int64

    init(_ src: ByteInputStream, limit: Int64) {
        self.src = src
        self.remaining = limit
    }

    func read(into buffer: UnsafeMutablePointer<UInt8>, maxLength: Int) throws -> Int {
        if maxLength <= 0 || remaining <= 0 { return 0 }
        let want = Int(min(Int64(maxLength), remaining))
        let n = try src.read(into: buffer, maxLength: want)
        if n <= 0 { throw StreamError.unexpectedEOF }
        remaining -= Int64(n)
        return n
    }
}

/// De-chunks a `Transfer-Encoding: chunked` body; ignores chunk extensions and consumes trailers.
final class ChunkedInputStream: ByteInputStream {
    private let src: ByteInputStream
    private var chunkRemaining: Int64 = 0
    private var finished = false

    init(_ src: ByteInputStream) { self.src = src }

    func read(into buffer: UnsafeMutablePointer<UInt8>, maxLength: Int) throws -> Int {
        if maxLength <= 0 || finished { return 0 }
        if chunkRemaining == 0 {
            try nextChunk()
            if finished { return 0 }
        }
        let want = Int(min(Int64(maxLength), chunkRemaining))
        let n = try src.read(into: buffer, maxLength: want)
        if n <= 0 { throw StreamError.unexpectedEOF }
        chunkRemaining -= Int64(n)
        if chunkRemaining == 0 { try readCrlf() }
        return n
    }

    private func nextChunk() throws {
        let line = try readLine()
        let sizeText = (line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !sizeText.isEmpty, let size = Int64(sizeText, radix: 16), size >= 0 else {
            throw StreamError.io("Bad chunk size: \(sizeText)")
        }
        if size == 0 {
            while try !readLine().isEmpty { /* skip trailers */ }
            finished = true
        } else {
            chunkRemaining = size
        }
    }

    private func readCrlf() throws {
        if try !readLine().isEmpty { throw StreamError.io("Missing CRLF after chunk") }
    }

    private func readLine() throws -> String {
        var bytes: [UInt8] = []
        while true {
            let c: UInt8?
            if let s = src as? SocketInputStream { c = try s.nextByte() } else { c = try src.readByte() }
            guard let b = c else { throw StreamError.unexpectedEOF }
            if b == 0x0A { break }
            if b != 0x0D { bytes.append(b) }
            if bytes.count > 8192 { throw StreamError.io("Chunk line too long") }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
