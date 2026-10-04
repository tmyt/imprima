package dev.utatane.imprima.raster

import java.io.EOFException
import java.io.IOException
import java.io.InputStream

/**
 * Streaming decoder for Apple URF (image/urf, "UNIRAST" magic) and PWG Raster
 * (image/pwg-raster, "RaS2" magic). FROZEN INTERFACE. Detects the format from the magic.
 * Decodes every page, un-RLEs rows and converts to one of the [PixelFormat]s:
 *  - 1-bit black / 1-bit gray → BLACK_1 (gray 1-bit is inverted so 1 = black)
 *  - 8-bit gray (sgray/W8/"DeviceGray") → GRAY_8 (8-bit black/K is inverted)
 *  - 24-bit sRGB / AdobeRGB / DeviceRGB → RGB_24
 *  - 32-bit CMYK → RGB_24 (naive conversion); 16-bit depths → downsampled to 8-bit
 * Throws RasterFormatException on malformed input.
 *
 * Reads with many small reads: pass a buffered stream for performance. The decoder never
 * reads beyond the end of the last page except for the single probe byte used by PWG
 * (and URF with page count 0) to detect end of document.
 */
object RasterDecoder {
    private val URF_MAGIC = byteArrayOf(
        'U'.code.toByte(), 'N'.code.toByte(), 'I'.code.toByte(), 'R'.code.toByte(),
        'A'.code.toByte(), 'S'.code.toByte(), 'T'.code.toByte(), 0,
    )
    private val PWG_MAGIC = byteArrayOf('R'.code.toByte(), 'a'.code.toByte(), 'S'.code.toByte(), '2'.code.toByte())

    private const val PWG_HEADER_SIZE = 1796
    private const val URF_PAGE_HEADER_SIZE = 32
    private const val MAX_DIMENSION = 65_536
    private const val MAX_LINE_BYTES = 64 * 1024 * 1024

    @Throws(RasterFormatException::class)
    fun decode(input: InputStream, sink: RasterSink) {
        try {
            val magic = ByteArray(8)
            readFully(input, magic, 0, 4, "file header")
            if (startsWith(magic, PWG_MAGIC)) {
                decodePwg(input, sink)
                return
            }
            readFully(input, magic, 4, 4, "file header")
            if (startsWith(magic, URF_MAGIC)) {
                decodeUrf(input, sink)
                return
            }
            throw RasterFormatException("unknown raster magic: ${magic.joinToString(" ") { "%02x".format(it) }}")
        } catch (e: RasterFormatException) {
            throw e
        } catch (e: EOFException) {
            throw RasterFormatException("truncated raster data: ${e.message}", e)
        } catch (e: IOException) {
            throw RasterFormatException("I/O error while reading raster: ${e.message}", e)
        }
    }

    /** Returns "image/urf", "image/pwg-raster" or null, from the first 8 bytes. */
    fun sniff(head: ByteArray): String? = when {
        head.size >= 8 && startsWith(head, URF_MAGIC) -> "image/urf"
        head.size >= 4 && startsWith(head, PWG_MAGIC) -> "image/pwg-raster"
        else -> null
    }

    // ---------------------------------------------------------------- URF

    private fun decodeUrf(input: InputStream, sink: RasterSink) {
        val countBuf = ByteArray(4)
        readFully(input, countBuf, 0, 4, "URF page count")
        val pageCount = u32(countBuf, 0)
        val header = ByteArray(URF_PAGE_HEADER_SIZE)
        var page = 0L
        while (pageCount == 0L || page < pageCount) {
            if (pageCount == 0L) {
                val first = input.read()
                if (first < 0) return
                header[0] = first.toByte()
                readFully(input, header, 1, URF_PAGE_HEADER_SIZE - 1, "URF page header")
            } else {
                readFully(input, header, 0, URF_PAGE_HEADER_SIZE, "URF page ${page + 1} header")
            }
            val bpp = header[0].toInt() and 0xFF
            val colorSpace = header[1].toInt() and 0xFF
            val width = checkDim(u32(header, 12), "width")
            val height = checkDim(u32(header, 16), "height")
            val dpi = u32(header, 20).toInt()
            if (dpi <= 0) throw RasterFormatException("invalid URF resolution $dpi")
            val family = when (colorSpace) {
                0, 4 -> Family.GRAY
                1, 3, 5 -> Family.RGB
                6 -> Family.CMYK
                else -> throw RasterFormatException("unsupported URF color space $colorSpace")
            }
            val layout = Layout.of(family, bpp, "URF")
            decodePage(input, sink, layout, width, height, dpi, dpi, lineBytes(width, bpp))
            page++
        }
    }

