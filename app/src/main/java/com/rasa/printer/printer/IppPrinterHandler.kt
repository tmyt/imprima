package com.rasa.printer.printer

import com.rasa.printer.ipp.IppMessage
import java.io.InputStream

/**
 * IPP Everywhere operation handler, transport-agnostic. FROZEN INTERFACE.
 *
 * @param config current printer configuration (read on every request)
 * @param jobs job persistence
 * @param clock epoch millis provider (injectable for tests)
 */
class IppPrinterHandler(
    private val config: () -> PrinterConfig,
    private val jobs: JobStore,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    /**
     * @param request decoded IPP request
     * @param document document bytes following the attributes (may be empty); read to EOF for
     *                 Print-Job / Send-Document, ignored otherwise
     * @param printerUri the URI this printer is reachable at for this client,
     *                   e.g. "ipp://192.168.1.5:8631/ipp/print" (derived from the HTTP Host header)
     * @return IPP response (never throws for protocol errors; maps them to status codes)
     */
    fun handle(request: IppMessage, document: InputStream, printerUri: String): IppMessage = TODO("unit C")
}
