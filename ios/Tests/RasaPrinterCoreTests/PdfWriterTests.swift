import Foundation
import XCTest
@testable import RasaPrinterCore

final class PdfWriterTests: XCTestCase {
    private let rgbInfo = RasterPageInfo(widthPx: 8, heightPx: 4, dpiX: 72, dpiY: 72, pixelFormat: .rgb24)
    private let rgbPixels = Data((0..<(8 * 3 * 4)).map { UInt8(truncatingIfNeeded: $0 * 7) })
    private let monoInfo = RasterPageInfo(widthPx: 16, heightPx: 2, dpiX: 144, dpiY: 144, pixelFormat: .black1)
    private let monoPixels = Data([0xF0, 0x0F, 0xAA, 0x55])
    private var temps: [URL] = []

    override func tearDown() {
        for u in temps { try? FileManager.default.removeItem(at: u) }
        temps = []
        super.tearDown()
    }

    private func temp(_ ext: String) -> URL {
        let u = RasterTestSupport.tempURL(ext)
        temps.append(u)
        return u
    }

    /// Closure-backed JpegEncoder (Kotlin fun interface equivalent).
    private struct FnJpeg: JpegEncoder {
        let fn: (Int, Int, PixelFormat, Data, Int) -> Data?
        func encode(width: Int, height: Int, format: PixelFormat, pixels: Data, quality: Int) -> Data? {
            fn(width, height, format, pixels, quality)
        }
    }

    private func write(_ jpeg: JpegEncoder? = nil, _ pages: [(RasterPageInfo, Data)]) throws -> Data {
        let url = temp("pdf")
        let w = try PdfWriter(url: url, jpegEncoder: jpeg)
        for (i, p) in pages { try w.addPage(i, pixels: p) }
        try w.close()
        try w.close() // idempotent
        return try Data(contentsOf: url)
    }

    private func build(_ jpeg: JpegEncoder? = nil) throws -> Data {
        try write(jpeg, [(rgbInfo, rgbPixels), (monoInfo, monoPixels)])
    }


    private func latin1(_ d: Data) -> String { String(d.map { Character(Unicode.Scalar($0)) }) }
    private func count(_ s: String, _ sub: String) -> Int { s.components(separatedBy: sub).count - 1 }

    /// Bytes of the stream whose dictionary follows `marker`.
    private func streamAfter(_ pdf: Data, _ marker: String) throws -> Data {
        let b = [UInt8](pdf)
        let m = try XCTUnwrap(find(b, Array(marker.utf8), from: 0), "marker \(marker)")
        let lenKey = try XCTUnwrap(find(b, Array("/Length ".utf8), from: m))
        var p = lenKey + 8
        var len = 0
        while b[p] >= 0x30 && b[p] <= 0x39 { len = len * 10 + Int(b[p] - 0x30); p += 1 }
        let start = try XCTUnwrap(find(b, Array("stream\n".utf8), from: m)) + 7
        return Data(b[start..<(start + len)])
    }

