package dev.utatane.imprima.raster

import java.io.IOException
import java.io.InputStream

class RasterFormatException(message: String, cause: Throwable? = null) : IOException(message, cause)

/** Pixel layout of a decoded raster page. FROZEN INTERFACE. */
enum class PixelFormat(val bitsPerPixel: Int, val components: Int) {
    /** 1 bit per pixel, 1 = black (packed MSB first, rows padded to byte boundary). */
    BLACK_1(1, 1),
    /** 8-bit grayscale, 0 = black. */
    GRAY_8(8, 1),
    /** 8-bit sRGB, 3 bytes per pixel. */
    RGB_24(24, 3),
}

/** One page of a raster document. FROZEN INTERFACE. */
data class RasterPageInfo(
    val widthPx: Int,
    val heightPx: Int,
    val dpiX: Int,
    val dpiY: Int,
    val pixelFormat: PixelFormat,
) {
    /** Bytes per decoded row (rows of BLACK_1 are byte-padded). */
    val rowBytes: Int get() = (widthPx * pixelFormat.bitsPerPixel + 7) / 8
    val widthPoints: Float get() = widthPx * 72f / dpiX
    val heightPoints: Float get() = heightPx * 72f / dpiY
}

/** Receives decoded pages row by row. FROZEN INTERFACE. */
interface RasterSink {
    fun beginPage(info: RasterPageInfo)
    /** [row] holds exactly info.rowBytes bytes; the buffer is reused between calls - copy if you keep it. */
    fun row(row: ByteArray)
    fun endPage()
}
