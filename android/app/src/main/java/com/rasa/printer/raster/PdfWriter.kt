package com.rasa.printer.raster

import java.io.ByteArrayOutputStream
import java.io.OutputStream
import java.util.Locale
import java.util.zip.Deflater
import java.util.zip.DeflaterOutputStream

/**
 * Optional lossy encoder for continuous-tone pages (DCTDecode). FROZEN INTERFACE.
 * Returns baseline JPEG bytes for the given pixels, or null to fall back to Flate.
 * [pixels] is rowBytes * height packed as [format] (GRAY_8 or RGB_24 only).
 */
fun interface JpegEncoder {
    fun encode(width: Int, height: Int, format: PixelFormat, pixels: ByteArray, quality: Int): ByteArray?
}

/**
 * Writes a PDF where each page is a single full-page image. FROZEN INTERFACE.
 * Pure JVM (java.util.zip.Deflater for Flate). PDF 1.4, uncompressed xref table.
 *
 * Usage: PdfWriter(out, jpeg).use { w -> w.addPage(info, pixels); ... }  (close() writes trailer).
 * Image encoding: BLACK_1 → /DeviceGray 1 bpc with /Decode [1 0], FlateDecode;
 * GRAY_8 / RGB_24 → JPEG via [jpegEncoder] (DCTDecode) when it returns non-null, else FlateDecode.
 */
