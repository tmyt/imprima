package com.rasa.printer.printer

import com.rasa.printer.http.HttpHandler
import com.rasa.printer.http.HttpRequest
import com.rasa.printer.http.HttpResponse
import com.rasa.printer.ipp.IppCodec
import com.rasa.printer.ipp.IppMessage
import java.util.logging.Level
import java.util.logging.Logger

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
    override fun handle(request: HttpRequest): HttpResponse {
        val path = request.path.substringBefore('?')
        return when (request.method.uppercase()) {
            "POST" -> handlePost(request)
            "GET" -> when (path) {
                "/" -> HttpResponse.text(200, statusPage(), "text/html; charset=utf-8")
                "/icon.png" -> iconPng()?.let { HttpResponse(200, it, "image/png") }
                    ?: HttpResponse.text(404, "Not found")
                else -> HttpResponse.text(404, "Not found")
            }
            else -> HttpResponse(405, "Method not allowed".toByteArray(), "text/plain; charset=utf-8", mapOf("Allow" to "GET, POST"))
        }
    }

    private fun handlePost(request: HttpRequest): HttpResponse {
        val type = request.contentType?.substringBefore(';')?.trim()?.lowercase()
        if (type != "application/ipp") return HttpResponse.text(415, "Unsupported media type: expected application/ipp")
        val message: IppMessage = try {
            IppCodec.decode(request.body)
        } catch (e: Exception) {
            log.log(Level.INFO, "Malformed IPP request", e)
            return HttpResponse.text(400, "Bad IPP request: ${e.message}")
        }
        val host = request.host?.trim()?.takeIf { it.isNotEmpty() } ?: "localhost:${config().port}"
        val printerUri = "ipp://$host${PrinterConfig.RESOURCE_PATH}"
        val response = handler.handle(message, request.body, printerUri)
        return HttpResponse(200, IppCodec.encode(response), "application/ipp")
    }

    private fun statusPage(): String {
        val cfg = config()
        val list = jobs.list()
        val rows = list.take(MAX_LISTED).joinToString("\n") { j ->
            "<tr><td>${j.id}</td><td>${esc(j.name)}</td><td>${esc(j.userName)}</td><td>${esc(j.format)}</td>" +
                "<td>${j.state.name.lowercase()}</td><td>${j.sizeBytes}</td></tr>"
        }
        return """
            |<!DOCTYPE html>
            |<html><head><meta charset="utf-8"><title>${esc(cfg.name)}</title></head>
            |<body>
            |<h1>${esc(cfg.name)}</h1>
            |<p>${esc(cfg.makeAndModel)}${if (cfg.location.isNotEmpty()) " &middot; " + esc(cfg.location) else ""}</p>
            |<p>UUID: ${esc(cfg.uuid)}<br>Port: ${cfg.port}<br>IPP path: ${PrinterConfig.RESOURCE_PATH}<br>Mode: ${if (cfg.compatibilityMode) "Compatibility (PDF, URF, PWG raster, JPEG, PNG)" else "PDF-only"}<br>Jobs: ${list.size}</p>
            |<table border="1" cellpadding="4">
            |<tr><th>ID</th><th>Name</th><th>User</th><th>Format</th><th>State</th><th>Bytes</th></tr>
            |$rows
            |</table>
            |</body></html>
            |""".trimMargin()
    }

    private fun esc(s: String): String = buildString(s.length) {
        for (c in s) when (c) {
            '<' -> append("&lt;"); '>' -> append("&gt;"); '&' -> append("&amp;")
            '"' -> append("&quot;"); '\'' -> append("&#39;")
            else -> append(c)
        }
    }

    private companion object {
        val log: Logger = Logger.getLogger(IppHttpHandler::class.java.name)
        const val MAX_LISTED = 20
    }
}