    private func find(_ hay: [UInt8], _ needle: [UInt8], from: Int) -> Int? {
        guard needle.count <= hay.count else { return nil }
        var i = from
        while i + needle.count <= hay.count {
            if hay[i] == needle[0] && Array(hay[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }

    // MARK: tests

    func testStructureAndXref() throws {
        let pdf = try build()
        let s = latin1(pdf)
        XCTAssertTrue(s.hasPrefix("%PDF-1.4"))
        XCTAssertTrue(s.hasSuffix("%%EOF\n"))
        XCTAssertTrue(s.contains("/Count 2"))
        XCTAssertEqual(count(s, "/Type /Page "), 2)
        XCTAssertTrue(s.contains("/FlateDecode"))
        XCTAssertTrue(s.contains("/Decode [1 0]"))
        XCTAssertTrue(s.contains("/MediaBox [0 0 8 4]"))
        XCTAssertTrue(s.contains("/MediaBox [0 0 8 1]"))
        XCTAssertTrue(s.contains("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>"))
        XCTAssertTrue(s.contains("3 0 obj\n<< /Producer (Rasa Printer) >>"))
        let sxRange = try XCTUnwrap(s.range(of: "startxref\n"))
        let sxLine = s[sxRange.upperBound...].prefix { $0 != "\n" }
        let sx = try XCTUnwrap(Int(sxLine))
        let bytes = [UInt8](pdf)
        XCTAssertEqual(latin1(Data(bytes[sx..<(sx + 4)])), "xref")
        let lines = latin1(Data(bytes[sx...])).components(separatedBy: "\n")
        let n = try XCTUnwrap(Int(lines[1].split(separator: " ")[1]))
        XCTAssertEqual(n, 10) // 3 fixed objects + 2 pages x 3, plus the free entry
        XCTAssertEqual(lines[2], "0000000000 65535 f ")
        for i in 1..<n {
            let e = lines[2 + i]
            XCTAssertEqual(e.count, 19)
            XCTAssertTrue(e.hasSuffix(" 00000 n "))
            let off = try XCTUnwrap(Int(e.prefix(10)))
            let expect = Array("\(i) 0 obj\n".utf8)
            XCTAssertEqual(Array(bytes[off..<(off + expect.count)]), expect, "obj \(i)")
        }
        XCTAssertTrue(s.contains("trailer\n<< /Size \(n) /Root 1 0 R /Info 3 0 R >>"))
    }

    func testStreamsInflateToInput() throws {
        let pdf = try build()
        XCTAssertEqual(try RasterTestSupport.inflate(streamAfter(pdf, "/Width 8 /Height 4")), rgbPixels)
        XCTAssertEqual(try RasterTestSupport.inflate(streamAfter(pdf, "/Width 16 /Height 2")), monoPixels)
        // Content stream draws the image over the full page.
        XCTAssertEqual(latin1(try streamAfter(pdf, "5 0 obj")), "q 8 0 0 4 0 0 cm /Im0 Do Q")
    }

    func testJpegUsedAndFallback() throws {
        let jpg = fakeJpeg(8, 4, 3)
        var args: (Int, Int, PixelFormat, Int)?
        var calls = 0
        let pdf = try build(FnJpeg { w, h, f, _, q in args = (w, h, f, q); calls += 1; return jpg })
        let s = latin1(pdf)
        XCTAssertTrue(s.contains("/DCTDecode"))
        XCTAssertEqual(try streamAfter(pdf, "/DCTDecode"), jpg)
        XCTAssertEqual(calls, 1) // never called for black1
        XCTAssertEqual(args?.0, 8); XCTAssertEqual(args?.1, 4); XCTAssertEqual(args?.2, .rgb24); XCTAssertEqual(args?.3, 85)
        let pdf2 = latin1(try build(FnJpeg { _, _, _, _, _ in nil }))
        XCTAssertFalse(pdf2.contains("/DCTDecode"))
        XCTAssertTrue(pdf2.contains("/FlateDecode"))
    }

    private func fakeJpeg(_ w: Int, _ h: Int, _ comps: Int) -> Data {
        var sof: [UInt8] = [0xFF, 0xC0, 0, UInt8(8 + 3 * comps), 8,
                            UInt8(h >> 8 & 0xFF), UInt8(h & 0xFF), UInt8(w >> 8 & 0xFF), UInt8(w & 0xFF), UInt8(comps)]
        sof += [UInt8](repeating: 1, count: 3 * comps)
        // SOI, an APP0 segment, SOF0, then arbitrary tail
        return Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 4, 0, 0] + sof + [0x11, 0x22, 0x33])
    }

    private func grayPdf(_ jpg: Data) throws -> String {
        latin1(try write(FnJpeg { _, _, _, _, _ in jpg },
                         [(RasterPageInfo(widthPx: 4, heightPx: 2, dpiX: 72, dpiY: 72, pixelFormat: .gray8), Data(count: 8))]))
    }

    func testJpegColorSpaceFollowsComponents() throws {
        let three = try grayPdf(fakeJpeg(4, 2, 3))
        XCTAssertTrue(three.contains("/DeviceRGB") && three.contains("/DCTDecode") && !three.contains("/DeviceGray"))
        let one = try grayPdf(fakeJpeg(4, 2, 1))
        XCTAssertTrue(one.contains("/DeviceGray") && one.contains("/DCTDecode"))
        let four = try grayPdf(fakeJpeg(4, 2, 4))
        XCTAssertTrue(four.contains("/DeviceCMYK") && four.contains("/Decode [1 0 1 0 1 0 1 0]") && four.contains("/DCTDecode"))
    }

    func testBadJpegFallsBackToFlate() throws {
        for bad in [Data([1, 2, 3, 4, 5]), fakeJpeg(5, 2, 3), fakeJpeg(4, 2, 2), Data()] {
            let s = try grayPdf(bad)
            XCTAssertFalse(s.contains("/DCTDecode"))
            XCTAssertTrue(s.contains("/FlateDecode") && s.contains("/DeviceGray"))
        }
    }

    func testGrayPage() throws {
        let s = latin1(try write(nil, [(RasterPageInfo(widthPx: 4, heightPx: 2, dpiX: 72, dpiY: 72, pixelFormat: .gray8), Data(count: 8))]))
        XCTAssertTrue(s.contains("/DeviceGray"))
        XCTAssertTrue(s.contains("/BitsPerComponent 8"))
    }

    func testInvalidPagesThrow() throws {
        let url = temp("pdf")
        let w = try PdfWriter(url: url)
        XCTAssertThrowsError(try w.addPage(rgbInfo, pixels: Data(count: 3)))
        XCTAssertThrowsError(try w.addPage(RasterPageInfo(widthPx: 0, heightPx: 1, dpiX: 72, dpiY: 72, pixelFormat: .gray8), pixels: Data(count: 8)))
        try w.close()
        XCTAssertThrowsError(try w.addPage(rgbInfo, pixels: rgbPixels))
        XCTAssertTrue(latin1(try Data(contentsOf: url)).contains("/Count 0"))
    }

    func testFmt() {
        XCTAssertEqual(PdfWriter.fmt(8), "8")
        XCTAssertEqual(PdfWriter.fmt(594.96), "594.96")
        XCTAssertEqual(PdfWriter.fmt(841.92), "841.92")
        XCTAssertEqual(PdfWriter.fmt(1.5), "1.5")
        XCTAssertEqual(PdfWriter.fmt(0.125), "0.13") // HALF_UP
        XCTAssertEqual(PdfWriter.fmt(612.0), "612")
    }

    func testSipsRenders() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/usr/bin/sips"))
        let pdfURL = temp("pdf")
        try build().write(to: pdfURL)
        let png = temp("png")
        XCTAssertEqual(try RasterTestSupport.sips(pdf: pdfURL, png: png), 0)
        XCTAssertGreaterThan(try Data(contentsOf: png).count, 0)
        // visual check file
        let dir = RasterTestSupport.scratch
        if FileManager.default.fileExists(atPath: dir.path) {
            var px = [UInt8](repeating: 0, count: 64 * 64 * 3)
            for y in 0..<64 { for x in 0..<64 {
                px[(y * 64 + x) * 3] = UInt8(truncatingIfNeeded: x * 4); px[(y * 64 + x) * 3 + 1] = UInt8(truncatingIfNeeded: y * 4); px[(y * 64 + x) * 3 + 2] = 128
            } }
            let d = try write(nil, [(RasterPageInfo(widthPx: 64, heightPx: 64, dpiX: 72, dpiY: 72, pixelFormat: .rgb24), Data(px))])
            let u = temp("pdf")
            try d.write(to: u)
            _ = try RasterTestSupport.sips(pdf: u, png: dir.appendingPathComponent("swift-pdfwriter-check.png"))
        }
    }

