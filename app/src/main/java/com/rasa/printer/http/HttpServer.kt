package com.rasa.printer.http

/**
 * Minimal blocking HTTP/1.1 server on a ServerSocket. FROZEN INTERFACE.
 *
 * Requirements: one thread per connection; keep-alive; Content-Length and chunked
 * request bodies; "Expect: 100-continue" (send "HTTP/1.1 100 Continue" before the
 * handler reads the body); responses always carry Content-Length and Connection
 * header; handler exceptions become 500. [port] 0 means ephemeral (see [boundPort]).
 */
class HttpServer(
    private val port: Int,
    private val handler: HttpHandler,
) {
    /** Actual bound port after [start]. */
    val boundPort: Int get() = TODO("unit B")

    /** Binds and starts the accept loop on a background thread. Throws IOException if bind fails. */
    fun start(): Unit = TODO("unit B")

    /** Closes the listening socket and all open connections. Idempotent. */
    fun stop(): Unit = TODO("unit B")
}
