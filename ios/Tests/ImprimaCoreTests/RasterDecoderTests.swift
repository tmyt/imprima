import Foundation
import XCTest
import zlib
@testable import ImprimaCore

final class RasterDecoderTests: XCTestCase {

    /// Collects every row (copied).
    private final class CollectingSink: RasterSink {
        var pages: [(info: RasterPageInfo, rows: [[UInt8]])] = []
        var open = false
        func beginPage(_ info: RasterPageInfo) {
            XCTAssertFalse(open, "beginPage while page open")
            open = true
            pages.append((info, []))
        }
        func row(_ row: UnsafeBufferPointer<UInt8>) {
            XCTAssertTrue(open)
            XCTAssertEqual(pages[pages.count - 1].info.rowBytes, row.count)
            pages[pages.count - 1].rows.append(Array(row))
        }
        func endPage() {
            XCTAssertTrue(open)
            open = false
        }
    }

    /// Statistics-only sink for big fixtures (rows kept only for the first page if asked).
    private final class StatsSink: RasterSink {
        let keepFirstPage: Bool
        var infos: [RasterPageInfo] = []
        var rowCounts: [Int] = []
        var nonWhite: [Int] = []
        var graySum: [Int] = []
        var distinctRowHashes: [Set<Int>] = []
        var firstPage: [[UInt8]]?
        init(keepFirstPage: Bool = false) { self.keepFirstPage = keepFirstPage }
        func beginPage(_ info: RasterPageInfo) {
            infos.append(info); rowCounts.append(0); nonWhite.append(0); graySum.append(0); distinctRowHashes.append([])
            if keepFirstPage && infos.count == 1 { firstPage = [] }
        }
        func row(_ row: UnsafeBufferPointer<UInt8>) {
            let i = infos.count - 1
            let info = infos[i]
            XCTAssertEqual(info.rowBytes, row.count)
            rowCounts[i] += 1
            var nw = 0, gs = 0
            switch info.pixelFormat {
            case .black1: for b in row { nw += b.nonzeroBitCount }
            case .gray8: for v in row { gs += Int(v); if v < 250 { nw += 1 } }
            case .rgb24:
                var p = 0
                while p < row.count {
                    if row[p] < 250 || row[p + 1] < 250 || row[p + 2] < 250 { nw += 1 }
                    p += 3
                }
            }
            nonWhite[i] += nw; graySum[i] += gs
            if distinctRowHashes[i].count < 10 {
                var h = Hasher(); h.combine(bytes: UnsafeRawBufferPointer(row)); distinctRowHashes[i].insert(h.finalize())
            }
            if i == 0 && firstPage != nil { firstPage!.append(Array(row)) }
        }
        func endPage() {}
        func nonWhiteFraction(_ i: Int) -> Double { Double(nonWhite[i]) / Double(infos[i].widthPx * infos[i].heightPx) }
    }

    private func fixtureStream(_ name: String) throws -> DataInputStream { DataInputStream(try RasterTestSupport.fixture(name)) }

    // MARK: hand-encoding helpers

    private struct Bytes {
        var out: [UInt8] = []
        func u8(_ v: Int...) -> Bytes { var c = self; c.out += v.map { UInt8(truncatingIfNeeded: $0) }; return c }
        func u32(_ v: Int) -> Bytes { u8(v >> 24 & 0xFF, v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF) }
        func ascii(_ s: String) -> Bytes { var c = self; c.out += Array(s.utf8); return c }
        func raw(_ b: [UInt8]) -> Bytes { var c = self; c.out += b; return c }
        var data: Data { Data(out) }
    }

    private func urfPageHeader(_ bpp: Int, _ cs: Int, _ w: Int, _ h: Int, _ dpi: Int) -> [UInt8] {
        Bytes().u8(bpp, cs, 1, 0).u32(0).u32(0).u32(w).u32(h).u32(dpi).u32(0).u32(0).out
    }

