import Foundation

/// Printer attribute catalogue for an IPP Everywhere (PWG 5100.14) / AirPrint virtual printer.
/// Every attribute name appears at most once; group membership is derived from the name.
public enum PrinterAttributes {
    /// TXT record for `_ipp._tcp` (txtvers, qtotal, rp, ty, product, pdl, URF, Color, Duplex, UUID, kind, note...).
    public static func bonjourTxt(config: PrinterConfig) -> [String: String] {
        var m: [String: String] = [
            "txtvers": "1",
            "qtotal": "1",
            "rp": "ipp/print",
            "ty": config.name,
            "product": "(\(config.makeAndModel))",
            "pdl": config.compatibilityMode ? "application/pdf,image/pwg-raster,image/urf,image/jpeg,image/png" : "application/pdf",
            "Color": "T",
            "Duplex": "F",
            "Scan": "F",
            "Fax": "F",
            "kind": "document",
            "UUID": config.uuid,
            "priority": "0",
        ]
        // URF is what makes iOS list the printer for AirPrint; PDF-only mode deliberately omits it.
        if config.compatibilityMode { m["URF"] = urfSupported.joined(separator: ",") }
        if !config.location.isEmpty { m["note"] = config.location }
        return m
    }

    /// Supported document formats (document-format-supported) for the config's mode. In PDF-only mode
    /// application/octet-stream is only a transport type: the document must still sniff as PDF.
    public static func documentFormats(config: PrinterConfig) -> [String] {
        config.compatibilityMode
            ? ["application/pdf", "image/pwg-raster", "image/urf", "image/jpeg", "image/png", "application/octet-stream"]
            : ["application/pdf", "application/octet-stream"]
    }

    private static let urfSupported = ["V1.4", "W8", "SRGB24", "CP1", "RS300-600", "IS1", "MT1-2-3", "OB9", "PQ3-4-5", "DM1"]

    static let mediaColDatabase = "media-col-database"

    static let operations: [UInt16] = [
        IppOperation.printJob, IppOperation.validateJob, IppOperation.createJob, IppOperation.sendDocument,
        IppOperation.cancelJob, IppOperation.getJobAttributes, IppOperation.getJobs,
        IppOperation.getPrinterAttributes, IppOperation.cancelMyJobs, IppOperation.closeJob, IppOperation.identifyPrinter,
    ]

    private static let margin: Int32 = 423

    private struct Media { let keyword: String; let x: Int32; let y: Int32 }

    /// Sizes in hundredths of a millimetre (PWG 5101.1).
    private static let media: [Media] = [
        Media(keyword: "iso_a4_210x297mm", x: 21000, y: 29700),
        Media(keyword: "na_letter_8.5x11in", x: 21590, y: 27940),
        Media(keyword: "na_legal_8.5x14in", x: 21590, y: 35560),
        Media(keyword: "iso_a5_148x210mm", x: 14800, y: 21000),
        Media(keyword: "na_index-4x6_4x6in", x: 10160, y: 15240),
    ]
    private static let mediaReady = ["iso_a4_210x297mm", "na_letter_8.5x11in"]

    private static let templateBases: Set<String> = [
        "copies", "media", "media-col", "media-source", "media-type", "orientation-requested",
        "print-color-mode", "print-quality", "printer-resolution", "sides", "output-bin", "finishings",
        "page-ranges", "print-content-optimize", "print-rendering-intent", "overrides",
    ]
    private static let templateExtra: Set<String> = [
        "media-size-supported", "media-top-margin-supported", "media-bottom-margin-supported",
        "media-left-margin-supported", "media-right-margin-supported",
    ]

    /// Names of attributes belonging to the "job-template" group keyword.
    static let jobTemplateNames: Set<String> = Set(allNames().filter(isJobTemplate))

    /// Names belonging to "printer-description" (everything else except media-col-database).
    static let descriptionNames: Set<String> = Set(allNames().filter { !isJobTemplate($0) && $0 != mediaColDatabase })

    private static func isJobTemplate(_ name: String) -> Bool {
        if templateExtra.contains(name) { return true }
        guard let dash = name.lastIndex(of: "-") else { return false }
        let base = String(name[..<dash])
        let suffix = String(name[name.index(after: dash)...])
        return templateBases.contains(base) && ["default", "supported", "ready"].contains(suffix)
    }

    /// Superset of names across both modes (compatibility mode adds urf-supported / pwg-raster-*).
    private static func allNames() -> [String] {
        build(config: PrinterConfig(name: "x", uuid: "x", compatibilityMode: true),
              printerUri: "ipp://localhost:\(PrinterConfig.defaultPort)\(PrinterConfig.resourcePath)",
              queuedJobCount: 0, upTimeSeconds: 1, now: Date(timeIntervalSince1970: 0)).map { $0.name }
    }

    private static let res300 = IppValue.resolution(x: 300, y: 300, units: 3)
    private static let res600 = IppValue.resolution(x: 600, y: 600, units: 3)

