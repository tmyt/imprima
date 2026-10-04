package dev.utatane.imprima.raster

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.BufferedInputStream
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.util.zip.CRC32
import java.util.zip.DeflaterOutputStream
import java.util.zip.GZIPInputStream

class RasterDecoderTest {

    /** Collects every row (copied). */
    private class CollectingSink : RasterSink {
        val pages = mutableListOf<Pair<RasterPageInfo, MutableList<ByteArray>>>()
        var open = false
        override fun beginPage(info: RasterPageInfo) {
            assertTrue("beginPage while page open", !open)
            open = true
            pages += info to mutableListOf()
        }
        override fun row(row: ByteArray) {
            assertTrue(open)
            assertEquals(pages.last().first.rowBytes, row.size)
            pages.last().second += row.copyOf()
        }
        override fun endPage() {
            assertTrue(open)
            open = false
        }
    }

    /** Statistics-only sink for big fixtures (does not keep rows). */
    private class StatsSink(val keepFirstPage: Boolean = false) : RasterSink {
        val infos = mutableListOf<RasterPageInfo>()
        val rowCounts = mutableListOf<Int>()
        val nonWhite = mutableListOf<Long>()
        val graySum = mutableListOf<Long>()
        val distinctRowHashes = mutableListOf<MutableSet<Int>>()
        var firstPage: MutableList<ByteArray>? = null
        override fun beginPage(info: RasterPageInfo) {
            infos += info; rowCounts += 0; nonWhite += 0; graySum += 0; distinctRowHashes += mutableSetOf<Int>()
            if (keepFirstPage && infos.size == 1) firstPage = mutableListOf()
        }
        override fun row(row: ByteArray) {
            val info = infos.last()
            val i = infos.size - 1
            assertEquals(info.rowBytes, row.size)
            rowCounts[i]++
            var nw = 0L
            var gs = 0L
            when (info.pixelFormat) {
                PixelFormat.BLACK_1 -> for (b in row) nw += Integer.bitCount(b.toInt() and 0xFF)
                PixelFormat.GRAY_8 -> for (b in row) { val v = b.toInt() and 0xFF; gs += v; if (v < 250) nw++ }
                PixelFormat.RGB_24 -> {
                    var p = 0
                    while (p < row.size) {
                        if ((row[p].toInt() and 0xFF) < 250 || (row[p + 1].toInt() and 0xFF) < 250 ||
                            (row[p + 2].toInt() and 0xFF) < 250) nw++
                        p += 3
                    }
                }
            }
            nonWhite[i] += nw; graySum[i] += gs
            if (distinctRowHashes[i].size < 10) distinctRowHashes[i] += row.contentHashCode()
            if (i == 0) firstPage?.add(row.copyOf())
        }
        override fun endPage() {}
        fun nonWhiteFraction(i: Int) = nonWhite[i].toDouble() / (infos[i].widthPx.toLong() * infos[i].heightPx)
    }

    private fun fixture(name: String): InputStream =
        BufferedInputStream(GZIPInputStream(javaClass.getResourceAsStream("/raster/$name")!!), 1 shl 16)

    // ------------------------------------------------------------ helpers to hand-encode

    private class Bytes {
        val out = ByteArrayOutputStream()
        fun u8(vararg v: Int) = apply { v.forEach { out.write(it) } }
        fun u32(v: Long) = apply { u8((v ushr 24).toInt() and 0xFF, (v ushr 16).toInt() and 0xFF, (v ushr 8).toInt() and 0xFF, v.toInt() and 0xFF) }
        fun ascii(s: String) = apply { out.write(s.toByteArray(Charsets.US_ASCII)) }
        fun raw(b: ByteArray) = apply { out.write(b) }
        fun bytes(): ByteArray = out.toByteArray()
    }

    private fun urfPageHeader(bpp: Int, cs: Int, w: Int, h: Int, dpi: Int) =
        Bytes().u8(bpp, cs, 1, 0).u32(0).u32(0).u32(w.toLong()).u32(h.toLong()).u32(dpi.toLong()).u32(0).u32(0).bytes()

