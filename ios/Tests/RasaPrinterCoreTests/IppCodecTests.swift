import XCTest
@testable import RasaPrinterCore

final class IppCodecTests: XCTestCase {
    private func col(_ members: IppAttribute...) -> IppValue { .collection(members) }

    private let dateBytes = Data((1...11).map { UInt8($0) })
    private let octets = Data([1, 2, 3, 0, 0xFF])

    private var message: IppMessage {
        IppMessage(code: 0, requestId: 42, groups: [
            IppGroup(IppTag.operationAttributes, [
                IppAttribute("attributes-charset", .charset("utf-8")),
                IppAttribute("attributes-natural-language", .naturalLanguage("en")),
                IppAttribute("printer-uri", .uri("ipp://localhost/ipp/print")),
                IppAttribute("document-format", .mimeMediaType("application/pdf")),
                IppAttribute("status-message", .text("fine あ")),
            ]),
            IppGroup(IppTag.jobAttributes, []),
            IppGroup(IppTag.printerAttributes, [
                IppAttribute("copies-default", .integer(-5)),
                IppAttribute("printer-is-accepting-jobs", .bool(true)),
                IppAttribute("printer-state", .enumValue(3)),
                IppAttribute("printer-info", .text("hello", lang: "en-us")),
                IppAttribute("printer-name", .name("Rasa")),
                IppAttribute("printer-location", .name("Desk", lang: "en")),
                IppAttribute("blob", .octetString(octets)),
                IppAttribute("printer-current-time", .dateTime(dateBytes)),
                IppAttribute("printer-resolution-default", .resolution(x: 600, y: 300, units: 3)),
                IppAttribute("copies-supported", .range(low: 1, high: 99)),
                IppAttribute("printer-uri-scheme", .uriScheme("ipp")),
                IppAttribute("media-ready", .outOfBand(IppTag.noValue)),
                IppAttribute("sides-supported", [.keyword("one-sided"), .keyword("two-sided-long-edge"), .keyword("two-sided-short-edge")]),
                IppAttribute("media-col-database", [
                    col(
                        IppAttribute("media-size", col(
                            IppAttribute("x-dimension", .integer(21000)),
                            IppAttribute("y-dimension", .integer(29700)))),
                        IppAttribute("media-type", .keyword("stationery"))),
                    col(
                        IppAttribute("media-bottom-margin", .integer(0)),
                        IppAttribute("media-source", .keyword("main"))),
                ]),
                IppAttribute("multi-member", col(
                    IppAttribute("sizes", [.integer(1), .integer(2)]),
                    IppAttribute("tail", .keyword("x")))),
                IppAttribute("odd", .unknown(tag: 0x7F, Data([9, 8]))),
            ]),
        ])
    }

    func testRoundTrip() throws {
        let msg = message
        let bytes = IppCodec.encode(msg)
        let decoded = try IppCodec.decode(DataInputStream(bytes))
        XCTAssertEqual(decoded.code, msg.code)
        XCTAssertEqual(decoded.requestId, msg.requestId)
        XCTAssertEqual(decoded.groups.map { $0.tag }, msg.groups.map { $0.tag })
        let printer = try XCTUnwrap(decoded.group(IppTag.printerAttributes))
        let orig = try XCTUnwrap(msg.group(IppTag.printerAttributes))
        for a in orig.attributes {
            XCTAssertEqual(printer[a.name], a, a.name)
        }
        XCTAssertEqual(decoded.group(IppTag.operationAttributes), msg.group(IppTag.operationAttributes))
        XCTAssertEqual(decoded.jobAttributes, IppGroup(IppTag.jobAttributes, []))
        XCTAssertEqual(printer["sides-supported"]?.values.count, 3)
        XCTAssertEqual(printer["media-col-database"]?.values.count, 2)
        XCTAssertEqual(IppCodec.encode(decoded), bytes)
    }

