import Foundation
import CoreGraphics
import ImageIO

/// JPEG via ImageIO (macOS + iOS). FROZEN INTERFACE.
/// Returns nil on any failure (black1, > 16M pixels, short buffer, encoder error) so callers fall back to Flate.
public struct ImageIOJpegEncoder: JpegEncoder {
    private static let maxPixels = 16_000_000

    public init() {}

    public func encode(width: Int, height: Int, format: PixelFormat, pixels: Data, quality: Int) -> Data? {
        if width <= 0 || height <= 0 { return nil }
        let (n, overflow) = width.multipliedReportingOverflow(by: height)
        if overflow || n > ImageIOJpegEncoder.maxPixels { return nil }
        let colorSpace: CGColorSpace
        let bitsPerPixel: Int
        switch format {
        case .gray8: colorSpace = CGColorSpaceCreateDeviceGray(); bitsPerPixel = 8
        case .rgb24: colorSpace = CGColorSpaceCreateDeviceRGB(); bitsPerPixel = 24
        case .black1: return nil
        }
        let bytesPerRow = width * bitsPerPixel / 8
        if pixels.count < bytesPerRow * height { return nil }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: bitsPerPixel,
                                  bytesPerRow: bytesPerRow, space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        let q = Double(min(100, max(0, quality))) / 100.0
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
