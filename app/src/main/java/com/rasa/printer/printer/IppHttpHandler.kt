package com.rasa.printer.printer

import com.rasa.printer.http.HttpHandler
import com.rasa.printer.http.HttpRequest
import com.rasa.printer.http.HttpResponse

/**
 * HTTP adapter for [IppPrinterHandler]. FROZEN INTERFACE.
 *
 * - POST with Content-Type application/ipp → decode, handle, encode (200, application/ipp)
 * - GET "/" → small HTML status page (printer name, job count)
 * - GET "/icon.png" → [iconPng] bytes as image/png (404 if null)
 * - anything else → 404 / 400 / 415 as appropriate
 *
 * printerUri passed to the handler = "ipp://" + Host header + PrinterConfig.RESOURCE_PATH
 * (fallback host "localhost:<port>" when Host is absent).
 */
class IppHttpHandler(
    private val handler: IppPrinterHandler,
    private val config: () -> PrinterConfig,
    private val jobs: JobStore,
    private val iconPng: () -> ByteArray?,
) : HttpHandler {
    override fun handle(request: HttpRequest): HttpResponse = TODO("unit C")
}
