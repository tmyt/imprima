package com.rasa.printer.http

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.ConnectException
import java.net.InetAddress
import java.net.Socket
import java.util.Random
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

class HttpServerTest {
    private class Resp(val status: Int, val headers: Map<String, String>, val body: ByteArray)

    private lateinit var server: HttpServer
    @Volatile private var lastRequest: HttpRequest? = null
    @Volatile private var lastBody: ByteArray = ByteArray(0)
    @Volatile private var handlerImpl: (HttpRequest) -> HttpResponse = { HttpResponse.text(200, "hi") }

    @Before fun setUp() {
        server = HttpServer(0) { req ->
            lastRequest = req
            handlerImpl(req)
        }
        server.start()
    }

    @After fun tearDown() { server.stop() }

    private fun connect() = Socket(InetAddress.getLoopbackAddress(), server.boundPort).also { it.soTimeout = 10_000 }

    private fun readLine(i: InputStream): String {
        val sb = StringBuilder()
        while (true) {
            val c = i.read()
            if (c < 0) break
            if (c == '\n'.code) break
            if (c != '\r'.code) sb.append(c.toChar())
        }
        return sb.toString()
    }

    private fun readResponse(i: InputStream): Resp {
        val status = readLine(i).split(' ')[1].toInt()
        val h = HashMap<String, String>()
        while (true) {
            val l = readLine(i)
            if (l.isEmpty()) break
            h[l.substringBefore(':').lowercase()] = l.substringAfter(':').trim()
        }
        val len = h["content-length"]!!.toInt()
        val b = ByteArray(len)
        var off = 0
        while (off < len) {
            val n = i.read(b, off, len - off)
            if (n < 0) break
            off += n
        }
        return Resp(status, h, b)
    }

    private fun send(s: Socket, text: String) = send(s, text.toByteArray(Charsets.ISO_8859_1))
    private fun send(s: Socket, b: ByteArray) { s.getOutputStream().write(b); s.getOutputStream().flush() }

    @Test fun getNoBody() {
        handlerImpl = { HttpResponse.text(200, "hello") }
        connect().use { s ->
            send(s, "GET /a/b?x=1 HTTP/1.1\r\nHost: Example\r\nX-Custom-Header:  Val \r\n\r\n")
            val r = readResponse(s.getInputStream())
            assertEquals(200, r.status)
            assertEquals("5", r.headers["content-length"])
            assertEquals("hello", String(r.body))
            assertEquals("keep-alive", r.headers["connection"])
        }
        val req = lastRequest!!
        assertEquals("GET", req.method)
        assertEquals("/a/b?x=1", req.path)
        assertEquals("Example", req.headers["host"])
        assertEquals("Val", req.headers["x-custom-header"])
    }

    @Test fun postContentLength() {
        val data = ByteArray(100 * 1024).also { Random(1).nextBytes(it) }
        handlerImpl = { req -> lastBody = req.body.readBytes(); HttpResponse(200) }
        connect().use { s ->
            send(s, "POST /ipp HTTP/1.1\r\nContent-Type: application/ipp\r\nContent-Length: ${data.size}\r\n\r\n")
            send(s, data)
            assertEquals(200, readResponse(s.getInputStream()).status)
        }
        assertArrayEquals(data, lastBody)
    }

    @Test fun postChunked() {
        handlerImpl = { req -> lastBody = req.body.readBytes(); HttpResponse(200) }
        connect().use { s ->
            send(s, "POST /ipp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" +
                "5\r\nhello\r\n6;foo=bar\r\n world\r\nA\r\n0123456789\r\n0\r\nTrailer: x\r\n\r\n")
            assertEquals(200, readResponse(s.getInputStream()).status)
        }
        assertEquals("hello world0123456789", String(lastBody))
    }

    @Test fun expectContinue() {
        handlerImpl = { req -> lastBody = req.body.readBytes(); HttpResponse(200) }
        connect().use { s ->
            send(s, "POST /ipp HTTP/1.1\r\nExpect: 100-Continue\r\nContent-Length: 4\r\n\r\n")
            val i = s.getInputStream()
            assertEquals("HTTP/1.1 100 Continue", readLine(i))
            assertEquals("", readLine(i))
            send(s, "abcd")
            assertEquals(200, readResponse(i).status)
        }
        assertEquals("abcd", String(lastBody))
    }

    @Test fun keepAliveDrainsUnreadBody() {
        handlerImpl = { req -> if (req.method == "POST") HttpResponse.text(200, "first") else HttpResponse.text(200, "second") }
        connect().use { s ->
            val i = s.getInputStream()
            send(s, "POST /x HTTP/1.1\r\nContent-Length: 10\r\n\r\n0123456789")
            assertEquals("first", String(readResponse(i).body))
            send(s, "GET /y HTTP/1.1\r\n\r\n")
            assertEquals("second", String(readResponse(i).body))
        }
    }

    @Test fun handlerThrows500() {
        handlerImpl = { throw IllegalStateException("boom") }
        connect().use { s ->
            send(s, "GET / HTTP/1.1\r\n\r\n")
            val r = readResponse(s.getInputStream())
            assertEquals(500, r.status)
            assertEquals("close", r.headers["connection"])
        }
    }

    @Test fun malformedRequestLine400() {
        connect().use { s ->
            send(s, "garbage\r\n\r\n")
            assertEquals(400, readResponse(s.getInputStream()).status)
        }
    }

    @Test fun stopClosesListenerAndConnections() {
        val idle = connect()
        Thread.sleep(100)
        val start = System.nanoTime()
        server.stop()
        server.stop()
        assertTrue("stop too slow", (System.nanoTime() - start) / 1_000_000 < 2000)
        try {
            Socket(InetAddress.getLoopbackAddress(), server.boundPort).close()
            fail("connect should fail")
        } catch (e: ConnectException) {
            // expected
        }
        assertEquals(-1, idle.getInputStream().read())
        idle.close()
    }
}