    // ---------------------------------------------------------------- PWG

    private fun decodePwg(input: InputStream, sink: RasterSink) {
        val h = ByteArray(PWG_HEADER_SIZE)
        while (true) {
            val first = input.read()
            if (first < 0) return // clean EOF at a page boundary
            h[0] = first.toByte()
            readFully(input, h, 1, PWG_HEADER_SIZE - 1, "PWG page header")
            val dpiX = u32(h, 276).toInt()
            val dpiY = u32(h, 280).toInt()
            val width = checkDim(u32(h, 372), "width")
            val height = checkDim(u32(h, 376), "height")
            val bpc = u32(h, 384).toInt()
            val bpp = u32(h, 388).toInt()
            val bytesPerLine = u32(h, 392)
            val colorOrder = u32(h, 396)
            val colorSpace = u32(h, 400).toInt()
            if (dpiX <= 0 || dpiY <= 0) throw RasterFormatException("invalid PWG resolution ${dpiX}x$dpiY")
            if (colorOrder != 0L) throw RasterFormatException("unsupported PWG color order $colorOrder")
            val family = when (colorSpace) {
                0, 18 -> Family.GRAY
                1, 19, 20 -> Family.RGB
                3 -> Family.BLACK
                6 -> Family.CMYK
                48 -> Family.GRAY
                50 -> Family.RGB
                51 -> Family.CMYK
                else -> throw RasterFormatException("unsupported PWG color space $colorSpace")
            }
            if (bpp != bpc * family.components) {
                throw RasterFormatException("unsupported PWG depth: $bpc bits/color, $bpp bits/pixel, color space $colorSpace")
            }
            val layout = Layout.of(family, bpp, "PWG")
            val expected = lineBytes(width, bpp)
            if (bytesPerLine != expected.toLong()) {
                throw RasterFormatException("PWG bytesPerLine $bytesPerLine does not match width $width x $bpp bpp")
            }
            decodePage(input, sink, layout, width, height, dpiX, dpiY, expected)
        }
    }

    // ---------------------------------------------------------------- shared

    private enum class Family(val components: Int, val blank: Byte) {
        GRAY(1, 0xFF.toByte()), // W / sGray / DeviceW: 0 = black
        BLACK(1, 0x00),         // K: 1/255 = black
        RGB(3, 0xFF.toByte()),
        CMYK(4, 0x00),
    }

    /** Source layout of one coded line and how to convert it. */
    private class Layout(val family: Family, val bpp: Int, val format: PixelFormat) {
        /** RLE pixel unit in bytes (1 for sub-byte depths). */
        val unit: Int get() = if (bpp < 8) 1 else bpp / 8
        val bytesPerComponent: Int get() = if (bpp < 8) 0 else bpp / 8 / family.components

        companion object {
            fun of(family: Family, bpp: Int, what: String): Layout {
                val fmt = when (family) {
                    Family.GRAY, Family.BLACK -> when (bpp) {
                        1 -> PixelFormat.BLACK_1
                        8, 16 -> PixelFormat.GRAY_8
                        else -> null
                    }
                    Family.RGB -> if (bpp == 24 || bpp == 48) PixelFormat.RGB_24 else null
                    Family.CMYK -> if (bpp == 32 || bpp == 64) PixelFormat.RGB_24 else null
                } ?: throw RasterFormatException("unsupported $what bits per pixel $bpp for ${family.name} color")
                return Layout(family, bpp, fmt)
            }
        }
    }

