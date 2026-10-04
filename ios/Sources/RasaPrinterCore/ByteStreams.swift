import Foundation

/// Blocking byte source. FROZEN INTERFACE. `read` returns 0 only at end of stream.
public protocol ByteInputStream: AnyObject {
    /// Reads up to `maxLength` bytes into `buffer`; returns the number read (0 = EOF). Blocks until at least one byte is available.
    func read(into buffer: UnsafeMutablePointer<UInt8>, maxLength: Int) throws -> Int
}

public enum StreamError: Error, Equatable, LocalizedError {
    case unexpectedEOF
    case closed
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .unexpectedEOF: return String(localized: "Unexpected end of data", bundle: .module)
        case .closed: return String(localized: "Connection closed", bundle: .module)
        case .io(let m): return m
        }
    }
}

public extension ByteInputStream {
    /// Reads exactly `count` bytes or throws `StreamError.unexpectedEOF`.
    func readExactly(_ count: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        var filled = 0
        try out.withUnsafeMutableBufferPointer { buf in
            while filled < count {
                let n = try read(into: buf.baseAddress! + filled, maxLength: count - filled)
                if n <= 0 { throw StreamError.unexpectedEOF }
                filled += n
            }
        }
        return out
    }

    /// Reads a single byte, or nil at EOF.
    func readByte() throws -> UInt8? {
        var b: UInt8 = 0
        let n = try read(into: &b, maxLength: 1)
        return n == 1 ? b : nil
    }

    /// Reads everything until EOF.
    func readToEnd() throws -> Data {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = try chunk.withUnsafeMutableBufferPointer { try read(into: $0.baseAddress!, maxLength: $0.count) }
            if n <= 0 { break }
            data.append(contentsOf: chunk[0..<n])
        }
        return data
    }
}

/// In-memory ByteInputStream. FROZEN INTERFACE.
public final class DataInputStream: ByteInputStream {
    private let data: Data
    private var position = 0
    public init(_ data: Data) { self.data = data }
    public var remaining: Int { data.count - position }
    public func read(into buffer: UnsafeMutablePointer<UInt8>, maxLength: Int) throws -> Int {
        let n = min(maxLength, data.count - position)
        if n <= 0 { return 0 }
        data.copyBytes(to: buffer, from: position..<(position + n))
        position += n
        return n
    }
}

/// ByteInputStream over an open FileHandle (reads sequentially). FROZEN INTERFACE.
public final class FileInputStream: ByteInputStream {
    private let handle: FileHandle
    public init(url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
    deinit { try? handle.close() }
    public func read(into buffer: UnsafeMutablePointer<UInt8>, maxLength: Int) throws -> Int {
        let d = handle.readData(ofLength: maxLength)
        if d.isEmpty { return 0 }
        d.copyBytes(to: buffer, count: d.count)
        return d.count
    }
}
