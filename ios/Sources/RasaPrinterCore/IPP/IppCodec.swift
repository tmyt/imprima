import Foundation

public struct IppDecodeError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// IPP binary encoding (RFC 8010). FROZEN INTERFACE.
/// `decode` reads header + attribute groups up to and including the end-of-attributes tag and
/// returns; document bytes after it are left unread in `input` (no read-ahead).
public enum IppCodec {
    public static func decode(_ input: ByteInputStream) throws -> IppMessage { fatalError("TODO unit swift-ipp") }
    public static func encode(_ message: IppMessage) -> Data { fatalError("TODO unit swift-ipp") }
}
