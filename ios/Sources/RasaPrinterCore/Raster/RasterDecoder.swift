import Foundation

/// Streaming decoder for Apple URF ("UNIRAST") and PWG Raster ("RaS2"). FROZEN INTERFACE.
///
/// Detects the format from the magic, decodes every page, un-RLEs rows and converts to a `PixelFormat`:
///  - 1-bit black / 1-bit gray → black1 (gray 1-bit is inverted so 1 = black)
///  - 8-bit gray (sgray / W8 / DeviceW) → gray8 (8-bit black/K is inverted)
///  - 24-bit sRGB / AdobeRGB / DeviceRGB → rgb24
///  - 32-bit CMYK → rgb24 (naive conversion); 16-bit depths → high byte
/// Throws `RasterFormatError` on malformed or truncated input.
///
/// The input is read through an internal 64 KiB buffer, so the decoder may consume bytes from
/// `input` beyond the end of the last page (unlike the Kotlin version, which reads unbuffered).
public enum RasterDecoder {
    private static let urfMagic: [UInt8] = Array("UNIRAST".utf8) + [0]
    private static let pwgMagic: [UInt8] = Array("RaS2".utf8)

    private static let pwgHeaderSize = 1796
    private static let urfPageHeaderSize = 32
    private static let maxDimension: UInt32 = 65_536
    private static let maxLineBytes = 64 * 1024 * 1024

    public static func decode(_ input: ByteInputStream, sink: RasterSink) throws {
        let reader = Reader(input)
        do {
            var magic = [UInt8](repeating: 0, count: 8)
            try reader.readFully(&magic, 0, 4, "file header")
            if startsWith(magic, pwgMagic) {
                try decodePwg(reader, sink)
                return
            }
            try reader.readFully(&magic, 4, 4, "file header")
            if startsWith(magic, urfMagic) {
                try decodeUrf(reader, sink)
                return
            }
            throw RasterFormatError("unknown raster magic: " + magic.map { String(format: "%02x", $0) }.joined(separator: " "))
        } catch let e as RasterFormatError {
            throw e
        } catch {
            throw RasterFormatError("I/O error while reading raster: \(error)")
        }
    }

    /// "image/urf" | "image/pwg-raster" | nil from the first 8 bytes.
    public static func sniff(_ head: Data) -> String? {
        let h = [UInt8](head.prefix(8))
        if h.count >= 8 && startsWith(h, urfMagic) { return "image/urf" }
        if h.count >= 4 && startsWith(h, pwgMagic) { return "image/pwg-raster" }
        return nil
    }

    // MARK: - URF

    private static func decodeUrf(_ input: Reader, _ sink: RasterSink) throws {
        var countBuf = [UInt8](repeating: 0, count: 4)
        try input.readFully(&countBuf, 0, 4, "URF page count")
        let pageCount = u32(countBuf, 0)
        var header = [UInt8](repeating: 0, count: urfPageHeaderSize)
        var page: UInt32 = 0
        while pageCount == 0 || page < pageCount {
            if pageCount == 0 {
                guard let first = try input.readByte() else { return }
                header[0] = first
                try input.readFully(&header, 1, urfPageHeaderSize - 1, "URF page header")
            } else {
                try input.readFully(&header, 0, urfPageHeaderSize, "URF page \(UInt64(page) + 1) header")
            }
            let bpp = Int(header[0])
            let colorSpace = Int(header[1])
            let width = try checkDim(u32(header, 12), "width")
            let height = try checkDim(u32(header, 16), "height")
            let dpi = Int(Int32(bitPattern: u32(header, 20)))
            if dpi <= 0 { throw RasterFormatError("invalid URF resolution \(dpi)") }
            let family: Family
            switch colorSpace {
            case 0, 4: family = .gray
            case 1, 3, 5: family = .rgb
            case 6: family = .cmyk
            default: throw RasterFormatError("unsupported URF color space \(colorSpace)")
            }
            let layout = try Layout.of(family, bpp, "URF")
            try decodePage(input, sink, layout, width, height, dpi, dpi, try lineBytes(width, bpp))
            page += 1
        }
    }

    // MARK: - PWG