    private fun decodePage(
        input: InputStream,
        sink: RasterSink,
        layout: Layout,
        width: Int,
        height: Int,
        dpiX: Int,
        dpiY: Int,
        bytesPerLine: Int,
    ) {
        val info = RasterPageInfo(width, height, dpiX, dpiY, layout.format)
        val line = ByteArray(bytesPerLine)
        val out = ByteArray(info.rowBytes)
        val unit = layout.unit
        sink.beginPage(info)
        var y = 0
        while (y < height) {
            val repeat = readByte(input, "line repeat at row $y") + 1
            var pos = 0
            while (pos < bytesPerLine) {
                val n = readByte(input, "run at row $y").toByte().toInt()
                when {
                    n == -128 -> {
                        line.fill(layout.family.blank, pos, bytesPerLine)
                        pos = bytesPerLine
                    }
                    n >= 0 -> {
                        val count = (n + 1) * unit
                        if (pos + count > bytesPerLine) throw RasterFormatException("repeat run overflows line at row $y")
                        readFully(input, line, pos, unit, "pixel at row $y")
                        var p = pos + unit
                        while (p < pos + count) {
                            System.arraycopy(line, pos, line, p, unit)
                            p += unit
                        }
                        pos += count
                    }
                    else -> {
                        val count = (-n + 1) * unit
                        if (pos + count > bytesPerLine) throw RasterFormatException("literal run overflows line at row $y")
                        readFully(input, line, pos, count, "literal pixels at row $y")
                        pos += count
                    }
                }
            }
            convert(layout, width, line, out)
            // A line repeat that runs past the page end is clamped rather than rejected.
            val emit = minOf(repeat, height - y)
            repeat(emit) { sink.row(out) }
            y += emit
        }
        sink.endPage()
    }

    private fun convert(layout: Layout, width: Int, src: ByteArray, dst: ByteArray) {
        when (layout.format) {
            PixelFormat.BLACK_1 -> {
                val invert = layout.family == Family.GRAY
                for (i in dst.indices) dst[i] = if (invert) src[i].toInt().inv().toByte() else src[i]
                val pad = dst.size * 8 - width
                if (pad > 0) dst[dst.size - 1] = (dst[dst.size - 1].toInt() and (0xFF shl pad)).toByte()
            }
            PixelFormat.GRAY_8 -> {
                val step = layout.bytesPerComponent
                val invert = layout.family == Family.BLACK
                var s = 0
                for (i in 0 until width) {
                    val v = src[s].toInt() and 0xFF
                    dst[i] = (if (invert) 255 - v else v).toByte()
                    s += step
                }
            }
            PixelFormat.RGB_24 -> {
                val step = layout.bytesPerComponent
                if (layout.family == Family.RGB) {
                    if (step == 1) {
                        System.arraycopy(src, 0, dst, 0, dst.size)
                    } else {
                        for (i in dst.indices) dst[i] = src[i * step]
                    }
                } else {
                    var s = 0
                    var d = 0
                    for (i in 0 until width) {
                        val c = src[s].toInt() and 0xFF
                        val m = src[s + step].toInt() and 0xFF
                        val yy = src[s + 2 * step].toInt() and 0xFF
                        val k = src[s + 3 * step].toInt() and 0xFF
                        dst[d] = (255 - minOf(255, c + k)).toByte()
                        dst[d + 1] = (255 - minOf(255, m + k)).toByte()
                        dst[d + 2] = (255 - minOf(255, yy + k)).toByte()
                        s += 4 * step
                        d += 3
                    }
                }
            }
        }
    }

    private fun lineBytes(width: Int, bpp: Int): Int {
        val bytes = (width.toLong() * bpp + 7) / 8
        if (bytes > MAX_LINE_BYTES) throw RasterFormatException("raster line too large: $bytes bytes")
        return bytes.toInt()
    }

    private fun checkDim(v: Long, what: String): Int {
        if (v <= 0 || v > MAX_DIMENSION) throw RasterFormatException("invalid raster $what $v")
        return v.toInt()
    }

    private fun startsWith(a: ByteArray, prefix: ByteArray): Boolean {
        if (a.size < prefix.size) return false
        for (i in prefix.indices) if (a[i] != prefix[i]) return false
        return true
    }

    private fun u32(b: ByteArray, off: Int): Long =
        ((b[off].toLong() and 0xFF) shl 24) or ((b[off + 1].toLong() and 0xFF) shl 16) or
            ((b[off + 2].toLong() and 0xFF) shl 8) or (b[off + 3].toLong() and 0xFF)

    private fun readByte(input: InputStream, what: String): Int {
        val b = input.read()
        if (b < 0) throw RasterFormatException("truncated raster data: unexpected end of stream reading $what")
        return b
    }

    private fun readFully(input: InputStream, buf: ByteArray, off: Int, len: Int, what: String) {
        var done = 0
        while (done < len) {
            val n = input.read(buf, off + done, len - done)
            if (n < 0) throw RasterFormatException("truncated raster data: unexpected end of stream reading $what")
            done += n
        }
    }
}
