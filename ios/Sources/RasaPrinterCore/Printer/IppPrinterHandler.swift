import Foundation

/// IPP Everywhere operation handler, transport-agnostic. FROZEN INTERFACE.
public final class IppPrinterHandler {
    public init(config: @escaping () -> PrinterConfig, jobs: JobStore, clock: @escaping () -> Date = { Date() }) { fatalError("TODO unit swift-printer") }
    /// - document: bytes following the IPP attributes (read to EOF for Print-Job / Send-Document)
    /// - printerUri: e.g. "ipp://192.168.1.5:8631/ipp/print" (from the HTTP Host header)
    public func handle(_ request: IppMessage, document: ByteInputStream, printerUri: String) -> IppMessage { fatalError("TODO unit swift-printer") }
}

/// HTTP adapter: POST application/ipp → IPP; GET "/" → HTML status; GET "/icon.png". FROZEN INTERFACE.
public final class IppHttpHandler {
    public init(handler: IppPrinterHandler, config: @escaping () -> PrinterConfig, jobs: JobStore, iconPng: @escaping () -> Data?) { fatalError("TODO unit swift-printer") }
    public func handle(_ request: HttpRequest) -> HttpResponse { fatalError("TODO unit swift-printer") }
}

/// Printer attribute catalogue + Bonjour TXT record. FROZEN INTERFACE (only these two entry points are frozen).
public enum PrinterAttributes {
    /// TXT record for `_ipp._tcp` (txtvers, qtotal, rp, ty, product, pdl, URF, Color, Duplex, UUID, kind, note...).
    public static func bonjourTxt(config: PrinterConfig) -> [String: String] { fatalError("TODO unit swift-printer") }
    /// Supported document formats (document-format-supported).
    public static let documentFormats: [String] = ["application/pdf", "image/pwg-raster", "image/urf", "image/jpeg", "image/png", "application/octet-stream"]
}
