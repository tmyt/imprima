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
) {
    companion object {
        const val DEFAULT_PORT = 8631
        const val RESOURCE_PATH = "/ipp/print"
    }
}
