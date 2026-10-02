import Foundation
import zlib

/// Dependency-free PDF writer: one full-page image per page. FROZEN INTERFACE.
///
/// PDF 1.4 with a classic xref table. Image encoding: black1 → /DeviceGray 1 bpc with /Decode [1 0],
/// FlateDecode; gray8 / rgb24 → JPEG via `jpegEncoder` (DCTDecode) when it returns a JPEG whose SOF
/// matches the page, else FlateDecode (zlib-wrapped deflate).
public final class PdfWriter {
    private static let catalogId = 1
    private static let pagesId = 2
    private static let infoId = 3
    private static let firstPageId = 4
    private static let flushThreshold = 256 * 1024

    private let handle: FileHandle
    private let jpegEncoder: JpegEncoder?
    private let jpegQuality: Int
    private var pending = Data()
    private var count: UInt64 = 0
    private var offsets: [Int: UInt64] = [:]
    private var pageIds: [Int] = []
    private var nextId = PdfWriter.firstPageId
    private var closed = false

    public init(url: URL, jpegEncoder: JpegEncoder? = nil, jpegQuality: Int = 85) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw RasterFormatError("cannot create PDF file \(url.path)")
        }
        handle = try FileHandle(forWritingTo: url)
        self.jpegEncoder = jpegEncoder
        self.jpegQuality = jpegQuality
        writeAscii("%PDF-1.4\n")
        write(Data([0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]))
    }

    deinit { try? handle.close() }

    /// Adds one page sized info.widthPoints x info.heightPoints with the image filling it.
    public func addPage(_ info: RasterPageInfo, pixels: Data) throws {
        if closed { throw RasterFormatError("PdfWriter is closed") }
        if info.widthPx <= 0 || info.heightPx <= 0 { throw RasterFormatError("empty page") }
        let (needed, overflow) = info.rowBytes.multipliedReportingOverflow(by: info.heightPx)
        if overflow || pixels.count < needed { throw RasterFormatError("pixel buffer too small") }
        let imageId = nextId; nextId += 1
        let contentId = nextId; nextId += 1
        let pageId = nextId; nextId += 1

        var colorSpace = "/ColorSpace /DeviceGray /BitsPerComponent 8"
        var extra = ""
        var filter = "/FlateDecode"
        var data: Data?
        switch info.pixelFormat {
        case .black1:
            colorSpace = "/ColorSpace /DeviceGray /BitsPerComponent 1"
            extra = " /Decode [1 0]"
        case .gray8: break
        case .rgb24: colorSpace = "/ColorSpace /DeviceRGB /BitsPerComponent 8"
        }
        if info.pixelFormat != .black1, let enc = jpegEncoder,
           let jpg = enc.encode(width: info.widthPx, height: info.heightPx, format: info.pixelFormat, pixels: pixels, quality: jpegQuality),
           let sof = PdfWriter.parseJpegSof(jpg), sof.width == info.widthPx, sof.height == info.heightPx {
            switch sof.components {
            case 1: colorSpace = "/ColorSpace /DeviceGray /BitsPerComponent 8"
            case 3: colorSpace = "/ColorSpace /DeviceRGB /BitsPerComponent 8"
            case 4:
                colorSpace = "/ColorSpace /DeviceCMYK /BitsPerComponent 8"
                extra = " /Decode [1 0 1 0 1 0 1 0]"
            default: break
            }
            if sof.components == 1 || sof.components == 3 || sof.components == 4 {
                data = jpg
                filter = "/DCTDecode"
            }
        }
        let body = try data ?? PdfWriter.deflate(pixels, length: needed)

        beginObject(imageId)
        writeAscii("<< /Type /XObject /Subtype /Image /Width \(info.widthPx) /Height \(info.heightPx) " +
                   "\(colorSpace)\(extra) /Filter \(filter) /Length \(body.count) >>\nstream\n")
        write(body)
        writeAscii("\nendstream\nendobj\n")

        // Points computed in Float like the Kotlin reference so MediaBox strings match exactly.
        let w = PdfWriter.fmt(Float(info.widthPx) * 72 / Float(info.dpiX))
        let h = PdfWriter.fmt(Float(info.heightPx) * 72 / Float(info.dpiY))
        let content = "q \(w) 0 0 \(h) 0 0 cm /Im0 Do Q"
        beginObject(contentId)
        writeAscii("<< /Length \(content.utf8.count) >>\nstream\n")
        writeAscii(content)
        writeAscii("\nendstream\nendobj\n")

        beginObject(pageId)
        writeAscii("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(w) \(h)] " +
                   "/Resources << /XObject << /Im0 \(imageId) 0 R >> >> /Contents \(contentId) 0 R >>\nendobj\n")
        pageIds.append(pageId)
        try flushIfNeeded()
    }

    /// Writes page tree, catalog, xref, trailer; closes the file. Idempotent.
    public func close() throws {
        if closed { return }
        closed = true
        defer { try? handle.close() }
        beginObject(PdfWriter.pagesId)
        writeAscii("<< /Type /Pages /Kids [\(pageIds.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(pageIds.count) >>\nendobj\n")
        beginObject(PdfWriter.catalogId)
        writeAscii("<< /Type /Catalog /Pages \(PdfWriter.pagesId) 0 R >>\nendobj\n")
        beginObject(PdfWriter.infoId)
        writeAscii("<< /Producer (Rasa Printer) >>\nendobj\n")

        let xrefPos = count
        let size = nextId
        var s = "xref\n0 \(size)\n0000000000 65535 f \n"
        for id in 1..<size {
            let off = String(offsets[id] ?? 0)
            s += String(repeating: "0", count: max(0, 10 - off.count)) + off + " 00000 n \n"
        }
        s += "trailer\n<< /Size \(size) /Root \(PdfWriter.catalogId) 0 R /Info \(PdfWriter.infoId) 0 R >>\nstartxref\n\(xrefPos)\n%%EOF\n"
        writeAscii(s)
        try flush()
        try handle.synchronize()
    }

    // MARK: - output

    private func beginObject(_ id: Int) {
        offsets[id] = count
        writeAscii("\(id) 0 obj\n")
    }

    private func writeAscii(_ s: String) { write(Data(s.utf8)) }

    private func write(_ d: Data) {
        pending.append(d)
        count += UInt64(d.count)
    }

    private func flushIfNeeded() throws {
        if pending.count >= PdfWriter.flushThreshold { try flush() }
    }

    private func flush() throws {
        if pending.isEmpty { return }
        try handle.write(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
    }

    // MARK: - helpers

    struct JpegSof { let width: Int; let height: Int; let components: Int }

    /// Walks JPEG markers to the first SOF0/1/2 segment; nil if absent or malformed.
    static func parseJpegSof(_ data: Data) -> JpegSof? {
        let b = [UInt8](data)
        func u8(_ i: Int) -> Int { Int(b[i]) }
        if b.count < 4 || u8(0) != 0xFF || u8(1) != 0xD8 { return nil }
        var i = 2
        while i + 3 < b.count {
            if u8(i) != 0xFF { return nil }
            while i + 1 < b.count && u8(i + 1) == 0xFF { i += 1 }
            if i + 1 >= b.count { return nil }
            let m = u8(i + 1)
            i += 2
            if m == 0x01 || (0xD0...0xD8).contains(m) { continue }
            if m == 0xD9 || m == 0xDA { return nil }
            if i + 2 > b.count { return nil }
            let len = (u8(i) << 8) | u8(i + 1)
            if len < 2 { return nil }
            if m == 0xC0 || m == 0xC1 || m == 0xC2 {
                if len < 8 || i + 8 > b.count { return nil }
                let h = (u8(i + 3) << 8) | u8(i + 4)
                let w = (u8(i + 5) << 8) | u8(i + 6)
                return JpegSof(width: w, height: h, components: u8(i + 7))
            }
            i += len
        }
        return nil
    }

    /// zlib-wrapped deflate (RFC 1950), as required by /FlateDecode.
    static func deflate(_ pixels: Data, length: Int) throws -> Data {
        var bound = compressBound(uLong(length))
        var out = Data(count: Int(bound))
        let rc: Int32 = out.withUnsafeMutableBytes { dst in
            pixels.withUnsafeBytes { src in
                compress2(dst.bindMemory(to: Bytef.self).baseAddress!, &bound,
                          src.bindMemory(to: Bytef.self).baseAddress!, uLong(length), Z_DEFAULT_COMPRESSION)
            }
        }
        if rc != Z_OK { throw RasterFormatError("deflate failed: zlib error \(rc)") }
        out.count = Int(bound)
        return out
    }

    /// Two decimals, HALF_UP on the exact binary value, trailing zeros trimmed (Kotlin BigDecimal semantics).
    static func fmt(_ v: Float) -> String {
        let d = Double(v) // exact
        let scaled = (d * 100).rounded(.toNearestOrAwayFromZero)
        let cents = Int64(scaled)
        let neg = cents < 0
        let a = cents.magnitude
        var s = "\(a / 100)"
        let frac = a % 100
        if frac != 0 {
            s += frac < 10 ? ".0\(frac)" : ".\(frac)"
            while s.hasSuffix("0") { s.removeLast() }
        }
        return neg ? "-" + s : s
    }
}