    private func pwgHeader(_ w: Int, _ h: Int, _ dpiX: Int, _ dpiY: Int, _ bpc: Int, _ bpp: Int, _ cs: Int, _ numColors: Int) -> [UInt8] {
        var hdr = [UInt8](repeating: 0, count: 1796)
        func put(_ off: Int, _ v: Int) {
            hdr[off] = UInt8(truncatingIfNeeded: v >> 24); hdr[off + 1] = UInt8(truncatingIfNeeded: v >> 16)
            hdr[off + 2] = UInt8(truncatingIfNeeded: v >> 8); hdr[off + 3] = UInt8(truncatingIfNeeded: v)
        }
        for (i, c) in "PwgRaster".utf8.enumerated() { hdr[i] = c }
        put(276, dpiX); put(280, dpiY)
        put(372, w); put(376, h)
        put(384, bpc); put(388, bpp); put(392, (w * bpp + 7) / 8)
        put(396, 0); put(400, cs); put(420, numColors)
        return hdr
    }

    private func rgb(_ px: Int...) -> [UInt8] {
        px.flatMap { [UInt8($0 >> 16 & 0xFF), UInt8($0 >> 8 & 0xFF), UInt8($0 & 0xFF)] }
    }

    private func decode(_ d: Data) throws -> CollectingSink {
        let sink = CollectingSink()
        try RasterDecoder.decode(DataInputStream(d), sink: sink)
        return sink
    }

    private func info(_ w: Int, _ h: Int, _ dx: Int, _ dy: Int, _ f: PixelFormat) -> RasterPageInfo {
        RasterPageInfo(widthPx: w, heightPx: h, dpiX: dx, dpiY: dy, pixelFormat: f)
    }

    // MARK: tests

    func testSniffDetectsMagics() {
        func s(_ str: String) -> String? { RasterDecoder.sniff(Data(str.utf8)) }
        XCTAssertEqual(s("UNIRAST\u{0}\u{0}\u{0}"), "image/urf")
        XCTAssertEqual(s("UNIRAST\u{0}"), "image/urf")
        XCTAssertEqual(s("RaS2PwgRaster"), "image/pwg-raster")
        XCTAssertEqual(s("RaS2"), "image/pwg-raster")
        XCTAssertNil(s("%PDF-1.7"))
        XCTAssertNil(s("UNIRASTX"))
        XCTAssertNil(s("UNIRAST"))
        XCTAssertNil(s("RaS"))
        XCTAssertNil(RasterDecoder.sniff(Data()))
        XCTAssertNil(s("RaS3xxxx"))
        // A Data slice with non-zero startIndex.
        let sliced = Data("xxRaS2abc".utf8).dropFirst(2)
        XCTAssertEqual(RasterDecoder.sniff(sliced), "image/pwg-raster")
    }

    func testSyntheticUrfTwoPages() throws {
        let r = 0xFF0000, g = 0x00FF00, b = 0x0000FF, w = 0xFFFFFF, k = 0x000000
        let doc = Bytes().ascii("UNIRAST").u8(0).u32(2)
            // page 1: 4x3 sRGB @300
            .raw(urfPageHeader(24, 1, 4, 3, 300))
            // line 0, repeated twice: repeat red x2, literal [green, blue]
            .u8(1).u8(1).raw(rgb(r)).u8(0xFF).raw(rgb(g, b))
            // line 2: literal [blue, black], then 0x80 fill white
            .u8(0).u8(0xFF).raw(rgb(b, k)).u8(0x80)
            // page 2: 4x3 DeviceRGB @600, one line repeated 3 times: repeat black x4
            .raw(urfPageHeader(24, 5, 4, 3, 600))
            .u8(2).u8(3).raw(rgb(k))
            .data
        let sink = try decode(doc)
        XCTAssertEqual(sink.pages.count, 2)
        XCTAssertEqual(sink.pages[0].info, info(4, 3, 300, 300, .rgb24))
        XCTAssertEqual(sink.pages[1].info, info(4, 3, 600, 600, .rgb24))
        let p1 = sink.pages[0].rows
        XCTAssertEqual(p1.count, 3)
        XCTAssertEqual(p1[0], rgb(r, r, g, b))
        XCTAssertEqual(p1[1], rgb(r, r, g, b))
        XCTAssertEqual(p1[2], rgb(b, k, w, w))
        let p2 = sink.pages[1].rows
        XCTAssertEqual(p2.count, 3)
        for row in p2 { XCTAssertEqual(row, rgb(k, k, k, k)) }
        XCTAssertFalse(sink.open)
    }

