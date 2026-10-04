package com.rasa.printer.printer

import com.rasa.printer.ipp.IppAttribute
import com.rasa.printer.ipp.IppOperation
import com.rasa.printer.ipp.IppTag
import com.rasa.printer.ipp.IppValue
import java.net.URI
import java.util.Calendar
import java.util.TimeZone

/**
 * Printer attribute catalogue for an IPP Everywhere (PWG 5100.14) / AirPrint virtual printer.
 * Every attribute name appears at most once; group membership is derived from the name.
 */
object PrinterAttributes {
    const val MEDIA_COL_DATABASE = "media-col-database"

    /** Cancel-My-Jobs (PWG 5100.11); not among the frozen IppOperation constants. */
    const val CANCEL_MY_JOBS = 0x0039

    const val PDF = "application/pdf"
    const val OCTET_STREAM = "application/octet-stream"

    /** Every format the compatibility mode accepts (octet-stream = "sniff it"). */
    val DOCUMENT_FORMATS_ALL: List<String> = listOf(PDF, "image/pwg-raster", "image/urf", "image/jpeg", "image/png", OCTET_STREAM)

    /** PDF-only mode: octet-stream is only a transport type whose content must sniff to PDF. */
    val DOCUMENT_FORMATS_PDF_ONLY: List<String> = listOf(PDF, OCTET_STREAM)

    /** Document formats accepted by Print-Job / Send-Document / Validate-Job for [config]. */
    fun documentFormats(config: PrinterConfig): List<String> =
        if (config.compatibilityMode) DOCUMENT_FORMATS_ALL else DOCUMENT_FORMATS_PDF_ONLY

    private val URF_SUPPORTED = listOf("V1.4", "W8", "SRGB24", "CP1", "RS300-600", "IS1", "MT1-2-3", "OB9", "PQ3-4-5", "DM1")

    /** DNS-SD TXT record for _ipp._tcp (Bonjour Printing Specification / IPP Everywhere). */
    fun bonjourTxt(config: PrinterConfig): Map<String, String> = buildMap {
        put("txtvers", "1")
        put("qtotal", "1")
        put("rp", PrinterConfig.RESOURCE_PATH.removePrefix("/"))
        put("ty", config.name)
        put("product", "(${config.makeAndModel})")
        put("pdl", documentFormats(config).filter { it != OCTET_STREAM }.joinToString(","))
        if (config.compatibilityMode) put("URF", URF_SUPPORTED.joinToString(","))
        put("Color", "T")
        put("Duplex", "F")
        put("Scan", "F")
        put("Fax", "F")
        put("kind", "document")
        put("UUID", config.uuid)
        put("priority", "0")
        if (config.location.isNotEmpty()) put("note", config.location)
    }

    val OPERATIONS: List<Int> = listOf(
        IppOperation.PRINT_JOB, IppOperation.VALIDATE_JOB, IppOperation.CREATE_JOB, IppOperation.SEND_DOCUMENT,
        IppOperation.CANCEL_JOB, IppOperation.GET_JOB_ATTRIBUTES, IppOperation.GET_JOBS,
        IppOperation.GET_PRINTER_ATTRIBUTES, CANCEL_MY_JOBS, IppOperation.CLOSE_JOB, IppOperation.IDENTIFY_PRINTER,
    )

    private const val MARGIN = 423

    private class Media(val keyword: String, val x: Int, val y: Int)

    /** Sizes in hundredths of a millimetre (PWG 5101.1). */
    private val MEDIA = listOf(
        Media("iso_a4_210x297mm", 21000, 29700),
        Media("na_letter_8.5x11in", 21590, 27940),
        Media("na_legal_8.5x14in", 21590, 35560),
        Media("iso_a5_148x210mm", 14800, 21000),
        Media("na_index-4x6_4x6in", 10160, 15240),
    )
    private val MEDIA_READY = listOf("iso_a4_210x297mm", "na_letter_8.5x11in")