    private static func decodePwg(_ input: Reader, _ sink: RasterSink) throws {
        var h = [UInt8](repeating: 0, count: pwgHeaderSize)
        while true {
            guard let first = try input.readByte() else { return } // clean EOF at a page boundary
            h[0] = first
            try input.readFully(&h, 1, pwgHeaderSize - 1, "PWG page header")
            let dpiX = Int(Int32(bitPattern: u32(h, 276)))
            let dpiY = Int(Int32(bitPattern: u32(h, 280)))
            let width = try checkDim(u32(h, 372), "width")
            let height = try checkDim(u32(h, 376), "height")
            let bpc = Int(Int32(bitPattern: u32(h, 384)))
            let bpp = Int(Int32(bitPattern: u32(h, 388)))
            let bytesPerLine = u32(h, 392)
            let colorOrder = u32(h, 396)
            let colorSpace = Int(Int32(bitPattern: u32(h, 400)))
            if dpiX <= 0 || dpiY <= 0 { throw RasterFormatError("invalid PWG resolution \(dpiX)x\(dpiY)") }
            if colorOrder != 0 { throw RasterFormatError("unsupported PWG color order \(colorOrder)") }
            let family: Family
            switch colorSpace {
            case 0, 18, 48: family = .gray
            case 1, 19, 20, 50: family = .rgb
            case 3: family = .black
            case 6, 51: family = .cmyk
            default: throw RasterFormatError("unsupported PWG color space \(colorSpace)")
            }
            if bpp != bpc * family.components {
                throw RasterFormatError("unsupported PWG depth: \(bpc) bits/color, \(bpp) bits/pixel, color space \(colorSpace)")
            }
            let layout = try Layout.of(family, bpp, "PWG")
            let expected = try lineBytes(width, bpp)
            if Int(bytesPerLine) != expected {
                throw RasterFormatError("PWG bytesPerLine \(bytesPerLine) does not match width \(width) x \(bpp) bpp")
            }
            try decodePage(input, sink, layout, width, height, dpiX, dpiY, expected)
        }
    }

    // MARK: - shared

    private enum Family: String {
        case gray, black, rgb, cmyk // gray = W / sGray / DeviceW (0 = black); black = K (1/255 = black)
        var components: Int { switch self { case .gray, .black: return 1; case .rgb: return 3; case .cmyk: return 4 } }
        var blank: UInt8 { switch self { case .gray, .rgb: return 0xFF; case .black, .cmyk: return 0x00 } }
    }

    /// Source layout of one coded line and how to convert it.
    private struct Layout {
        let family: Family
        let bpp: Int
        let format: PixelFormat
        /// RLE pixel unit in bytes (1 for sub-byte depths).
        var unit: Int { bpp < 8 ? 1 : bpp / 8 }
        var bytesPerComponent: Int { bpp < 8 ? 0 : bpp / 8 / family.components }

        static func of(_ family: Family, _ bpp: Int, _ what: String) throws -> Layout {
            let fmt: PixelFormat?
            switch family {
            case .gray, .black: fmt = bpp == 1 ? .black1 : (bpp == 8 || bpp == 16) ? .gray8 : nil
            case .rgb: fmt = (bpp == 24 || bpp == 48) ? .rgb24 : nil
            case .cmyk: fmt = (bpp == 32 || bpp == 64) ? .rgb24 : nil
            }
            guard let f = fmt else {
                throw RasterFormatError("unsupported \(what) bits per pixel \(bpp) for \(family.rawValue.uppercased()) color")
            }
            return Layout(family: family, bpp: bpp, format: f)
        }
    }