    func testSyntheticUrfUnknownPageCountDecodesUntilEof() throws {
        let page = Bytes().raw(urfPageHeader(8, 4, 3, 1, 300)).u8(0).u8(0xFE).u8(0x00, 0x80, 0xFF).out
        let doc = Bytes().ascii("UNIRAST").u8(0).u32(0).raw(page).raw(page).data
        let sink = try decode(doc)
        XCTAssertEqual(sink.pages.count, 2)
        XCTAssertEqual(sink.pages[0].info.pixelFormat, .gray8)
        XCTAssertEqual(sink.pages[1].rows[0], [0x00, 0x80, 0xFF])
    }

    func testSyntheticPwgBlackAndWhiteAndGray() throws {
        let doc = Bytes().ascii("RaS2")
            // page 1: 10x2 W 1-bit (1 = white). bytesPerLine 2.
            .raw(pwgHeader(10, 2, 300, 300, 1, 1, 0, 1))
            .u8(0).u8(0xFF).u8(0xB0, 0xC0)
            .u8(0).u8(0x80)
            // page 2: 10x1 K 1-bit (1 = black), repeat 0xA5 x2
            .raw(pwgHeader(10, 1, 600, 300, 1, 1, 3, 1))
            .u8(0).u8(1).u8(0xA5)
            // page 3: 3x2 K 8-bit (255 = black): literal [0, 128, 255], line repeated
            .raw(pwgHeader(3, 2, 300, 300, 8, 8, 3, 1))
            .u8(1).u8(0xFE).u8(0x00, 0x80, 0xFF)
            .data
        let sink = try decode(doc)
        XCTAssertEqual(sink.pages.count, 3)

        XCTAssertEqual(sink.pages[0].info, info(10, 2, 300, 300, .black1))
        // inverted 0xB0 -> 0x4F, 0xC0 -> 0x3F, then padding (6 bits) masked to 0 -> 0x00
        XCTAssertEqual(sink.pages[0].rows[0], [0x4F, 0x00])
        XCTAssertEqual(sink.pages[0].rows[1], [0x00, 0x00])

        XCTAssertEqual(sink.pages[1].info, info(10, 1, 600, 300, .black1))
        XCTAssertEqual(sink.pages[1].rows[0], [0xA5, 0x80])

        XCTAssertEqual(sink.pages[2].info, info(3, 2, 300, 300, .gray8))
        XCTAssertEqual(sink.pages[2].rows.count, 2)
        for row in sink.pages[2].rows { XCTAssertEqual(row, [0xFF, 0x7F, 0x00]) }
    }

    func testSyntheticPwgCmykAnd16Bit() throws {
        let doc = Bytes().ascii("RaS2")
            // 2x1 CMYK 8-bit: literal [c=255 m0 y0 k0], [0 0 0 k=255]
            .raw(pwgHeader(2, 1, 300, 300, 8, 32, 6, 4))
            .u8(0).u8(0xFF).u8(255, 0, 0, 0, 0, 0, 0, 255)
            // 2x1 sRGB 16-bit: repeat pixel (0x1234, 0x5678, 0x9ABC) x2
            .raw(pwgHeader(2, 1, 300, 300, 16, 48, 19, 3))
            .u8(0).u8(1).u8(0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC)
            .data
        let sink = try decode(doc)
        XCTAssertEqual(sink.pages[0].info.pixelFormat, .rgb24)
        XCTAssertEqual(sink.pages[0].rows[0], rgb(0x00FFFF, 0x000000))
        XCTAssertEqual(sink.pages[1].rows[0], rgb(0x12569A, 0x12569A))
    }

