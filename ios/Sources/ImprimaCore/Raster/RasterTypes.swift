import Foundation

public struct RasterFormatError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// FROZEN INTERFACE.
public enum PixelFormat {
    /// 1 bpp, 1 = black, MSB first, rows byte-padded.
    case black1
    /// 8-bit gray, 0 = black.
    case gray8
    /// 24-bit RGB.
    case rgb24
    public var bitsPerPixel: Int { switch self { case .black1: return 1; case .gray8: return 8; case .rgb24: return 24 } }
    public var components: Int { self == .rgb24 ? 3 : 1 }
}

/// FROZEN INTERFACE.
public struct RasterPageInfo: Equatable {
    public var widthPx: Int
    public var heightPx: Int
    public var dpiX: Int
    public var dpiY: Int
    public var pixelFormat: PixelFormat
    public init(widthPx: Int, heightPx: Int, dpiX: Int, dpiY: Int, pixelFormat: PixelFormat) {
        self.widthPx = widthPx; self.heightPx = heightPx; self.dpiX = dpiX; self.dpiY = dpiY; self.pixelFormat = pixelFormat
    }
    public var rowBytes: Int { (widthPx * pixelFormat.bitsPerPixel + 7) / 8 }
    public var widthPoints: Double { Double(widthPx) * 72.0 / Double(dpiX) }
    public var heightPoints: Double { Double(heightPx) * 72.0 / Double(dpiY) }
}

/// Receives decoded pages row by row. FROZEN INTERFACE. `row` buffer is reused - copy if kept.
public protocol RasterSink: AnyObject {
    func beginPage(_ info: RasterPageInfo)
    func row(_ row: UnsafeBufferPointer<UInt8>)
    func endPage()
}

/// Optional lossy encoder (DCTDecode) for gray8/rgb24 pages; nil → Flate fallback. FROZEN INTERFACE.
public protocol JpegEncoder {
    func encode(width: Int, height: Int, format: PixelFormat, pixels: Data, quality: Int) -> Data?
}