    private val TEMPLATE_BASES = setOf(
        "copies", "media", "media-col", "media-source", "media-type", "orientation-requested",
        "print-color-mode", "print-quality", "printer-resolution", "sides", "output-bin", "finishings",
        "page-ranges", "print-content-optimize", "print-rendering-intent", "overrides",
    )
    private val TEMPLATE_EXTRA = setOf(
        "media-size-supported", "media-top-margin-supported", "media-bottom-margin-supported",
        "media-left-margin-supported", "media-right-margin-supported",
    )

    /** Names of attributes belonging to the "job-template" group keyword. */
    val JOB_TEMPLATE_NAMES: Set<String> by lazy { allNames().filter(::isJobTemplate).toSet() }

    /** Names belonging to "printer-description" (everything else except media-col-database). */
    val DESCRIPTION_NAMES: Set<String> by lazy {
        allNames().filter { !isJobTemplate(it) && it != MEDIA_COL_DATABASE }.toSet()
    }

    private fun isJobTemplate(name: String): Boolean {
        if (name in TEMPLATE_EXTRA) return true
        val base = name.substringBeforeLast('-')
        val suffix = name.substringAfterLast('-')
        return base in TEMPLATE_BASES && suffix in setOf("default", "supported", "ready")
    }

    /** Superset of names (compatibility mode advertises everything PDF-only mode does, plus raster). */
    private fun allNames(): List<String> =
        build(PrinterConfig(name = "x", uuid = "x", compatibilityMode = true), "ipp://localhost:${PrinterConfig.DEFAULT_PORT}${PrinterConfig.RESOURCE_PATH}", 0, 1, 0L, 0L)
            .map { it.name }

