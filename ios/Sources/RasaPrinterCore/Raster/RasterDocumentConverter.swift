import Foundation

/// DocumentConverter turning image/urf and image/pwg-raster (or sniffed octet-stream) into PDF. FROZEN INTERFACE.
public struct RasterDocumentConverter: DocumentConverter {
    public let jpegEncoder: JpegEncoder?
    public init(jpegEncoder: JpegEncoder? = ImageIOJpegEncoder()) { self.jpegEncoder = jpegEncoder }

    public func convert(source: URL, format: String, target: (String) -> URL) throws -> (URL, String)? {
        let f = format.lowercased()
        let applicable = f == "image/urf" || f == "image/pwg-raster" ||
            (f == "application/octet-stream" && sniffsRaster(source))
        if !applicable { return nil }
        let out = target("pdf")
        do {
            let input = try FileInputStream(url: source)
            try RasterToPdf.convert(input: input, to: out, jpegEncoder: jpegEncoder)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return (out, "application/pdf")
    }

    private func sniffsRaster(_ source: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: source) else { return false }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 8), !head.isEmpty else { return false }
        return RasterDecoder.sniff(head) != nil
    }
}
