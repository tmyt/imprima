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
    public static func decode(_ input: ByteInputStream) throws -> IppMessage {
        do {
            return try Decoder(input).decodeMessage()
        } catch let e as IppDecodeError {
            throw e
        } catch StreamError.unexpectedEOF {
            throw IppDecodeError("Truncated IPP message")
        } catch {
            throw IppDecodeError("I/O error while decoding IPP message: \(error)")
        }
    }

    /// Values longer than 0xFFFF bytes (names, values) are silently truncated to fit the wire format.
    /// Groups whose tag is not a delimiter (0x00-0x0F) are skipped.
    public static func encode(_ message: IppMessage) -> Data {
        var out = Data()
        out.append(message.versionMajor)
        out.append(message.versionMinor)
        appendU16(&out, Int(message.code))
        appendI32(&out, message.requestId)
        for group in message.groups {
            if group.tag == IppTag.endOfAttributes || group.tag > 0x0F { continue }
            out.append(group.tag)
            for attr in group.attributes { writeAttribute(&out, attr.name, attr.values) }
        }
        out.append(IppTag.endOfAttributes)
        return out
    }

    // MARK: encoding

    private static func appendU16(_ d: inout Data, _ v: Int) {
        d.append(UInt8((v >> 8) & 0xFF)); d.append(UInt8(v & 0xFF))
    }

    private static func appendI32(_ d: inout Data, _ v: Int32) {
        let u = UInt32(bitPattern: v)
        d.append(UInt8((u >> 24) & 0xFF)); d.append(UInt8((u >> 16) & 0xFF))
        d.append(UInt8((u >> 8) & 0xFF)); d.append(UInt8(u & 0xFF))
    }

    private static func clamp(_ d: Data) -> Data { d.count > 0xFFFF ? d.prefix(0xFFFF) : d }

    private static func writeAttribute(_ d: inout Data, _ name: String, _ values: [IppValue]) {
        if values.isEmpty {
            writeValue(&d, name, .outOfBand(IppTag.noValue))
            return
        }
        for (i, v) in values.enumerated() { writeValue(&d, i == 0 ? name : "", v) }
    }

    private static func writeHeader(_ d: inout Data, tag: UInt8, name: Data, value: Data) {
        let n = clamp(name), v = clamp(value)
        d.append(tag)
        appendU16(&d, n.count); d.append(n)
        appendU16(&d, v.count); d.append(v)
    }

    private static func writeValue(_ d: inout Data, _ name: String, _ value: IppValue) {
        let nameBytes = Data(name.utf8)
        if case .collection(let members) = value {
            writeHeader(&d, tag: IppTag.begCollection, name: nameBytes, value: Data())
            for m in members {
                writeHeader(&d, tag: IppTag.memberAttrName, name: Data(), value: Data(m.name.utf8))
                for mv in m.values { writeValue(&d, "", mv) }
            }
            writeHeader(&d, tag: IppTag.endCollection, name: Data(), value: Data())
            return
        }
        writeHeader(&d, tag: value.tag, name: nameBytes, value: valueBytes(value))
    }

    private static func valueBytes(_ value: IppValue) -> Data {
        var d = Data()
        switch value {
        case .integer(let v), .enumValue(let v): appendI32(&d, v)
        case .bool(let b): d.append(b ? 1 : 0)
        case .octetString(let b), .dateTime(let b): d.append(b)
        case .resolution(let x, let y, let units):
            appendI32(&d, x); appendI32(&d, y); d.append(units)
        case .range(let lo, let hi): appendI32(&d, lo); appendI32(&d, hi)
        case .text(let s, let lang), .name(let s, let lang): writeMaybeLang(&d, s, lang)
        case .keyword(let s), .uri(let s), .uriScheme(let s), .charset(let s),
             .naturalLanguage(let s), .mimeMediaType(let s):
            d.append(contentsOf: Array(s.utf8))
        case .outOfBand: break
        case .unknown(_, let b): d.append(b)
        case .collection: break // written by writeValue
        }
        return d
    }

    private static func writeMaybeLang(_ d: inout Data, _ text: String, _ lang: String?) {
        let t = Data(text.utf8)
        guard let lang = lang else { d.append(t); return }
        // Keep the combined value within 0xFFFF bytes so the layout stays parseable.
        let l = Data(lang.utf8).prefix(0xFFFF - 4)
        let tt = t.prefix(0xFFFF - 4 - l.count)
        appendU16(&d, l.count); d.append(l)
        appendU16(&d, tt.count); d.append(tt)
    }

    // MARK: decoding

    private final class Decoder {
        let input: ByteInputStream
        init(_ input: ByteInputStream) { self.input = input }

        func byte() throws -> UInt8 {
            guard let b = try input.readByte() else { throw IppDecodeError("Truncated IPP message") }
            return b
        }
        func u16() throws -> Int { let a = Int(try byte()); return (a << 8) | Int(try byte()) }
        func i32() throws -> Int32 {
            var u: UInt32 = 0
            for _ in 0..<4 { u = (u << 8) | UInt32(try byte()) }
            return Int32(bitPattern: u)
        }
        func bytes(_ n: Int) throws -> Data {
            if n == 0 { return Data() }
            return Data(try input.readExactly(n))
        }

        func decodeMessage() throws -> IppMessage {
            let major = try byte()
            let minor = try byte()
            let code = try u16()
            let requestId = try i32()

            var groups: [IppGroup] = []
            var groupTag: UInt8? = nil
            var attrs: [(String, [IppValue])] = []

            func flush() {
                if let t = groupTag { groups.append(IppGroup(t, attrs.map { IppAttribute($0.0, $0.1) })) }
                attrs = []
            }

            while true {
                let tag = try byte()
                if tag == IppTag.endOfAttributes { flush(); break }
                if tag <= 0x0F { flush(); groupTag = tag; continue }
                if groupTag == nil { throw IppDecodeError("Attribute before any group delimiter") }
                let name = String(decoding: try bytes(try u16()), as: UTF8.self)
                let value = try readValue(tag)
                if name.isEmpty {
                    if attrs.isEmpty { throw IppDecodeError("Additional value without a preceding attribute") }
                    attrs[attrs.count - 1].1.append(value)
                } else {
                    attrs.append((name, [value]))
                }
            }
            return IppMessage(code: UInt16(code), requestId: requestId, groups: groups,
                              versionMajor: major, versionMinor: minor)
        }

        func readValue(_ tag: UInt8) throws -> IppValue {
            let len = try u16()
            if tag == IppTag.begCollection {
                _ = try bytes(len)
                return .collection(try readCollectionMembers())
            }
            return try parseValue(tag, try bytes(len))
        }

        func readCollectionMembers() throws -> [IppAttribute] {
            var members: [IppAttribute] = []
            var memberName: String? = nil
            var memberValues: [IppValue] = []

            func flush() {
                if let n = memberName { members.append(IppAttribute(n, memberValues)) }
                memberName = nil
                memberValues = []
            }

            while true {
                let tag = try byte()
                let nameLen = try u16()
                if nameLen != 0 { _ = try bytes(nameLen) }
                switch tag {
                case IppTag.endCollection:
                    _ = try bytes(try u16())
                    flush()
                    return members
                case IppTag.memberAttrName:
                    let nb = try bytes(try u16())
                    flush()
                    memberName = String(decoding: nb, as: UTF8.self)
                default:
                    if tag <= 0x0F {
                        throw IppDecodeError("Unexpected delimiter 0x\(String(tag, radix: 16)) inside collection")
                    }
                    if memberName == nil { throw IppDecodeError("Collection value without memberAttrName") }
                    memberValues.append(try readValue(tag))
                }
            }
        }

        func parseValue(_ tag: UInt8, _ data: Data) throws -> IppValue {
            let b = [UInt8](data)
            func need(_ n: Int) throws {
                if b.count != n {
                    throw IppDecodeError("Tag 0x\(String(tag, radix: 16)) expects \(n) bytes, got \(b.count)")
                }
            }
            func int(_ o: Int) -> Int32 {
                Int32(bitPattern: (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3]))
            }
            func str() -> String { String(decoding: b, as: UTF8.self) }

            switch tag {
            case IppTag.integer: try need(4); return .integer(int(0))
            case IppTag.enumValue: try need(4); return .enumValue(int(0))
            case IppTag.boolean: try need(1); return .bool(b[0] != 0)
            case IppTag.octetString: return .octetString(data)
            case IppTag.dateTime: try need(11); return .dateTime(data)
            case IppTag.resolution: try need(9); return .resolution(x: int(0), y: int(4), units: b[8])
            case IppTag.rangeOfInteger: try need(8); return .range(low: int(0), high: int(4))
            case IppTag.textWithoutLanguage: return .text(str(), lang: nil)
            case IppTag.nameWithoutLanguage: return .name(str(), lang: nil)
            case IppTag.textWithLanguage:
                let (l, t) = try parseWithLanguage(b); return .text(t, lang: l)
            case IppTag.nameWithLanguage:
                let (l, t) = try parseWithLanguage(b); return .name(t, lang: l)
            case IppTag.keyword: return .keyword(str())
            case IppTag.uri: return .uri(str())
            case IppTag.uriScheme: return .uriScheme(str())
            case IppTag.charset: return .charset(str())
            case IppTag.naturalLanguage: return .naturalLanguage(str())
            case IppTag.mimeMediaType: return .mimeMediaType(str())
            case 0x10...0x1F: return .outOfBand(tag)
            default: return .unknown(tag: tag, data)
            }
        }

        func parseWithLanguage(_ b: [UInt8]) throws -> (String, String) {
            func u16(_ o: Int) -> Int { (Int(b[o]) << 8) | Int(b[o + 1]) }
            if b.count < 4 { throw IppDecodeError("Truncated text/name with language") }
            let langLen = u16(0)
            if 2 + langLen + 2 > b.count { throw IppDecodeError("Bad language length") }
            let lang = String(decoding: b[2..<(2 + langLen)], as: UTF8.self)
            let textLen = u16(2 + langLen)
            if 4 + langLen + textLen > b.count { throw IppDecodeError("Bad text length") }
            return (lang, String(decoding: b[(4 + langLen)..<(4 + langLen + textLen)], as: UTF8.self))
        }
    }
}