    func testMalformedInputsThrow() {
        func assertThrows(_ doc: Data, line: UInt = #line) {
            XCTAssertThrowsError(try decode(doc), line: line) { e in
                XCTAssertTrue(e is RasterFormatError, "got \(e)", line: line)
            }
        }
        assertThrows(Data("garbage!".utf8))
        assertThrows(Data("RaS".utf8))
        // unsupported URF bpp
        assertThrows(Bytes().ascii("UNIRAST").u8(0).u32(1).raw(urfPageHeader(16, 1, 2, 1, 300)).u8(0, 0x80).data)
        // unsupported PWG color space (2 = RGBA)
        assertThrows(Bytes().ascii("RaS2").raw(pwgHeader(2, 1, 300, 300, 8, 32, 2, 4)).u8(0, 0x80).data)
        // run overflow: repeat 3 pixels into a 2px line
        assertThrows(Bytes().ascii("RaS2").raw(pwgHeader(2, 1, 300, 300, 8, 8, 18, 1)).u8(0, 2, 0).data)
        // page count says 2 but only 1 present
        assertThrows(Bytes().ascii("UNIRAST").u8(0).u32(2).raw(urfPageHeader(8, 0, 1, 1, 300)).u8(0, 0, 7).data)
        // truncated PWG header
        assertThrows(Bytes().ascii("RaS2").raw([UInt8](repeating: 0, count: 100)).data)
    }

    func testFixtureRgbUrf() throws {
        let sink = StatsSink()
        try RasterDecoder.decode(fixtureStream("a4-rgb-1page.urf.gz"), sink: sink)
        XCTAssertEqual(sink.infos, [info(2479, 3508, 300, 300, .rgb24)])
        XCTAssertEqual(sink.rowCounts, [3508])
        assertTextPage(sink.nonWhiteFraction(0))
    }

    func testFixtureRgbPwg() throws {
        let sink = StatsSink()
        try RasterDecoder.decode(fixtureStream("a4-rgb-1page.pwg.gz"), sink: sink)
        XCTAssertEqual(sink.infos, [info(2479, 3508, 300, 300, .rgb24)])
        XCTAssertEqual(sink.rowCounts, [3508])
        assertTextPage(sink.nonWhiteFraction(0))
    }

    func testFixtureMonoPwgTwoPages() throws {
        let sink = StatsSink()
        try RasterDecoder.decode(fixtureStream("a4-mono-2pages.pwg.gz"), sink: sink)
        XCTAssertEqual(sink.infos.count, 2)
        for i in 0..<2 {
            XCTAssertEqual(sink.infos[i], info(2479, 3508, 300, 300, .black1))
            XCTAssertEqual(sink.rowCounts[i], 3508)
            assertTextPage(sink.nonWhiteFraction(i))
        }
    }

    func testFixtureGrayPhotoUrf() throws {
        let sink = StatsSink(keepFirstPage: true)
        try RasterDecoder.decode(fixtureStream("photo-gray.urf.gz"), sink: sink)
        XCTAssertEqual(sink.infos.count, 1)
        let i0 = sink.infos[0]
        XCTAssertEqual(i0.pixelFormat, .gray8)
        XCTAssertEqual(i0, info(2479, 3508, 300, 300, .gray8))
        XCTAssertEqual(sink.rowCounts[0], i0.heightPx)
        // The photo is centered on an otherwise white A4 page, so the mean-gray check uses the
        // central 20% x 20% region, which lies entirely inside the photo.
        let rows = sink.firstPage!
        let x0 = i0.widthPx * 2 / 5, x1 = i0.widthPx * 3 / 5
        let y0 = i0.heightPx * 2 / 5, y1 = i0.heightPx * 3 / 5
        var sum = 0
        for y in y0..<y1 { for x in x0..<x1 { sum += Int(rows[y][x]) } }
        let mean = Double(sum) / Double((x1 - x0) * (y1 - y0))
        XCTAssertTrue((40.0...215.0).contains(mean), "central mean gray \(mean)")
        let pageMean = Double(sink.graySum[0]) / Double(i0.widthPx * i0.heightPx)
        XCTAssertLessThan(pageMean, 250.0, "page mean gray")
        XCTAssertGreaterThan(sink.distinctRowHashes[0].count, 1, "rows all identical")
    }

