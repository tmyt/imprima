package dev.utatane.imprima.service

import dev.utatane.imprima.printer.ConvertedDocument
import dev.utatane.imprima.printer.DocumentConverter
import dev.utatane.imprima.raster.JpegEncoder
import dev.utatane.imprima.raster.RasterDecoder
import dev.utatane.imprima.raster.RasterToPdf
import java.io.File

/** Converts stored URF / PWG raster documents to PDF. */
class RasterDocumentConverter(private val jpegEncoder: JpegEncoder?) : DocumentConverter {
    override fun convert(source: File, format: String, target: (extension: String) -> File): ConvertedDocument? {
        val f = format.lowercase()
        val applicable = f == "image/urf" || f == "image/pwg-raster" ||
            (f == "application/octet-stream" && sniffsRaster(source))
        if (!applicable) return null
        val out = target("pdf")
        try {
            source.inputStream().buffered().use { input ->
                out.outputStream().buffered().use { os -> RasterToPdf.convert(input, os, jpegEncoder) }
            }
        } catch (e: Throwable) {
            out.delete()
            throw e
        }
        return ConvertedDocument(out, "application/pdf")
    }

    private fun sniffsRaster(source: File): Boolean = try {
        val head = ByteArray(8)
        val n = source.inputStream().use { it.read(head) }
        n > 0 && RasterDecoder.sniff(head.copyOf(n)) != null
    } catch (e: Exception) {
        false
    }
}