    private fun pwgHeader(w: Int, h: Int, dpiX: Int, dpiY: Int, bpc: Int, bpp: Int, cs: Int, numColors: Int): ByteArray {
        val hdr = ByteArray(1796)
        fun put(off: Int, v: Int) {
            hdr[off] = (v ushr 24).toByte(); hdr[off + 1] = (v ushr 16).toByte()
            hdr[off + 2] = (v ushr 8).toByte(); hdr[off + 3] = v.toByte()
        }
        "PwgRaster".toByteArray().copyInto(hdr, 0)
        put(276, dpiX); put(280, dpiY)
        put(372, w); put(376, h)
        put(384, bpc); put(388, bpp); put(392, (w * bpp + 7) / 8)
        put(396, 0); put(400, cs); put(420, numColors)
        return hdr
    }

    private fun rgb(vararg px: Int): ByteArray =
        ByteArray(px.size * 3).also { b -> px.forEachIndexed { i, p -> b[i * 3] = (p shr 16).toByte(); b[i * 3 + 1] = (p shr 8).toByte(); b[i * 3 + 2] = p.toByte() } }

    // ------------------------------------------------------------ tests

    @Test
    fun sniffDetectsMagics() {
        assertEquals("image/urf", RasterDecoder.sniff("UNIRAST\u0000\u0000\u0000".toByteArray()))
        assertEquals("image/urf", RasterDecoder.sniff("UNIRAST\u0000".toByteArray()))
        assertEquals("image/pwg-raster", RasterDecoder.sniff("RaS2PwgRaster".toByteArray()))
        assertEquals("image/pwg-raster", RasterDecoder.sniff("RaS2".toByteArray()))
        assertNull(RasterDecoder.sniff("%PDF-1.7".toByteArray()))
        assertNull(RasterDecoder.sniff("UNIRASTX".toByteArray()))
        assertNull(RasterDecoder.sniff("UNIRAST".toByteArray()))
        assertNull(RasterDecoder.sniff("RaS".toByteArray()))
        assertNull(RasterDecoder.sniff(ByteArray(0)))
        assertNull(RasterDecoder.sniff("RaS3xxxx".toByteArray()))
    }

    @Test
    fun syntheticUrfTwoPages() {
        val r = 0xFF0000; val g = 0x00FF00; val b = 0x0000FF; val w = 0xFFFFFF; val k = 0x000000
        val doc = Bytes().ascii("UNIRAST").u8(0).u32(2)
            // page 1: 4x3 sRGB @300
            .raw(urfPageHeader(24, 1, 4, 3, 300))
            // line 0, repeated twice (L=1): repeat red x2, literal [green, blue]
            .u8(1).u8(1).raw(rgb(r)).u8(0xFF).raw(rgb(g, b))
            // line 2: literal [blue], then 0x80 fill white
            .u8(0).u8(0xFF /* -1 => 2 px */).raw(rgb(b, k)).u8(0x80)
            // page 2: 4x3 DeviceRGB @600, one line repeated 3 times: repeat black x4
            .raw(urfPageHeader(24, 5, 4, 3, 600))
            .u8(2).u8(3).raw(rgb(k))
            .bytes()
        val sink = CollectingSink()
        RasterDecoder.decode(ByteArrayInputStream(doc), sink)
        assertEquals(2, sink.pages.size)
        assertEquals(RasterPageInfo(4, 3, 300, 300, PixelFormat.RGB_24), sink.pages[0].first)
        assertEquals(RasterPageInfo(4, 3, 600, 600, PixelFormat.RGB_24), sink.pages[1].first)
        val p1 = sink.pages[0].second
        assertEquals(3, p1.size)
        assertArrayEquals(rgb(r, r, g, b), p1[0])
        assertArrayEquals(rgb(r, r, g, b), p1[1])
        assertArrayEquals(rgb(b, k, w, w), p1[2])
        val p2 = sink.pages[1].second
        assertEquals(3, p2.size)
        p2.forEach { assertArrayEquals(rgb(k, k, k, k), it) }
        assertTrue(!sink.open)
    }

