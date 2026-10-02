package com.rasa.printer.raster

import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.zip.GZIPInputStream
import java.util.zip.Inflater

class PdfWriterTest {
    private val rgbInfo = RasterPageInfo(8, 4, 72, 72, PixelFormat.RGB_24)
    private val rgbPixels = ByteArray(8 * 3 * 4) { (it * 7).toByte() }
    private val monoInfo = RasterPageInfo(16, 2, 144, 144, PixelFormat.BLACK_1)
    private val monoPixels = byteArrayOf(0xF0.toByte(), 0x0F, 0xAA.toByte(), 0x55)

    private fun build(jpeg: JpegEncoder? = null): ByteArray {
        val bos = ByteArrayOutputStream()
        PdfWriter(bos, jpeg).use {
            it.addPage(rgbInfo, rgbPixels)
            it.addPage(monoInfo, monoPixels)
        }
        return bos.toByteArray()
    }

    private fun str(b: ByteArray) = String(b, Charsets.ISO_8859_1)
    private fun count(s: String, sub: String) = s.windowed(sub.length).count { it == sub }

    private fun streamAfter(pdf: ByteArray, marker: String): ByteArray {
        val s = str(pdf)
        val m = s.indexOf(marker)
        assertTrue("marker $marker", m >= 0)
        val len = Regex("/Length (\\d+)").find(s, m)!!.groupValues[1].toInt()
        val start = s.indexOf("stream\n", m) + 7
        return pdf.copyOfRange(start, start + len)
    }

    private fun inflate(b: ByteArray): ByteArray {
        val inf = Inflater()
        inf.setInput(b)
        val out = ByteArrayOutputStream()
        val buf = ByteArray(4096)
        while (!inf.finished()) {
            val n = inf.inflate(buf)
            if (n == 0 && (inf.needsInput() || inf.needsDictionary())) break
            out.write(buf, 0, n)
        }
        return out.toByteArray()
    }

    @Test fun structureAndXref() {
        val pdf = build()
        val s = str(pdf)
        assertTrue(s.startsWith("%PDF-1.4"))
        assertTrue(s.endsWith("%%EOF\n"))
        assertTrue(s.contains("/Count 2"))
        assertEquals(2, count(s, "/Type /Page ") )
        assertTrue(s.contains("/FlateDecode"))
        assertTrue(s.contains("/Decode [1 0]"))
        assertTrue(s.contains("/MediaBox [0 0 8 4]"))
        assertTrue(s.contains("/MediaBox [0 0 8 1]"))
        val sx = Regex("startxref\n(\\d+)\n").find(s)!!.groupValues[1].toInt()
        assertEquals("xref", s.substring(sx, sx + 4))
        val lines = s.substring(sx).split("\n")
        val n = lines[1].split(" ")[1].toInt()
        assertEquals("0000000000 65535 f ", lines[2])
        for (i in 1 until n) {
            val e = lines[2 + i]
            assertTrue(e.endsWith(" 00000 n "))
            val off = e.substring(0, 10).toInt()
            assertTrue("obj $i", s.startsWith("$i 0 obj\n", off))
        }
    }

    @Test fun streamsInflateToInput() {
        val pdf = build()
        assertArrayEquals(rgbPixels, inflate(streamAfter(pdf, "/Width 8 /Height 4")))
        assertArrayEquals(monoPixels, inflate(streamAfter(pdf, "/Width 16 /Height 2")))
    }

    @Test fun jpegUsedAndFallback() {
        val jpg = fakeJpeg(8, 4, 3)
        var args: List<Any>? = null
        val pdf = build { w, h, f, _, q -> args = listOf(w, h, f, q); jpg }
        val s = str(pdf)
        assertTrue(s.contains("/DCTDecode"))
        assertArrayEquals(jpg, streamAfter(pdf, "/DCTDecode"))
        assertEquals(listOf<Any>(8, 4, PixelFormat.RGB_24, 85), args)
        val pdf2 = build { _, _, _, _, _ -> null }
        assertFalse(str(pdf2).contains("/DCTDecode"))
        assertTrue(str(pdf2).contains("/FlateDecode"))
    }