    func testConvertFixture() throws {
        let input = DataInputStream(try RasterTestSupport.fixture("a4-mono-2pages.pwg.gz"))
        let url = temp("pdf")
        try RasterToPdf.convert(input: input, to: url)
        let s = latin1(try Data(contentsOf: url))
        XCTAssertTrue(s.contains("/Count 2"))
        XCTAssertTrue(s.contains("/MediaBox [0 0 594.96 841.92]"))
        XCTAssertTrue(s.contains("/Decode [1 0]"))
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/usr/bin/sips"))
        let png = temp("png")
        XCTAssertEqual(try RasterTestSupport.sips(pdf: url, png: png), 0)
    }

    func testRasterToPdfTruncatedThrows() throws {
        let head = try RasterTestSupport.fixture("a4-mono-2pages.pwg.gz").prefix(50_000)
        XCTAssertThrowsError(try RasterToPdf.convert(input: DataInputStream(Data(head)), to: temp("pdf"))) { e in
            XCTAssertTrue(e is RasterFormatError)
        }
    }

    func testImageIOJpegEncoder() throws {
        let enc = ImageIOJpegEncoder()
        let rgb = try XCTUnwrap(enc.encode(width: 8, height: 4, format: .rgb24, pixels: rgbPixels, quality: 85))
        let sof = try XCTUnwrap(PdfWriter.parseJpegSof(rgb))
        XCTAssertEqual(sof.width, 8); XCTAssertEqual(sof.height, 4); XCTAssertEqual(sof.components, 3)
        let gray = try XCTUnwrap(enc.encode(width: 4, height: 2, format: .gray8, pixels: Data(count: 8), quality: 50))
        XCTAssertEqual(PdfWriter.parseJpegSof(gray)?.components, 1)
        XCTAssertNil(enc.encode(width: 16, height: 2, format: .black1, pixels: monoPixels, quality: 85))
        XCTAssertNil(enc.encode(width: 8, height: 4, format: .rgb24, pixels: Data(count: 10), quality: 85))
        XCTAssertNil(enc.encode(width: 5000, height: 4000, format: .gray8, pixels: Data(count: 1), quality: 85))
    }