    private func attr(_ tag: UInt8, _ name: String, _ value: String) -> [UInt8] {
        let n = Array(name.utf8), v = Array(value.utf8)
        return [tag, UInt8(n.count >> 8), UInt8(n.count & 0xFF)] + n + [UInt8(v.count >> 8), UInt8(v.count & 0xFF)] + v
    }

    func testDecodeGetPrinterAttributesLeavesTrailingBytes() throws {
        var o: [UInt8] = [0x02, 0x00, 0x00, 0x0B, 0, 0, 0, 1, 0x01]
        o += attr(0x47, "attributes-charset", "utf-8")
        o += attr(0x48, "attributes-natural-language", "en")
        o += attr(0x45, "printer-uri", "ipp://localhost/ipp/print")
        o += attr(0x44, "requested-attributes", "all")
        o += attr(0x44, "", "media-col-database")
        o.append(0x03)
        o += Array("DOC!".utf8)
        let input = DataInputStream(Data(o))

        let m = try IppCodec.decode(input)
        XCTAssertEqual(m.versionMajor, 2)
        XCTAssertEqual(m.versionMinor, 0)
        XCTAssertEqual(m.code, IppOperation.getPrinterAttributes)
        XCTAssertEqual(m.requestId, 1)
        let g = try XCTUnwrap(m.operationAttributes)
        XCTAssertEqual(g.attributes.count, 4)
        XCTAssertEqual(g["attributes-charset"]?.stringValue, "utf-8")
        XCTAssertEqual(g["attributes-natural-language"]?.stringValue, "en")
        XCTAssertEqual(g["printer-uri"]?.stringValue, "ipp://localhost/ipp/print")
        XCTAssertEqual(g["requested-attributes"]?.stringValues, ["all", "media-col-database"])
        XCTAssertEqual(input.remaining, 4)
        XCTAssertEqual(try input.readToEnd(), Data("DOC!".utf8))
    }

    func testTruncatedInputThrows() {
        let full = IppCodec.encode(message)
        for n in [0, 3, 8, 9, 20, full.count - 1] {
            XCTAssertThrowsError(try IppCodec.decode(DataInputStream(full.prefix(n))), "length \(n)") { e in
                XCTAssertTrue(e is IppDecodeError, "length \(n): \(e)")
                XCTAssertFalse((e as? IppDecodeError)?.message.isEmpty ?? true)
            }
        }
    }

    func testResponseHeaderBytes() {
        let bytes = IppCodec.encode(IppMessage(code: IppStatus.ok, requestId: 1, groups: []))
        XCTAssertEqual([UInt8](bytes), [0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x03])
    }

    func testEndGroupIgnored() {
        let m = IppMessage(code: 0, requestId: 1, groups: [IppGroup(IppTag.endOfAttributes, [])])
        XCTAssertEqual(IppCodec.encode(m).count, 9)
    }

    func testOversizeValueTruncatedNotCrashing() throws {
        let big = IppMessage(code: 0, requestId: 1, groups: [
            IppGroup(1, [IppAttribute("a", .keyword(String(repeating: "x", count: 70000)))])])
        let decoded = try IppCodec.decode(DataInputStream(IppCodec.encode(big)))
        XCTAssertEqual(decoded.group(1)?["a"]?.stringValue?.utf8.count, 0xFFFF)
    }

    func testEmptyValuesEncodeAsNoValue() throws {
        let m = IppMessage(code: 0, requestId: 1, groups: [IppGroup(4, [IppAttribute("x", [IppValue]())])])
        let d = try IppCodec.decode(DataInputStream(IppCodec.encode(m)))
        XCTAssertEqual(d.group(4)?["x"]?.values, [.outOfBand(IppTag.noValue)])
    }

    func testBadSizesThrow() {
        let o: [UInt8] = [2, 0, 0, 0, 0, 0, 0, 1, 1] + attr(0x21, "n", "abc") + [3]
        XCTAssertThrowsError(try IppCodec.decode(DataInputStream(Data(o)))) { XCTAssertTrue($0 is IppDecodeError) }
    }
}
