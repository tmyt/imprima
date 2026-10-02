package com.rasa.printer.raster

import java.io.OutputStream

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
    private val out: OutputStream,
    private val jpegEncoder: JpegEncoder? = null,
    private val jpegQuality: Int = 85,
) : AutoCloseable {
    /** Adds one page sized info.widthPoints x info.heightPoints with the image filling it. */
    fun addPage(info: RasterPageInfo, pixels: ByteArray): Unit = TODO("unit pdf-writer")

    /** Writes page tree, catalog, xref and trailer; flushes [out]. Does not close [out]. */
    override fun close(): Unit = TODO("unit pdf-writer")
}

/**
 * Convenience: decode a raster stream and write a PDF. FROZEN INTERFACE.
 * Buffers one page of pixels at a time (max ~ width*height*3 bytes).
 */
object RasterToPdf {
    @Throws(RasterFormatException::class)
    fun convert(input: java.io.InputStream, out: OutputStream, jpegEncoder: JpegEncoder? = null): Unit = TODO("unit pdf-writer")
}