    @Test
    fun syntheticUrfUnknownPageCountDecodesUntilEof() {
        val page = Bytes().raw(urfPageHeader(8, 4, 3, 1, 300)).u8(0).u8(0xFE).u8(0x00, 0x80, 0xFF).bytes()
        val doc = Bytes().ascii("UNIRAST").u8(0).u32(0).raw(page).raw(page).bytes()
        val sink = CollectingSink()
        RasterDecoder.decode(ByteArrayInputStream(doc), sink)
        assertEquals(2, sink.pages.size)
        assertEquals(PixelFormat.GRAY_8, sink.pages[0].first.pixelFormat)
        assertArrayEquals(byteArrayOf(0x00, 0x80.toByte(), 0xFF.toByte()), sink.pages[1].second[0])
    }

    @Test
    fun syntheticPwgBlackAndWhiteAndGray() {
        val doc = Bytes().ascii("RaS2")
            // page 1: 10x2 W 1-bit (1 = white). bytesPerLine 2.
            .raw(pwgHeader(10, 2, 300, 300, 1, 1, 0, 1))
            // line 0: literal [0b10110000, 0b11000000]
            .u8(0).u8(0xFF).u8(0xB0, 0xC0)
            // line 1: 0x80 fill => white => all 0 in BLACK_1
            .u8(0).u8(0x80)
            // page 2: 10x1 K 1-bit (1 = black), repeat 0xA5 x2
            .raw(pwgHeader(10, 1, 600, 300, 1, 1, 3, 1))
            .u8(0).u8(1).u8(0xA5)
            // page 3: 3x2 K 8-bit (255 = black): line literal [0, 128, 255] x2 rows
            .raw(pwgHeader(3, 2, 300, 300, 8, 8, 3, 1))
            .u8(1).u8(0xFE).u8(0x00, 0x80, 0xFF)
            .bytes()
        val sink = CollectingSink()
        RasterDecoder.decode(ByteArrayInputStream(doc), sink)
        assertEquals(3, sink.pages.size)

        assertEquals(RasterPageInfo(10, 2, 300, 300, PixelFormat.BLACK_1), sink.pages[0].first)
        // inverted 0xB0 -> 0x4F, 0xC0 -> 0x3F, then padding (6 bits) masked to 0 -> 0x00
        assertArrayEquals(byteArrayOf(0x4F, 0x00), sink.pages[0].second[0])
        assertArrayEquals(byteArrayOf(0x00, 0x00), sink.pages[0].second[1])

        assertEquals(RasterPageInfo(10, 1, 600, 300, PixelFormat.BLACK_1), sink.pages[1].first)
        assertArrayEquals(byteArrayOf(0xA5.toByte(), 0x80.toByte()), sink.pages[1].second[0])

        assertEquals(RasterPageInfo(3, 2, 300, 300, PixelFormat.GRAY_8), sink.pages[2].first)
        sink.pages[2].second.forEach { assertArrayEquals(byteArrayOf(0xFF.toByte(), 0x7F, 0x00), it) }
    }

    @Test
    fun syntheticPwgCmykAnd16Bit() {
        val doc = Bytes().ascii("RaS2")
            // 2x1 CMYK 8-bit: literal [c=255 m0 y0 k0], [0 0 0 k=255]
            .raw(pwgHeader(2, 1, 300, 300, 8, 32, 6, 4))
            .u8(0).u8(0xFF).u8(255, 0, 0, 0, 0, 0, 0, 255)
            // 2x1 sRGB 16-bit: repeat pixel (0x12 0x34, 0x56 0x78, 0x9A 0xBC) x2
            .raw(pwgHeader(2, 1, 300, 300, 16, 48, 19, 3))
            .u8(0).u8(1).u8(0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC)
            .bytes()
        val sink = CollectingSink()
        RasterDecoder.decode(ByteArrayInputStream(doc), sink)
        assertEquals(PixelFormat.RGB_24, sink.pages[0].first.pixelFormat)
        assertArrayEquals(rgb(0x00FFFF, 0x000000), sink.pages[0].second[0])
        assertArrayEquals(rgb(0x12569A, 0x12569A), sink.pages[1].second[0])
    }

