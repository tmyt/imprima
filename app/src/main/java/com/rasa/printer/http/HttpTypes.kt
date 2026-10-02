package com.rasa.printer.http

import java.io.InputStream

/**
 * Minimal HTTP model. FROZEN INTERFACE.
 *
 * @param headers header names lower-cased; last value wins for duplicates.
 * @param body the entity body: already de-chunked if Transfer-Encoding: chunked,
 *             bounded to Content-Length otherwise; empty stream when no body.
 *             The server drains whatever the handler leaves unread.
 */
class HttpRequest(
    val method: String,
    val path: String,
    val headers: Map<String, String>,
    val body: InputStream,
) {
    val contentType: String? get() = headers["content-type"]
    val host: String? get() = headers["host"]
}

class HttpResponse(
    val status: Int,
    val body: ByteArray = ByteArray(0),
    val contentType: String = "application/octet-stream",
    val headers: Map<String, String> = emptyMap(),
) {
    companion object {
        fun text(status: Int, text: String, contentType: String = "text/plain; charset=utf-8") =
            HttpResponse(status, text.toByteArray(Charsets.UTF_8), contentType)
    }
}

fun interface HttpHandler {
    fun handle(request: HttpRequest): HttpResponse
}