    /// Full printer attribute list.
    /// - changeTime: when config / state last changed; *-change-time uses printer-up-time's epoch-seconds scale.
    static func build(config: PrinterConfig, printerUri: String, queuedJobCount: Int32, upTimeSeconds: Int32,
                      now: Date, changeTime: Date? = nil) -> [IppAttribute] {
        let change = changeTime ?? now
        let changeSeconds = Int32(clamping: max(0, Int64(change.timeIntervalSince1970.rounded(.down))))
        let httpBase = httpBase(printerUri: printerUri, fallbackPort: config.port)
        var c = Catalogue()
        // --- charset / language / protocol
        c.add("charset-configured", .charset("utf-8"))
        c.add("charset-supported", .charset("utf-8"))
        c.add("natural-language-configured", .naturalLanguage("en"))
        c.add("generated-natural-language-supported", .naturalLanguage("en"))
        c.kw("ipp-versions-supported", "1.1", "2.0")
        c.kw("ipp-features-supported", "ipp-everywhere")
        c.add("operations-supported", operations.map { .enumValue(Int32($0)) })
        c.add("printer-uri-supported", .uri(printerUri))
        c.kw("uri-security-supported", "none")
        c.kw("uri-authentication-supported", "none")

        // --- identity
        c.add("printer-name", .name(config.name))
        c.text("printer-info", config.name)
        c.text("printer-location", config.location)
        c.text("printer-make-and-model", config.makeAndModel)
        c.add("printer-uuid", .uri("urn:uuid:" + config.uuid))
        c.text("printer-device-id", "MFG:Imprima;MDL:Virtual Printer;CMD:\(config.compatibilityMode ? "PDF,PWGRaster,URF" : "PDF");CLS:PRINTER;")
        c.add("printer-more-info", .uri("\(httpBase)/"))
        c.add("printer-icons", .uri("\(httpBase)/icon.png"))
        c.add("printer-geo-location", .outOfBand(IppTag.unknown))
        c.text("printer-organization", "")
        c.text("printer-organizational-unit", "")
        c.kw("printer-kind", "document")

        // --- state
        c.enums("printer-state", 3)
        c.kw("printer-state-reasons", "none")
        c.text("printer-state-message", "Idle")
        c.bool("printer-is-accepting-jobs", true)
        c.ints("queued-job-count", queuedJobCount)
        c.ints("printer-up-time", upTimeSeconds)
        c.add("printer-current-time", dateTime(now))
        c.add("printer-config-change-date-time", dateTime(change))
        c.ints("printer-config-change-time", changeSeconds)
        c.add("printer-state-change-date-time", dateTime(change))
        c.ints("printer-state-change-time", changeSeconds)
        c.add("printer-supply", .octetString(Data("type=toner;maxcapacity=100;level=100;colorantname=black;".utf8)))
        c.text("printer-supply-description", "Virtual toner")
        c.add("printer-supply-info-uri", .uri("\(httpBase)/"))
        c.ints("pages-per-minute", 10)
        c.ints("pages-per-minute-color", 10)

        // --- document handling
        c.add("document-format-default", .mimeMediaType("application/pdf"))
        c.add("document-format-supported", documentFormats(config: config).map { .mimeMediaType($0) })
        c.kw("compression-supported", "none")
        c.kw("pdl-override-supported", "attempted")
        c.bool("multiple-document-jobs-supported", false)
        c.ints("multiple-operation-time-out", 120)
        c.kw("multiple-operation-time-out-action", "abort-job")
        c.bool("preferred-attributes-supported", false)
        c.kw("printer-get-attributes-supported", "document-format")
        c.kw("which-jobs-supported", "completed", "not-completed", "all")
        c.bool("job-ids-supported", true)
        // Whole documents are stored, so any page range is trivially "honoured".
        c.bool("page-ranges-supported", true)
        // ipptool's ipp-everywhere.test expects "document-number" (as CUPS ippeveprinter sends);
        // PWG 5100.6 spells the member "document-numbers" - advertise both.
        c.kw("overrides-supported", "document-number", "document-numbers", "pages")
        c.kw("job-creation-attributes-supported",
             "copies", "document-format", "job-name", "media", "media-col", "orientation-requested",
             "print-color-mode", "print-quality", "printer-resolution", "sides")
        c.kw("printer-settable-attributes-supported", "none")
        c.kw("identify-actions-default", "display")
        c.kw("identify-actions-supported", "display", "sound")

        // --- raster formats (compatibility mode only)
        if config.compatibilityMode {
            c.add("pwg-raster-document-resolution-supported", [res300, res600])
            c.kw("pwg-raster-document-type-supported", "black_1", "sgray_8", "srgb_8")
            c.kw("pwg-raster-document-sheet-back", "normal")
            c.add("urf-supported", urfSupported.map { .keyword($0) })
        }

        // --- job template
        c.ints("copies-default", 1)
        c.enums("finishings-default", 3)
        c.enums("finishings-supported", 3)
        c.kw("print-content-optimize-default", "auto")
        c.kw("print-content-optimize-supported", "auto", "photo", "graphic", "text", "text-and-graphic")
        c.kw("print-rendering-intent-default", "auto")
        c.kw("print-rendering-intent-supported", "auto", "perceptual", "relative", "saturation", "absolute", "relative-bpc")
        c.add("copies-supported", .range(low: 1, high: 1))
        c.bool("color-supported", true)
        c.kw("print-color-mode-default", "color")
        c.kw("print-color-mode-supported", "color", "monochrome", "auto")
        c.kw("sides-default", "one-sided")
        c.kw("sides-supported", "one-sided")
        c.enums("orientation-requested-default", 3)
        c.enums("orientation-requested-supported", 3, 4)
        c.enums("print-quality-default", 4)
        c.enums("print-quality-supported", 3, 4, 5)
        c.add("printer-resolution-default", res300)
        c.add("printer-resolution-supported", [res300, res600])
        c.kw("output-bin-default", "face-up")
        c.kw("output-bin-supported", "face-up")

        c.kw("media-default", media[0].keyword)
        c.add("media-supported", media.map { .keyword($0.keyword) })
        c.add("media-ready", mediaReady.map { .keyword($0) })
        c.kw("media-source-default", "auto")
        c.kw("media-source-supported", "auto", "main")
        c.kw("media-type-default", "stationery")
        c.kw("media-type-supported", "stationery", "photographic")
        c.add("media-col-default", mediaCol(media[0]))
        c.add("media-col-ready", media.filter { mediaReady.contains($0.keyword) }.map(mediaCol))
        c.kw("media-col-supported",
             "media-size", "media-top-margin", "media-bottom-margin", "media-left-margin",
             "media-right-margin", "media-source", "media-type")
        c.add("media-size-supported", media.map(mediaSize))
        for side in ["top", "bottom", "left", "right"] { c.ints("media-\(side)-margin-supported", 0, margin) }
        c.add(mediaColDatabase, media.map(mediaCol))
        return c.list
    }