    func testTruncatedFixtureThrows() throws {
        let head = try RasterTestSupport.fixture("a4-rgb-1page.urf.gz").prefix(100 * 1024)
        let sink = StatsSink()
        XCTAssertThrowsError(try RasterDecoder.decode(DataInputStream(Data(head)), sink: sink)) { e in
            XCTAssertTrue(e is RasterFormatError)
        }
        XCTAssertEqual(sink.infos.count, 1)
        XCTAssertLessThan(sink.rowCounts[0], 3508)
    }

    func testRowBufferIsReused() throws {
        // Two different lines on one page: the sink must see the same buffer address each time.
        let doc = Bytes().ascii("RaS2").raw(pwgHeader(2, 2, 300, 300, 8, 8, 18, 1))
            .u8(0).u8(0xFF).u8(1, 2).u8(0).u8(0xFF).u8(3, 4).data
        final class AddrSink: RasterSink {
            var addrs: [UnsafePointer<UInt8>?] = []
            var rows: [[UInt8]] = []
            func beginPage(_ info: RasterPageInfo) {}
            func row(_ row: UnsafeBufferPointer<UInt8>) { addrs.append(row.baseAddress); rows.append(Array(row)) }
            func endPage() {}
        }
        let sink = AddrSink()
        try RasterDecoder.decode(DataInputStream(doc), sink: sink)
        XCTAssertEqual(sink.rows, [[1, 2], [3, 4]])
        XCTAssertEqual(sink.addrs[0], sink.addrs[1])
    }

    private func assertTextPage(_ fraction: Double, line: UInt = #line) {
        XCTAssertTrue((0.005...0.25).contains(fraction), "non-white fraction \(fraction)", line: line)
    }
}

/// Shared helpers for the raster / PDF tests (gzip fixtures, zlib inflate, sips).

enum RasterTestSupport {
    static let scratch = URL(fileURLWithPath: "/private/tmp/claude-502/-Users-tsumori-labo-imprima/6981ed8a-48ee-456d-b11a-413bc8ce5277/scratchpad")

    static func fixtureURL(_ name: String) -> URL {
        if let u = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") { return u }
        return Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(name)
    }

    /// Gunzipped fixture bytes.
    static func fixture(_ name: String) throws -> Data {
        try gunzip(Data(contentsOf: fixtureURL(name)))
    }

    /// zlib inflate with gzip wrapper (windowBits 16 + MAX_WBITS).
    static func gunzip(_ data: Data) throws -> Data { try inflate(data, windowBits: 16 + MAX_WBITS) }

    /// zlib inflate (RFC 1950 wrapper by default).
    static func inflate(_ data: Data, windowBits: Int32 = MAX_WBITS) throws -> Data {
        var strm = z_stream()
        var rc = inflateInit2_(&strm, windowBits, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard rc == Z_OK else { throw RasterFormatError("inflateInit2 \(rc)") }
        defer { inflateEnd(&strm) }
        var out = Data()
        let chunk = 1 << 20
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buf.deallocate() }
        var input = [UInt8](data)
        try input.withUnsafeMutableBufferPointer { src in
            strm.next_in = src.baseAddress
            strm.avail_in = uInt(src.count)
            repeat {
                strm.next_out = buf
                strm.avail_out = uInt(chunk)
                rc = zlib.inflate(&strm, Z_NO_FLUSH)
                if rc != Z_OK && rc != Z_STREAM_END { throw RasterFormatError("inflate \(rc)") }
                out.append(buf, count: chunk - Int(strm.avail_out))
                if rc == Z_OK && strm.avail_in == 0 && strm.avail_out != 0 { break } // input exhausted
            } while rc != Z_STREAM_END
        }
        return out
    }

    static func sips(pdf: URL, png: URL) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        p.arguments = ["-s", "format", "png", pdf.path, "--out", png.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("imprima-\(UUID().uuidString).\(ext)")
    }
}