    private fun fakeJpeg(w: Int, h: Int, comps: Int): ByteArray {
        val sof = byteArrayOf(
            0xFF.toByte(), 0xC0.toByte(), 0, (8 + 3 * comps).toByte(), 8,
            (h shr 8).toByte(), h.toByte(), (w shr 8).toByte(), w.toByte(), comps.toByte(),
        ) + ByteArray(3 * comps) { 1 }
        // SOI, an APP0 segment, SOF0, then arbitrary tail
        return byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE0.toByte(), 0, 4, 0, 0) +
            sof + byteArrayOf(0x11, 0x22, 0x33)
    }

    private fun grayPdf(jpg: ByteArray): String {
        val bos = ByteArrayOutputStream()
        PdfWriter(bos, JpegEncoder { _, _, _, _, _ -> jpg }).use { it.addPage(RasterPageInfo(4, 2, 72, 72, PixelFormat.GRAY_8), ByteArray(8)) }
        return str(bos.toByteArray())
    }

    @Test fun jpegColorSpaceFollowsComponents() {
        val three = grayPdf(fakeJpeg(4, 2, 3))
        assertTrue(three.contains("/DeviceRGB") && three.contains("/DCTDecode") && !three.contains("/DeviceGray"))
        val one = grayPdf(fakeJpeg(4, 2, 1))
        assertTrue(one.contains("/DeviceGray") && one.contains("/DCTDecode"))
        val four = grayPdf(fakeJpeg(4, 2, 4))
        assertTrue(four.contains("/DeviceCMYK") && four.contains("/Decode [1 0 1 0 1 0 1 0]") && four.contains("/DCTDecode"))
    }

    @Test fun badJpegFallsBackToFlate() {
        for (bad in listOf(byteArrayOf(1, 2, 3, 4, 5), fakeJpeg(5, 2, 3), fakeJpeg(4, 2, 2), ByteArray(0))) {
            val s = grayPdf(bad)
            assertFalse(s.contains("/DCTDecode"))
            assertTrue(s.contains("/FlateDecode") && s.contains("/DeviceGray"))
        }
    }

    @Test fun grayPage() {
        val bos = ByteArrayOutputStream()
        PdfWriter(bos).use { it.addPage(RasterPageInfo(4, 2, 72, 72, PixelFormat.GRAY_8), ByteArray(8)) }
        val s = str(bos.toByteArray())
        assertTrue(s.contains("/DeviceGray"))
        assertTrue(s.contains("/BitsPerComponent 8"))
    }

    private fun sips(pdf: ByteArray, png: File): Int {
        val f = File.createTempFile("pdfwriter", ".pdf")
        f.writeBytes(pdf)
        val p = ProcessBuilder("/usr/bin/sips", "-s", "format", "png", f.path, "--out", png.path)
            .redirectErrorStream(true).start()
        p.inputStream.readBytes()
        val rc = p.waitFor()
        f.delete()
        return rc
    }

    @Test fun sipsRenders() {
        assumeTrue(File("/usr/bin/sips").exists())
        val png = File.createTempFile("pdfwriter", ".png")
        assertEquals(0, sips(build(), png))
        assertTrue(png.length() > 0)
        png.delete()
        // visual check file
        val dir = File("/private/tmp/claude-502/-Users-tsumori-labo-rasa/6981ed8a-48ee-456d-b11a-413bc8ce5277/scratchpad")
        if (dir.isDirectory) {
            val px = ByteArray(64 * 64 * 3)
            for (y in 0 until 64) for (x in 0 until 64) {
                px[(y * 64 + x) * 3] = (x * 4).toByte(); px[(y * 64 + x) * 3 + 1] = (y * 4).toByte(); px[(y * 64 + x) * 3 + 2] = 128.toByte()
            }
            val bos = ByteArrayOutputStream()
            PdfWriter(bos).use { it.addPage(RasterPageInfo(64, 64, 72, 72, PixelFormat.RGB_24), px) }
            sips(bos.toByteArray(), File(dir, "pdfwriter-check.png"))
        }
    }

    @Test fun convertFixture() {
        val input = GZIPInputStream(javaClass.getResourceAsStream("/raster/a4-mono-2pages.pwg.gz")!!)
        val bos = ByteArrayOutputStream()
        RasterToPdf.convert(input, bos)
        val s = str(bos.toByteArray())
        assertTrue(s.contains("/Count 2"))
        assertTrue(s.contains("/MediaBox [0 0 594.96 841.92]"))
        assumeTrue(File("/usr/bin/sips").exists())
        val png = File.createTempFile("pdfwriter", ".png")
        assertEquals(0, sips(bos.toByteArray(), png))
        png.delete()
    }
}