    private static func mediaSize(_ m: Media) -> IppValue {
        .collection([
            IppAttribute("x-dimension", .integer(m.x)),
            IppAttribute("y-dimension", .integer(m.y)),
        ])
    }

    private static func mediaCol(_ m: Media) -> IppValue {
        .collection([
            IppAttribute("media-size", mediaSize(m)),
            IppAttribute("media-top-margin", .integer(margin)),
            IppAttribute("media-bottom-margin", .integer(margin)),
            IppAttribute("media-left-margin", .integer(margin)),
            IppAttribute("media-right-margin", .integer(margin)),
            IppAttribute("media-source", .keyword("auto")),
            IppAttribute("media-type", .keyword("stationery")),
        ])
    }

    /// "ipp://host:port/ipp/print" -> "http://host:port" (ipps -> https). Raw authority is kept (IPv6 literals included).
    static func httpBase(printerUri: String, fallbackPort: UInt16) -> String {
        guard let sep = printerUri.range(of: "://") else { return "http://localhost:\(fallbackPort)" }
        let scheme = printerUri[..<sep.lowerBound].lowercased() == "ipps" ? "https" : "http"
        let rest = printerUri[sep.upperBound...]
        let authority = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        return "\(scheme)://\(authority.isEmpty ? "localhost:\(fallbackPort)" : String(authority))"
    }

    /// RFC 2579 DateAndTime (11 bytes), UTC.
    static func dateTime(_ date: Date) -> IppValue {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let year = c.year ?? 1970
        let deci = UInt8(clamping: (c.nanosecond ?? 0) / 100_000_000)
        return .dateTime(Data([
            UInt8((year >> 8) & 0xFF), UInt8(year & 0xFF),
            UInt8(c.month ?? 1), UInt8(c.day ?? 1),
            UInt8(c.hour ?? 0), UInt8(c.minute ?? 0), UInt8(c.second ?? 0),
            min(deci, 9),
            UInt8(ascii: "+"), 0, 0,
        ]))
    }

    private struct Catalogue {
        var list: [IppAttribute] = []
        mutating func add(_ name: String, _ values: [IppValue]) { list.append(IppAttribute(name, values)) }
        mutating func add(_ name: String, _ value: IppValue) { add(name, [value]) }
        mutating func kw(_ name: String, _ v: String...) { add(name, v.map { .keyword($0) }) }
        mutating func text(_ name: String, _ v: String) { add(name, .text(v)) }
        mutating func bool(_ name: String, _ v: Bool) { add(name, .bool(v)) }
        mutating func ints(_ name: String, _ v: Int32...) { add(name, v.map { .integer($0) }) }
        mutating func enums(_ name: String, _ v: Int32...) { add(name, v.map { .enumValue($0) }) }
    }
}