    func testConverterWithImageIOJpegRendersUrf() throws {
        let src = temp("urf")
        try RasterTestSupport.fixture("a4-rgb-1page.urf.gz").write(to: src)
        let out = temp("pdf")
        var asked: String?
        let conv = RasterDocumentConverter(jpegEncoder: ImageIOJpegEncoder())
        let result = try XCTUnwrap(try conv.convert(source: src, format: "image/urf") { ext in asked = ext; return out })
        XCTAssertEqual(asked, "pdf")
        XCTAssertEqual(result.0, out)
        XCTAssertEqual(result.1, "application/pdf")
        let pdf = try Data(contentsOf: out)
        let s = latin1(pdf)
        XCTAssertTrue(s.contains("/DCTDecode"))
        XCTAssertTrue(s.contains("/DeviceRGB"))
        XCTAssertTrue(s.contains("/MediaBox [0 0 594.96 841.92]"))
        XCTAssertLessThan(pdf.count, 10_000_000)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/usr/bin/sips"))
        let png = temp("png")
        XCTAssertEqual(try RasterTestSupport.sips(pdf: out, png: png), 0)
        if FileManager.default.fileExists(atPath: RasterTestSupport.scratch.path) {
            _ = try RasterTestSupport.sips(pdf: out, png: RasterTestSupport.scratch.appendingPathComponent("swift-urf.png"))
        }
    }

    func testConverterApplicabilityAndCleanup() throws {
        let conv = RasterDocumentConverter(jpegEncoder: nil)
        let pdfSrc = temp("pdf")
        try Data("%PDF-1.7\n".utf8).write(to: pdfSrc)
        var called = false
        XCTAssertNil(try conv.convert(source: pdfSrc, format: "application/pdf") { _ in called = true; return self.temp("pdf") })
        XCTAssertNil(try conv.convert(source: pdfSrc, format: "application/octet-stream") { _ in called = true; return self.temp("pdf") })
        XCTAssertFalse(called)

        // octet-stream sniffed as PWG, converted via the mono fixture
        let mono = temp("bin")
        try RasterTestSupport.fixture("a4-mono-2pages.pwg.gz").write(to: mono)
        let out = temp("pdf")
        let r = try XCTUnwrap(try conv.convert(source: mono, format: "Application/Octet-Stream") { _ in out })
        XCTAssertEqual(r.1, "application/pdf")
        XCTAssertTrue(latin1(try Data(contentsOf: out)).contains("/Count 2"))
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/usr/bin/sips"))
        XCTAssertEqual(try RasterTestSupport.sips(pdf: out, png: temp("png")), 0)

        // malformed raster: throws and removes the partial file
        let bad = temp("urf")
        try (Data("UNIRAST\u{0}".utf8) + Data([0, 0, 0, 1]) + Data(count: 10)).write(to: bad)
        let badOut = temp("pdf")
        XCTAssertThrowsError(try conv.convert(source: bad, format: "image/urf") { _ in badOut })
        XCTAssertFalse(FileManager.default.fileExists(atPath: badOut.path))
    }
}
