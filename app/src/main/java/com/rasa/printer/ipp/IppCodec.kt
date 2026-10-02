package com.rasa.printer.ipp

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

class IppDecodeException(message: String, cause: Throwable? = null) : IOException(message, cause)

/**
 * IPP binary encoding (RFC 8010). FROZEN INTERFACE.
 *
 * decode() reads header + attribute groups up to and including the end-of-attributes
 * tag (0x03) and returns; any document data following it is left UNREAD in [input]
 * so the caller can stream it. Must not read ahead beyond the end tag (no buffering
 * of the stream beyond what is consumed).
 */
object IppCodec {
    @Throws(IppDecodeException::class)
    fun decode(input: InputStream): IppMessage = TODO("unit A")

    fun encode(message: IppMessage): ByteArray = TODO("unit A")

    fun encode(message: IppMessage, out: OutputStream): Unit = TODO("unit A")
}