/// FROZEN INTERFACE. Decodes a raster stream and writes a PDF, buffering one page at a time.
public enum RasterToPdf {
    public static func convert(input: ByteInputStream, to url: URL, jpegEncoder: JpegEncoder? = nil) throws {
        let writer = try PdfWriter(url: url, jpegEncoder: jpegEncoder)
        let sink = PageBufferSink(writer)
        do {
            try RasterDecoder.decode(input, sink: sink)
            if let e = sink.error { throw e }
        } catch {
            // Like Kotlin's use {}: the writer is closed (trailer written) even on failure.
            try? writer.close()
            throw error
        }
        try writer.close()
    }

    private final class PageBufferSink: RasterSink {
        let writer: PdfWriter
        var info: RasterPageInfo?
        var buf: Data?
        var pos = 0
        var error: Error?

        init(_ writer: PdfWriter) { self.writer = writer }

        func beginPage(_ info: RasterPageInfo) {
            self.info = info
            pos = 0
            let (size, overflow) = info.rowBytes.multipliedReportingOverflow(by: info.heightPx)
            if overflow {
                if error == nil { error = RasterFormatError("page too large") }
                buf = nil
                return
            }
            buf = Data(count: size)
        }

        func row(_ row: UnsafeBufferPointer<UInt8>) {
            guard buf != nil, let info = info, let src = row.baseAddress else { return }
            let n = info.rowBytes
            if pos + n > buf!.count || row.count < n { return }
            let p = pos
            buf!.withUnsafeMutableBytes { dst in
                (dst.baseAddress! + p).copyMemory(from: src, byteCount: n)
            }
            pos += n
        }

        func endPage() {
            guard let i = info, let b = buf else { return }
            info = nil
            buf = nil
            if error != nil { return }
            do { try writer.addPage(i, pixels: b) } catch { self.error = error }
        }
    }
}