    fun build(
        config: PrinterConfig,
        printerUri: String,
        queuedJobCount: Int,
        upTimeSeconds: Int,
        nowMillis: Long,
        /** When config / state last changed (epoch millis); *-change-time uses printer-up-time's epoch-seconds scale. */
        changeMillis: Long = nowMillis,
    ): List<IppAttribute> {
        val changeSeconds = maxOf(0L, changeMillis / 1000).toInt()
        val httpBase = httpBase(printerUri, config.port)
        val compat = config.compatibilityMode
        return Catalogue().apply {
            // --- charset / language / protocol
            add("charset-configured", IppValue.Charset("utf-8"))
            add("charset-supported", IppValue.Charset("utf-8"))
            add("natural-language-configured", IppValue.NaturalLanguage("en"))
            add("generated-natural-language-supported", IppValue.NaturalLanguage("en"))
            kw("ipp-versions-supported", "1.1", "2.0")
            kw("ipp-features-supported", "ipp-everywhere")
            enums("operations-supported", *OPERATIONS.toIntArray())
            add("printer-uri-supported", IppValue.Uri(printerUri))
            kw("uri-security-supported", "none")
            kw("uri-authentication-supported", "none")

            // --- identity
            add("printer-name", IppValue.Name(config.name))
            text("printer-info", config.name)
            text("printer-location", config.location)
            text("printer-make-and-model", config.makeAndModel)
            add("printer-uuid", IppValue.Uri("urn:uuid:" + config.uuid))
            text("printer-device-id", "MFG:Rasa;MDL:Virtual Printer;CMD:${if (compat) "PDF,PWGRaster,URF" else "PDF"};CLS:PRINTER;")
            add("printer-more-info", IppValue.Uri("$httpBase/"))
            add("printer-icons", IppValue.Uri("$httpBase/icon.png"))
            add("printer-geo-location", IppValue.OutOfBand(IppTag.UNKNOWN))
            text("printer-organization", "")
            text("printer-organizational-unit", "")
            kw("printer-kind", "document")

            // --- state
            enums("printer-state", 3)
            kw("printer-state-reasons", "none")
            text("printer-state-message", "Idle")
            bool("printer-is-accepting-jobs", true)
            ints("queued-job-count", queuedJobCount)
            ints("printer-up-time", upTimeSeconds)
            add("printer-current-time", dateTime(nowMillis))
            add("printer-config-change-date-time", dateTime(changeMillis))
            ints("printer-config-change-time", changeSeconds)
            add("printer-state-change-date-time", dateTime(changeMillis))
            ints("printer-state-change-time", changeSeconds)
            add("printer-supply", IppValue.OctetString("type=toner;maxcapacity=100;level=100;colorantname=black;".toByteArray(Charsets.US_ASCII)))
            text("printer-supply-description", "Virtual toner")
            add("printer-supply-info-uri", IppValue.Uri("$httpBase/"))
            ints("pages-per-minute", 10)
            ints("pages-per-minute-color", 10)

            // --- document handling
            add("document-format-default", IppValue.MimeMediaType(PDF))
            add("document-format-supported", documentFormats(config).map { IppValue.MimeMediaType(it) })
            kw("compression-supported", "none")
            kw("pdl-override-supported", "attempted")
            bool("multiple-document-jobs-supported", false)
            ints("multiple-operation-time-out", 120)
            kw("multiple-operation-time-out-action", "abort-job")
            bool("preferred-attributes-supported", false)
            kw("printer-get-attributes-supported", "document-format")
            kw("which-jobs-supported", "completed", "not-completed", "all")
            bool("job-ids-supported", true)
            // Whole documents are stored, so any page range is trivially "honoured".
            bool("page-ranges-supported", true)
            // ipptool's ipp-everywhere.test expects "document-number" (as CUPS ippeveprinter sends);
            // PWG 5100.6 spells the member "document-numbers" - advertise both.
            kw("overrides-supported", "document-number", "document-numbers", "pages")
            kw(
                "job-creation-attributes-supported",
                "copies", "document-format", "job-name", "media", "media-col", "orientation-requested",
                "print-color-mode", "print-quality", "printer-resolution", "sides",
            )
            kw("printer-settable-attributes-supported", "none")
            kw("identify-actions-default", "display")
            kw("identify-actions-supported", "display", "sound")

            // --- raster formats (compatibility mode only; their absence keeps iOS from listing a PDF-only printer)
            if (compat) {
                add("pwg-raster-document-resolution-supported", RES_300, RES_600)
                kw("pwg-raster-document-type-supported", "black_1", "sgray_8", "srgb_8")
                kw("pwg-raster-document-sheet-back", "normal")
                kw("urf-supported", *URF_SUPPORTED.toTypedArray())
            }

            // --- job template
            ints("copies-default", 1)
            enums("finishings-default", 3)
            enums("finishings-supported", 3)
            kw("print-content-optimize-default", "auto")
            kw("print-content-optimize-supported", "auto", "photo", "graphic", "text", "text-and-graphic")
            kw("print-rendering-intent-default", "auto")
            kw("print-rendering-intent-supported", "auto", "perceptual", "relative", "saturation", "absolute", "relative-bpc")
            add("copies-supported", IppValue.Range(1, 1))
            bool("color-supported", true)
            kw("print-color-mode-default", "color")
            kw("print-color-mode-supported", "color", "monochrome", "auto")
            kw("sides-default", "one-sided")
            kw("sides-supported", "one-sided")
            enums("orientation-requested-default", 3)
            enums("orientation-requested-supported", 3, 4)
            enums("print-quality-default", 4)
            enums("print-quality-supported", 3, 4, 5)
            add("printer-resolution-default", RES_300)
            add("printer-resolution-supported", RES_300, RES_600)
            kw("output-bin-default", "face-up")
            kw("output-bin-supported", "face-up")

            kw("media-default", MEDIA.first().keyword)
            kw("media-supported", *MEDIA.map { it.keyword }.toTypedArray())
            kw("media-ready", *MEDIA_READY.toTypedArray())
            kw("media-source-default", "auto")
            kw("media-source-supported", "auto", "main")
            kw("media-type-default", "stationery")
            kw("media-type-supported", "stationery", "photographic")
            add("media-col-default", mediaCol(MEDIA.first()))
            add("media-col-ready", MEDIA.filter { it.keyword in MEDIA_READY }.map(::mediaCol))
            kw(
                "media-col-supported",
                "media-size", "media-top-margin", "media-bottom-margin", "media-left-margin",
                "media-right-margin", "media-source", "media-type",
            )
            add("media-size-supported", MEDIA.map { mediaSize(it) })
            for (side in listOf("top", "bottom", "left", "right")) ints("media-$side-margin-supported", 0, MARGIN)
            add(MEDIA_COL_DATABASE, MEDIA.map(::mediaCol))
        }.list
    }

