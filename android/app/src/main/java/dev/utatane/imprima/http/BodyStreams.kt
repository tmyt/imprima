package dev.utatane.imprima.http

import java.io.EOFException
import java.io.IOException
import java.io.InputStream

/** Reads exactly [limit] bytes from [src]; never reads past the limit. Does not close [src]. */
internal class BoundedInputStream(private val src: InputStream, limit: Long) : InputStream() {
    private var remaining = limit

    override fun read(): Int {
        if (remaining <= 0) return -1
        val b = src.read()
        if (b < 0) throw EOFException("Unexpected end of body")
        remaining--
        return b
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (len == 0) return 0
        if (remaining <= 0) return -1
        val n = src.read(b, off, minOf(len.toLong(), remaining).toInt())
        if (n < 0) throw EOFException("Unexpected end of body")
        remaining -= n
        return n
    }

    override fun available(): Int = minOf(src.available().toLong(), remaining).toInt()
}

/** De-chunks a Transfer-Encoding: chunked body. Consumes trailers at the end. Does not close [src]. */
internal class ChunkedInputStream(private val src: InputStream) : InputStream() {
    private var chunkRemaining = 0L
    private var started = false
    private var finished = false

    override fun read(): Int {
        val one = ByteArray(1)
        while (true) {
            val n = read(one, 0, 1)
            if (n < 0) return -1
            if (n == 1) return one[0].toInt() and 0xff
        }
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (len == 0) return 0
        if (finished) return -1
        if (chunkRemaining == 0L) {
            nextChunk()
            if (finished) return -1
        }
        val n = src.read(b, off, minOf(len.toLong(), chunkRemaining).toInt())
        if (n < 0) throw EOFException("Unexpected end of chunked body")
        chunkRemaining -= n
        if (chunkRemaining == 0L) readCrlf()
        return n
    }

    private fun nextChunk() {
        val line = readLine()
        val sizeText = line.substringBefore(';').trim()
        val size = sizeText.toLongOrNull(16)
        if (size == null || size < 0) throw IOException("Bad chunk size: $sizeText")
        started = true
        if (size == 0L) {
            // trailers until blank line
            while (readLine().isNotEmpty()) { /* skip */ }
            finished = true
        } else {
            chunkRemaining = size
        }
    }

    private fun readCrlf() {
        if (readLine().isNotEmpty()) throw IOException("Missing CRLF after chunk")
    }

    private fun readLine(): String {
        val sb = StringBuilder()
        while (true) {
            val c = src.read()
            if (c < 0) throw EOFException("Unexpected end of chunked body")
            if (c == '\n'.code) break
            if (c != '\r'.code) sb.append(c.toChar())
            if (sb.length > 8192) throw IOException("Chunk line too long")
        }
        return sb.toString()
    }
}