    private static func decodePage(
        _ input: Reader, _ sink: RasterSink, _ layout: Layout,
        _ width: Int, _ height: Int, _ dpiX: Int, _ dpiY: Int, _ bytesPerLine: Int
    ) throws {
        let info = RasterPageInfo(widthPx: width, heightPx: height, dpiX: dpiX, dpiY: dpiY, pixelFormat: layout.format)
        let line = UnsafeMutablePointer<UInt8>.allocate(capacity: bytesPerLine)
        line.initialize(repeating: 0, count: bytesPerLine)
        let outCount = info.rowBytes
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: outCount)
        out.initialize(repeating: 0, count: outCount)
        defer { line.deallocate(); out.deallocate() }
        let unit = layout.unit
        sink.beginPage(info)
        var y = 0
        while y < height {
            let repeatCount = Int(try input.readByteOrThrow("line repeat at row \(y)")) + 1
            var pos = 0
            while pos < bytesPerLine {
                let n = Int(Int8(bitPattern: try input.readByteOrThrow("run at row \(y)")))
                if n == -128 {
                    (line + pos).update(repeating: layout.family.blank, count: bytesPerLine - pos)
                    pos = bytesPerLine
                } else if n >= 0 {
                    let count = (n + 1) * unit
                    if pos + count > bytesPerLine { throw RasterFormatError("repeat run overflows line at row \(y)") }
                    try input.readFully(line + pos, unit, "pixel at row \(y)")
                    if unit == 1 {
                        (line + pos + 1).update(repeating: line[pos], count: count - 1)
                    } else {
                        var p = pos + unit
                        while p < pos + count {
                            (line + p).update(from: line + pos, count: unit)
                            p += unit
                        }
                    }
                    pos += count
                } else {
                    let count = (-n + 1) * unit
                    if pos + count > bytesPerLine { throw RasterFormatError("literal run overflows line at row \(y)") }
                    try input.readFully(line + pos, count, "literal pixels at row \(y)")
                    pos += count
                }
            }
            convert(layout, width, line, out, outCount)
            // A line repeat that runs past the page end is clamped rather than rejected.
            let emit = min(repeatCount, height - y)
            let row = UnsafeBufferPointer(start: UnsafePointer(out), count: outCount)
            for _ in 0..<emit { sink.row(row) }
            y += emit
        }
        sink.endPage()
    }

    private static func convert(_ layout: Layout, _ width: Int, _ src: UnsafeMutablePointer<UInt8>,
                                _ dst: UnsafeMutablePointer<UInt8>, _ dstCount: Int) {
        switch layout.format {
        case .black1:
            if layout.family == .gray {
                for i in 0..<dstCount { dst[i] = ~src[i] }
            } else {
                dst.update(from: src, count: dstCount)
            }
            let pad = dstCount * 8 - width
            if pad > 0 { dst[dstCount - 1] &= UInt8(truncatingIfNeeded: 0xFF << pad) }
        case .gray8:
            let step = layout.bytesPerComponent
            let invert = layout.family == .black
            var s = 0
            for i in 0..<width {
                let v = src[s]
                dst[i] = invert ? 255 - v : v
                s += step
            }
        case .rgb24:
            let step = layout.bytesPerComponent
            if layout.family == .rgb {
                if step == 1 {
                    dst.update(from: src, count: dstCount)
                } else {
                    for i in 0..<dstCount { dst[i] = src[i * step] }
                }
            } else {
                var s = 0
                var d = 0
                for _ in 0..<width {
                    let c = Int(src[s]), m = Int(src[s + step]), yy = Int(src[s + 2 * step]), k = Int(src[s + 3 * step])
                    dst[d] = UInt8(255 - min(255, c + k))
                    dst[d + 1] = UInt8(255 - min(255, m + k))
                    dst[d + 2] = UInt8(255 - min(255, yy + k))
                    s += 4 * step
                    d += 3
                }
            }
        }
    }

    private static func lineBytes(_ width: Int, _ bpp: Int) throws -> Int {
        let bytes = (Int64(width) * Int64(bpp) + 7) / 8
        if bytes > Int64(maxLineBytes) { throw RasterFormatError("raster line too large: \(bytes) bytes") }
        return Int(bytes)
    }

    private static func checkDim(_ v: UInt32, _ what: String) throws -> Int {
        if v == 0 || v > maxDimension { throw RasterFormatError("invalid raster \(what) \(v)") }
        return Int(v)
    }

    private static func startsWith(_ a: [UInt8], _ prefix: [UInt8]) -> Bool {
        a.count >= prefix.count && a[0..<prefix.count].elementsEqual(prefix)
    }

    private static func u32(_ b: [UInt8], _ off: Int) -> UInt32 {
        UInt32(b[off]) << 24 | UInt32(b[off + 1]) << 16 | UInt32(b[off + 2]) << 8 | UInt32(b[off + 3])
    }

    /// Buffered reader over a ByteInputStream; EOF mid-structure → RasterFormatError.
    private final class Reader {
        private let input: ByteInputStream
        private let buf: UnsafeMutablePointer<UInt8>
        private let capacity = 64 * 1024
        private var pos = 0
        private var end = 0

        init(_ input: ByteInputStream) {
            self.input = input
            buf = .allocate(capacity: capacity)
        }

        deinit { buf.deallocate() }

        /// Refills the buffer; false at EOF.
        private func fill() throws -> Bool {
            let n = try input.read(into: buf, maxLength: capacity)
            pos = 0
            end = max(0, n)
            return n > 0
        }

        func readByte() throws -> UInt8? {
            if pos >= end, try !fill() { return nil }
            let b = buf[pos]
            pos += 1
            return b
        }

        func readByteOrThrow(_ what: String) throws -> UInt8 {
            guard let b = try readByte() else { throw truncated(what) }
            return b
        }

        func readFully(_ dst: UnsafeMutablePointer<UInt8>, _ len: Int, _ what: String) throws {
            var done = 0
            while done < len {
                if pos >= end, try !fill() { throw truncated(what) }
                let n = min(len - done, end - pos)
                (dst + done).update(from: buf + pos, count: n)
                pos += n
                done += n
            }
        }

        func readFully(_ dst: inout [UInt8], _ off: Int, _ len: Int, _ what: String) throws {
            try dst.withUnsafeMutableBufferPointer { try readFully($0.baseAddress! + off, len, what) }
        }

        private func truncated(_ what: String) -> RasterFormatError {
            RasterFormatError("truncated raster data: unexpected end of stream reading \(what)")
        }
    }
}
