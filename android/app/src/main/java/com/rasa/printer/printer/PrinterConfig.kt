package com.rasa.printer.printer

/** User-editable printer settings. FROZEN INTERFACE. */
data class PrinterConfig(
    val name: String,
    /** Non-privileged TCP port (never 631; the app runs without root). */
    val port: Int = DEFAULT_PORT,
    /** Stable UUID string (without "urn:uuid:" prefix). */
    val uuid: String,
    val location: String = "",
    val makeAndModel: String = "Rasa Virtual Printer",
    /**
     * false (default): PDF-only mode - only application/pdf documents are accepted; the printer does
     * not advertise URF/PWG raster (so iOS AirPrint does not list it and macOS/CUPS send PDF).
     * true: high-compatibility mode - additionally accepts image/urf, image/pwg-raster, image/jpeg,
     * image/png (raster is converted to PDF) and advertises AirPrint (URF, _universal subtype).
     */
    val compatibilityMode: Boolean = false,
) {
    companion object {
        const val DEFAULT_PORT = 8631
        const val RESOURCE_PATH = "/ipp/print"
    }
}