    private val RES_300 = IppValue.Resolution(300, 300, 3)
    private val RES_600 = IppValue.Resolution(600, 600, 3)

    private fun mediaSize(m: Media) = IppValue.Collection(
        listOf(
            IppAttribute("x-dimension", IppValue.Integer(m.x)),
            IppAttribute("y-dimension", IppValue.Integer(m.y)),
        ),
    )

    private fun mediaCol(m: Media) = IppValue.Collection(
        listOf(
            IppAttribute("media-size", mediaSize(m)),
            IppAttribute("media-top-margin", IppValue.Integer(MARGIN)),
            IppAttribute("media-bottom-margin", IppValue.Integer(MARGIN)),
            IppAttribute("media-left-margin", IppValue.Integer(MARGIN)),
            IppAttribute("media-right-margin", IppValue.Integer(MARGIN)),
            IppAttribute("media-source", IppValue.Keyword("auto")),
            IppAttribute("media-type", IppValue.Keyword("stationery")),
        ),
    )

    /** "ipp://host:port/ipp/print" -> "http://host:port" (ipps -> https). */
    internal fun httpBase(printerUri: String, fallbackPort: Int): String = try {
        val uri = URI(printerUri)
        val scheme = if (uri.scheme.equals("ipps", ignoreCase = true)) "https" else "http"
        val authority = uri.rawAuthority ?: "localhost:$fallbackPort"
        "$scheme://$authority"
    } catch (e: Exception) {
        "http://localhost:$fallbackPort"
    }

    /** RFC 2579 DateAndTime (11 bytes), UTC. */
    fun dateTime(millis: Long): IppValue.DateTime {
        val c = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply { timeInMillis = millis }
        val year = c.get(Calendar.YEAR)
        return IppValue.DateTime(
            byteArrayOf(
                (year shr 8).toByte(), year.toByte(),
                (c.get(Calendar.MONTH) + 1).toByte(), c.get(Calendar.DAY_OF_MONTH).toByte(),
                c.get(Calendar.HOUR_OF_DAY).toByte(), c.get(Calendar.MINUTE).toByte(), c.get(Calendar.SECOND).toByte(),
                (c.get(Calendar.MILLISECOND) / 100).toByte(),
                '+'.code.toByte(), 0, 0,
            ),
        )
    }

    private class Catalogue {
        val list = mutableListOf<IppAttribute>()
        fun add(name: String, values: List<IppValue>) { list += IppAttribute(name, values) }
        fun add(name: String, vararg values: IppValue) = add(name, values.toList())
        fun kw(name: String, vararg v: String) = add(name, v.map { IppValue.Keyword(it) })
        fun text(name: String, v: String) = add(name, IppValue.Text(v))
        fun bool(name: String, v: Boolean) = add(name, IppValue.Bool(v))
        fun ints(name: String, vararg v: Int) = add(name, v.map { IppValue.Integer(it) })
        fun enums(name: String, vararg v: Int) = add(name, v.map { IppValue.Enum(it) })
    }
}