class PdfWriter(
    out: OutputStream,
    private val jpegEncoder: JpegEncoder? = null,
    private val jpegQuality: Int = 85,
) : AutoCloseable {
    private val out = CountingOutputStream(out)
    private val offsets = HashMap<Int, Long>()
    private val pageIds = ArrayList<Int>()
    private var nextId = FIRST_PAGE_ID
    private var closed = false

    init {
        writeAscii("%PDF-1.4\n")
        this.out.write(byteArrayOf('%'.code.toByte(), 0xE2.toByte(), 0xE3.toByte(), 0xCF.toByte(), 0xD3.toByte(), '\n'.code.toByte()))
    }

    /** Adds one page sized info.widthPoints x info.heightPoints with the image filling it. */
    fun addPage(info: RasterPageInfo, pixels: ByteArray) {
        check(!closed) { "PdfWriter is closed" }
        require(info.widthPx > 0 && info.heightPx > 0) { "empty page" }
        require(pixels.size.toLong() >= info.rowBytes.toLong() * info.heightPx) { "pixel buffer too small" }
        val imageId = nextId++
        val contentId = nextId++
        val pageId = nextId++

        var colorSpace = "/ColorSpace /DeviceGray /BitsPerComponent 8"
        var extra = ""
        var filter = "/FlateDecode"
        var data: ByteArray? = null
        when (info.pixelFormat) {
            PixelFormat.BLACK_1 -> {
                colorSpace = "/ColorSpace /DeviceGray /BitsPerComponent 1"
                extra = " /Decode [1 0]"
            }
            PixelFormat.GRAY_8 -> Unit
            PixelFormat.RGB_24 -> colorSpace = "/ColorSpace /DeviceRGB /BitsPerComponent 8"
        }
        if (info.pixelFormat != PixelFormat.BLACK_1 && jpegEncoder != null) {
            val jpg = jpegEncoder.encode(info.widthPx, info.heightPx, info.pixelFormat, pixels, jpegQuality)
            val sof = jpg?.let { parseJpegSof(it) }
            if (jpg != null && sof != null && sof.width == info.widthPx && sof.height == info.heightPx) {
                when (sof.components) {
                    1 -> colorSpace = "/ColorSpace /DeviceGray /BitsPerComponent 8"
                    3 -> colorSpace = "/ColorSpace /DeviceRGB /BitsPerComponent 8"
                    4 -> {
                        colorSpace = "/ColorSpace /DeviceCMYK /BitsPerComponent 8"
                        extra = " /Decode [1 0 1 0 1 0 1 0]"
                    }
                    else -> Unit
                }
                if (sof.components == 1 || sof.components == 3 || sof.components == 4) {
                    data = jpg
                    filter = "/DCTDecode"
                }
            }
        }
        if (data == null) data = deflate(pixels, info.rowBytes.toLong().toInt() * info.heightPx)

        beginObject(imageId)
        writeAscii(
            "<< /Type /XObject /Subtype /Image /Width ${info.widthPx} /Height ${info.heightPx} " +
                "$colorSpace$extra /Filter $filter /Length ${data.size} >>\nstream\n",
        )
        out.write(data)
        writeAscii("\nendstream\nendobj\n")

        val w = fmt(info.widthPoints)
        val h = fmt(info.heightPoints)
        val content = "q $w 0 0 $h 0 0 cm /Im0 Do Q".toByteArray(Charsets.ISO_8859_1)
        beginObject(contentId)
        writeAscii("<< /Length ${content.size} >>\nstream\n")
        out.write(content)
        writeAscii("\nendstream\nendobj\n")

        beginObject(pageId)
        writeAscii(
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $w $h] " +
                "/Resources << /XObject << /Im0 $imageId 0 R >> >> /Contents $contentId 0 R >>\nendobj\n",
        )
        pageIds.add(pageId)
    }

    /** Writes page tree, catalog, xref and trailer; flushes [out]. Does not close [out]. */
    override fun close() {
        if (closed) return
        closed = true
        beginObject(PAGES_ID)
        writeAscii("<< /Type /Pages /Kids [${pageIds.joinToString(" ") { "$it 0 R" }}] /Count ${pageIds.size} >>\nendobj\n")
        beginObject(CATALOG_ID)
        writeAscii("<< /Type /Catalog /Pages $PAGES_ID 0 R >>\nendobj\n")
        beginObject(INFO_ID)
        writeAscii("<< /Producer (Rasa Printer) >>\nendobj\n")

        val xrefPos = out.count
        val size = nextId
        val sb = StringBuilder("xref\n0 $size\n0000000000 65535 f \n")
        for (id in 1 until size) {
            sb.append(String.format(Locale.ROOT, "%010d 00000 n \n", offsets.getValue(id)))
        }
        sb.append("trailer\n<< /Size $size /Root $CATALOG_ID 0 R /Info $INFO_ID 0 R >>\nstartxref\n$xrefPos\n%%EOF\n")
        writeAscii(sb.toString())
        out.flush()
    }

    private class JpegSof(val width: Int, val height: Int, val components: Int)

    /** Walks JPEG markers to the first SOF0/1/2 segment; null if absent or malformed. */
    private fun parseJpegSof(b: ByteArray): JpegSof? {
        fun u8(i: Int) = b[i].toInt() and 0xFF
        if (b.size < 4 || u8(0) != 0xFF || u8(1) != 0xD8) return null
        var i = 2
        while (i + 3 < b.size) {
            if (u8(i) != 0xFF) return null
            while (i + 1 < b.size && u8(i + 1) == 0xFF) i++
            if (i + 1 >= b.size) return null
            val m = u8(i + 1)
            i += 2
            if (m == 0x01 || m in 0xD0..0xD8) continue
            if (m == 0xD9 || m == 0xDA) return null
            if (i + 2 > b.size) return null
            val len = (u8(i) shl 8) or u8(i + 1)
            if (len < 2) return null
            if (m == 0xC0 || m == 0xC1 || m == 0xC2) {
                if (len < 8 || i + 8 > b.size) return null
                val h = (u8(i + 3) shl 8) or u8(i + 4)
                val w = (u8(i + 5) shl 8) or u8(i + 6)
                return JpegSof(w, h, u8(i + 7))
            }
            i += len
        }
        return null
    }

    private fun deflate(pixels: ByteArray, length: Int): ByteArray {
        val bos = ByteArrayOutputStream(maxOf(1024, length / 4))
        val deflater = Deflater(Deflater.DEFAULT_COMPRESSION)
        try {
            DeflaterOutputStream(bos, deflater, 64 * 1024).use { it.write(pixels, 0, length) }
        } finally {
            deflater.end()
        }
        return bos.toByteArray()
    }

    private fun beginObject(id: Int) {
        offsets[id] = out.count
        writeAscii("$id 0 obj\n")
    }

    private fun writeAscii(s: String) = out.write(s.toByteArray(Charsets.ISO_8859_1))

    private fun fmt(v: Float): String {
        var s = java.math.BigDecimal(v.toDouble()).setScale(2, java.math.RoundingMode.HALF_UP).toPlainString()
        if (s.contains('.')) s = s.trimEnd('0').trimEnd('.')
        return s
    }

    private class CountingOutputStream(private val d: OutputStream) : OutputStream() {
        var count = 0L
            private set

        override fun write(b: Int) { d.write(b); count++ }
        override fun write(b: ByteArray, off: Int, len: Int) { d.write(b, off, len); count += len }
        override fun flush() = d.flush()
    }

    private companion object {
        const val CATALOG_ID = 1
        const val PAGES_ID = 2
        const val INFO_ID = 3
        const val FIRST_PAGE_ID = 4
    }
}

/**
 * Convenience: decode a raster stream and write a PDF. FROZEN INTERFACE.
 * Buffers one page of pixels at a time (max ~ width*height*3 bytes).
 */
object RasterToPdf {
    @Throws(RasterFormatException::class)
    fun convert(input: java.io.InputStream, out: OutputStream, jpegEncoder: JpegEncoder? = null) {
        PdfWriter(out, jpegEncoder).use { writer ->
            RasterDecoder.decode(input, object : RasterSink {
                private var info: RasterPageInfo? = null
                private var buf: ByteArray? = null
                private var pos = 0

                override fun beginPage(info: RasterPageInfo) {
                    this.info = info
                    buf = ByteArray(Math.multiplyExact(info.rowBytes, info.heightPx))
                    pos = 0
                }

                override fun row(row: ByteArray) {
                    val b = buf ?: return
                    val n = info!!.rowBytes
                    if (pos + n > b.size) return
                    System.arraycopy(row, 0, b, pos, n)
                    pos += n
                }

                override fun endPage() {
                    val i = info ?: return
                    val b = buf ?: return
                    info = null
                    buf = null
                    writer.addPage(i, b)
                }
            })
        }
    }
}
