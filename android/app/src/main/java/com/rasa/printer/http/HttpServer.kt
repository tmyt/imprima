package com.rasa.printer.http

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.text.SimpleDateFormat
import java.util.Collections
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.atomic.AtomicInteger
import java.util.logging.Level
import java.util.logging.Logger

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
    @Volatile private var serverSocket: ServerSocket? = null
    @Volatile private var stopped = false
    private val connections: MutableSet<Socket> = Collections.synchronizedSet(HashSet())
    private val connCounter = AtomicInteger()

    /** Actual bound port after [start]. */
    val boundPort: Int get() = serverSocket?.localPort ?: port

    /** Binds and starts the accept loop on a background thread. Throws IOException if bind fails. */
    @Synchronized
    fun start() {
        check(serverSocket == null) { "already started" }
        val ss = ServerSocket()
        try {
            ss.reuseAddress = true
            ss.bind(InetSocketAddress(null as java.net.InetAddress?, port), 50)
        } catch (e: IOException) {
            runCatching { ss.close() }
            throw e
        }
        serverSocket = ss
        stopped = false
        Thread({ acceptLoop(ss) }, "http-accept").apply { isDaemon = true }.start()
    }

    /** Closes the listening socket and all open connections. Idempotent. */
    fun stop() {
        stopped = true
        runCatching { serverSocket?.close() }
        val snapshot = synchronized(connections) { connections.toList() }
        snapshot.forEach { runCatching { it.close() } }
    }

    private fun acceptLoop(ss: ServerSocket) {
        while (!stopped) {
            val s = try {
                ss.accept()
            } catch (e: SocketException) {
                break
            } catch (e: IOException) {
                if (stopped || ss.isClosed) break
                log.log(Level.WARNING, "accept failed", e)
                continue
            }
            connections.add(s)
            if (stopped) {
                runCatching { s.close() }
                connections.remove(s)
                break
            }
            Thread({ serve(s) }, "http-conn-${connCounter.incrementAndGet()}").apply { isDaemon = true }.start()
        }
    }

    private class BadRequest(val status: Int, msg: String) : IOException(msg)

    private fun serve(socket: Socket) {
        try {
            socket.soTimeout = IDLE_TIMEOUT_MS
            socket.tcpNoDelay = true
            val input = BufferedInputStream(socket.getInputStream(), 16 * 1024)
            val output = BufferedOutputStream(socket.getOutputStream(), 16 * 1024)
            var keepAlive = true
            while (keepAlive && !stopped) {
                keepAlive = handleOne(input, output)
            }
        } catch (e: IOException) {
            log.log(Level.FINE, "connection ended: ${e.message}")
        } catch (e: Throwable) {
            log.log(Level.WARNING, "connection error", e)
        } finally {
            connections.remove(socket)
            runCatching { socket.close() }
        }
    }

    /** Handles one request. Returns true if the connection should stay open. */
    private fun handleOne(input: InputStream, output: java.io.OutputStream): Boolean {
        val budget = intArrayOf(MAX_HEADER_BYTES)
        val requestLine: String
        val headers = LinkedHashMap<String, String>()
        try {
            var line = readHeaderLine(input, budget) ?: return false
            // Tolerate stray blank lines between requests.
            while (line.isEmpty()) line = readHeaderLine(input, budget) ?: return false
            requestLine = line
            while (true) {
                val h = readHeaderLine(input, budget) ?: throw IOException("EOF in headers")
                if (h.isEmpty()) break
                val idx = h.indexOf(':')
                if (idx <= 0) throw BadRequest(400, "Malformed header")
                headers[h.substring(0, idx).trim().lowercase(Locale.ROOT)] = h.substring(idx + 1).trim()
            }
        } catch (e: BadRequest) {
            writeResponse(output, HttpResponse.text(e.status, "${reason(e.status)}\n"), false)
            return false
        }

        val parts = requestLine.split(' ').filter { it.isNotEmpty() }
        if (parts.size != 3 || !parts[2].startsWith("HTTP/1.")) {
            writeResponse(output, HttpResponse.text(400, "Bad Request\n"), false)
            return false
        }
        val method = parts[0]
        val version = parts[2]
        var path = parts[1]
        if (path.startsWith("http://") || path.startsWith("https://")) {
            val rest = path.substringAfter("://")
            val slash = rest.indexOf('/')
            path = if (slash >= 0) rest.substring(slash) else "/"
        }
        log.log(Level.FINE) { "$method $path" }

        val connHeader = headers["connection"]?.lowercase(Locale.ROOT).orEmpty()
        var keepAlive = if (version == "HTTP/1.0") connHeader.contains("keep-alive") else !connHeader.contains("close")

        val te = headers["transfer-encoding"]?.lowercase(Locale.ROOT)
        val body: InputStream = when {
            te != null && te.contains("chunked") -> ChunkedInputStream(input)
            headers["content-length"] != null -> {
                val len = headers["content-length"]!!.toLongOrNull()
                if (len == null || len < 0) {
                    writeResponse(output, HttpResponse.text(400, "Bad Request\n"), false)
                    return false
                }
                BoundedInputStream(input, len)
            }
            else -> BoundedInputStream(input, 0)
        }

        if (headers["expect"]?.trim()?.equals("100-continue", ignoreCase = true) == true) {
            output.write("HTTP/1.1 100 Continue\r\n\r\n".toByteArray(Charsets.ISO_8859_1))
            output.flush()
        }

        val response = try {
            handler.handle(HttpRequest(method, path, headers, body))
        } catch (t: Throwable) {
            log.log(Level.WARNING, "handler failed for $method $path", t)
            keepAlive = false
            HttpResponse.text(500, "Internal Server Error\n")
        }

        if (keepAlive) {
            try {
                drain(body)
            } catch (e: IOException) {
                keepAlive = false
            }
        }
        writeResponse(output, response, keepAlive)
        return keepAlive
    }

    private fun drain(body: InputStream) {
        val buf = ByteArray(8192)
        while (body.read(buf) >= 0) { /* discard */ }
    }

    /** Reads a CRLF/LF-terminated line. Returns null on clean EOF before any byte. */
    private fun readHeaderLine(input: InputStream, budget: IntArray): String? {
        val sb = StringBuilder()
        while (true) {
            val c = input.read()
            if (c < 0) {
                if (sb.isEmpty()) return null
                throw IOException("EOF in line")
            }
            if (--budget[0] < 0) throw BadRequest(431, "Header block too large")
            if (c == '\n'.code) break
            if (c != '\r'.code) sb.append(c.toChar())
        }
        return sb.toString()
    }

    private fun writeResponse(output: java.io.OutputStream, r: HttpResponse, keepAlive: Boolean) {
        val sb = StringBuilder()
        sb.append("HTTP/1.1 ").append(r.status).append(' ').append(reason(r.status)).append("\r\n")
        sb.append("Content-Type: ").append(r.contentType).append("\r\n")
        sb.append("Content-Length: ").append(r.body.size).append("\r\n")
        sb.append("Connection: ").append(if (keepAlive) "keep-alive" else "close").append("\r\n")
        sb.append("Date: ").append(httpDate()).append("\r\n")
        sb.append("Server: RasaPrinter/0.1\r\n")
        for ((k, v) in r.headers) sb.append(k).append(": ").append(v).append("\r\n")
        sb.append("\r\n")
        output.write(sb.toString().toByteArray(Charsets.ISO_8859_1))
        output.write(r.body)
        output.flush()
    }

    private fun httpDate(): String {
        val f = SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss 'GMT'", Locale.US)
        f.timeZone = TimeZone.getTimeZone("GMT")
        return f.format(Date())
    }

    private fun reason(status: Int): String = when (status) {
        100 -> "Continue"
        200 -> "OK"
        201 -> "Created"
        204 -> "No Content"
        301 -> "Moved Permanently"
        302 -> "Found"
        304 -> "Not Modified"
        400 -> "Bad Request"
        401 -> "Unauthorized"
        403 -> "Forbidden"
        404 -> "Not Found"
        405 -> "Method Not Allowed"
        408 -> "Request Timeout"
        411 -> "Length Required"
        413 -> "Payload Too Large"
        415 -> "Unsupported Media Type"
        431 -> "Request Header Fields Too Large"
        500 -> "Internal Server Error"
        501 -> "Not Implemented"
        503 -> "Service Unavailable"
        else -> "Status"
    }

    private companion object {
        val log: Logger = Logger.getLogger("HttpServer")
        const val IDLE_TIMEOUT_MS = 60_000
        const val MAX_HEADER_BYTES = 64 * 1024
    }
}