    @Test
    fun malformedInputsThrow() {
        fun assertThrows(doc: ByteArray) {
            try {
                RasterDecoder.decode(ByteArrayInputStream(doc), CollectingSink())
                fail("expected RasterFormatException")
            } catch (_: RasterFormatException) {
            }
        }
        assertThrows("garbage!".toByteArray())
        assertThrows("RaS".toByteArray())
        // unsupported URF bpp
        assertThrows(Bytes().ascii("UNIRAST").u8(0).u32(1).raw(urfPageHeader(16, 1, 2, 1, 300)).u8(0, 0x80).bytes())
        // unsupported PWG color space (2 = RGBA)
        assertThrows(Bytes().ascii("RaS2").raw(pwgHeader(2, 1, 300, 300, 8, 32, 2, 4)).u8(0, 0x80).bytes())
        // run overflow: repeat 3 pixels into a 2px line
        assertThrows(Bytes().ascii("RaS2").raw(pwgHeader(2, 1, 300, 300, 8, 8, 18, 1)).u8(0, 2, 0).bytes())
        // page count says 2 but only 1 present
        assertThrows(Bytes().ascii("UNIRAST").u8(0).u32(2).raw(urfPageHeader(8, 0, 1, 1, 300)).u8(0, 0, 7).bytes())
        // truncated PWG header
        assertThrows(Bytes().ascii("RaS2").raw(ByteArray(100)).bytes())
    }

    @Test
    fun fixtureRgbUrf() {
        val sink = StatsSink(keepFirstPage = true)
        fixture("a4-rgb-1page.urf.gz").use { RasterDecoder.decode(it, sink) }
        assertEquals(1, sink.infos.size)
        assertEquals(RasterPageInfo(2479, 3508, 300, 300, PixelFormat.RGB_24), sink.infos[0])
        assertEquals(3508, sink.rowCounts[0])
        assertTextPage(sink.nonWhiteFraction(0))
        writePng(sink.infos[0], sink.firstPage!!, File(SCRATCH, "decoded-a4.png"))
    }

    @Test
    fun fixtureRgbPwg() {
        val sink = StatsSink(keepFirstPage = true)
        fixture("a4-rgb-1page.pwg.gz").use { RasterDecoder.decode(it, sink) }
        assertEquals(1, sink.infos.size)
        assertEquals(RasterPageInfo(2479, 3508, 300, 300, PixelFormat.RGB_24), sink.infos[0])
        assertEquals(3508, sink.rowCounts[0])
        assertTextPage(sink.nonWhiteFraction(0))
        writePng(sink.infos[0], sink.firstPage!!, File(SCRATCH, "decoded-a4-pwg.png"))
    }

    @Test
    fun fixtureMonoPwgTwoPages() {
        val sink = StatsSink(keepFirstPage = true)
        fixture("a4-mono-2pages.pwg.gz").use { RasterDecoder.decode(it, sink) }
        assertEquals(2, sink.infos.size)
        for (i in 0..1) {
            assertEquals(RasterPageInfo(2479, 3508, 300, 300, PixelFormat.BLACK_1), sink.infos[i])
            assertEquals(3508, sink.rowCounts[i])
            assertTextPage(sink.nonWhiteFraction(i))
        }
        writePng(sink.infos[0], sink.firstPage!!, File(SCRATCH, "decoded-mono.png"))
    }

    @Test
    fun fixtureGrayPhotoUrf() {
        val sink = StatsSink(keepFirstPage = true)
        fixture("photo-gray.urf.gz").use { RasterDecoder.decode(it, sink) }
        assertEquals(1, sink.infos.size)
        val info = sink.infos[0]
        writePng(info, sink.firstPage!!, File(SCRATCH, "decoded-photo.png"))
        assertEquals(PixelFormat.GRAY_8, info.pixelFormat)
        assertEquals(RasterPageInfo(2479, 3508, 300, 300, PixelFormat.GRAY_8), info)
        assertEquals(info.heightPx, sink.rowCounts[0])
        // The fixture is a photo centered on an otherwise white A4 page (whole-page mean is ~233),
        // so the mean-gray plausibility check is applied to the central 20% x 20% region, which
        // lies entirely inside the photo.
        val rows = sink.firstPage!!
        val x0 = info.widthPx * 2 / 5; val x1 = info.widthPx * 3 / 5
        val y0 = info.heightPx * 2 / 5; val y1 = info.heightPx * 3 / 5
        var sum = 0L
        for (y in y0 until y1) for (x in x0 until x1) sum += rows[y][x].toInt() and 0xFF
        val mean = sum.toDouble() / ((x1 - x0).toLong() * (y1 - y0))
        assertTrue("central mean gray $mean", mean in 40.0..215.0)
        val pageMean = sink.graySum[0].toDouble() / (info.widthPx.toLong() * info.heightPx)
        assertTrue("page mean gray $pageMean", pageMean < 250.0)
        assertTrue("rows all identical", sink.distinctRowHashes[0].size > 1)
    }

    @Test
    fun truncatedFixtureThrows() {
        val head = fixture("a4-rgb-1page.urf.gz").use { s ->
            val buf = ByteArray(100 * 1024)
            var n = 0
            while (n < buf.size) { val r = s.read(buf, n, buf.size - n); if (r < 0) break; n += r }
            buf.copyOf(n)
        }
        val sink = StatsSink()
        try {
            RasterDecoder.decode(ByteArrayInputStream(head), sink)
            fail("expected RasterFormatException")
        } catch (_: RasterFormatException) {
        }
        assertEquals(1, sink.infos.size)
        assertTrue(sink.rowCounts[0] < 3508)
    }

    private fun assertTextPage(fraction: Double) {
        assertTrue("non-white fraction $fraction", fraction in 0.005..0.25)
    }

    /** Visual sanity output (not an assertion): 1/4 downscale RGB PNG, hand-encoded (no java.awt on the Android test classpath). */
    private fun writePng(info: RasterPageInfo, rows: List<ByteArray>, file: File) {
        if (!file.parentFile.isDirectory) return
        val scale = 4
        val w = info.widthPx / scale
        val h = info.heightPx / scale
        val raw = ByteArrayOutputStream()
        DeflaterOutputStream(raw).use { z ->
            val line = ByteArray(1 + w * 3)
            for (y in 0 until h) {
                val row = rows[y * scale]
                for (x in 0 until w) {
                    val sx = x * scale
                    val c = when (info.pixelFormat) {
                        PixelFormat.BLACK_1 -> if ((row[sx / 8].toInt() shr (7 - sx % 8)) and 1 == 1) 0 else 0xFFFFFF
                        PixelFormat.GRAY_8 -> (row[sx].toInt() and 0xFF) * 0x010101
                        PixelFormat.RGB_24 -> ((row[sx * 3].toInt() and 0xFF) shl 16) or
                            ((row[sx * 3 + 1].toInt() and 0xFF) shl 8) or (row[sx * 3 + 2].toInt() and 0xFF)
                    }
                    line[1 + x * 3] = (c shr 16).toByte(); line[2 + x * 3] = (c shr 8).toByte(); line[3 + x * 3] = c.toByte()
                }
                z.write(line)
            }
        }
        val png = ByteArrayOutputStream()
        png.write(byteArrayOf(0x89.toByte(), 'P'.code.toByte(), 'N'.code.toByte(), 'G'.code.toByte(), 13, 10, 26, 10))
        fun chunk(type: String, data: ByteArray) {
            val t = type.toByteArray(Charsets.US_ASCII)
            png.write(Bytes().u32(data.size.toLong()).bytes())
            png.write(t); png.write(data)
            val crc = CRC32().apply { update(t); update(data) }
            png.write(Bytes().u32(crc.value).bytes())
        }
        chunk("IHDR", Bytes().u32(w.toLong()).u32(h.toLong()).u8(8, 2, 0, 0, 0).bytes())
        chunk("IDAT", raw.toByteArray())
        chunk("IEND", ByteArray(0))
        file.writeBytes(png.toByteArray())
    }

    companion object {
        private val SCRATCH = File("/private/tmp/claude-502/-Users-tsumori-labo-imprima/6981ed8a-48ee-456d-b11a-413bc8ce5277/scratchpad")
    }
}
