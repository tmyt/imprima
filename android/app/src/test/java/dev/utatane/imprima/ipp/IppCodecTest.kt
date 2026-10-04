package dev.utatane.imprima.ipp

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class IppCodecTest {
    private fun col(vararg members: IppAttribute) = IppValue.Collection(members.toList())

    private val dateBytes = ByteArray(11) { (it + 1).toByte() }
    private val octets = byteArrayOf(1, 2, 3, 0, -1)

    private val message = IppMessage(
        code = 0x0000, requestId = 42,
        groups = listOf(
            IppGroup(IppTag.OPERATION_ATTRIBUTES, listOf(
                IppAttribute("attributes-charset", IppValue.Charset("utf-8")),
                IppAttribute("attributes-natural-language", IppValue.NaturalLanguage("en")),
                IppAttribute("printer-uri", IppValue.Uri("ipp://localhost/ipp/print")),
                IppAttribute("document-format", IppValue.MimeMediaType("application/pdf")),
                IppAttribute("status-message", IppValue.Text("fine あ")),
            )),
            IppGroup(IppTag.JOB_ATTRIBUTES, emptyList()),
            IppGroup(IppTag.PRINTER_ATTRIBUTES, listOf(
                IppAttribute("copies-default", IppValue.Integer(-5)),
                IppAttribute("printer-is-accepting-jobs", IppValue.Bool(true)),
                IppAttribute("printer-state", IppValue.Enum(3)),
                IppAttribute("printer-info", IppValue.Text("hello", "en-us")),
                IppAttribute("printer-name", IppValue.Name("Imprima")),
                IppAttribute("printer-location", IppValue.Name("Desk", "en")),
                IppAttribute("blob", IppValue.OctetString(octets)),
                IppAttribute("printer-current-time", IppValue.DateTime(dateBytes)),
                IppAttribute("printer-resolution-default", IppValue.Resolution(600, 300, 3)),
                IppAttribute("copies-supported", IppValue.Range(1, 99)),
                IppAttribute("printer-uri-scheme", IppValue.UriScheme("ipp")),
                IppAttribute("media-ready", IppValue.OutOfBand(IppTag.NO_VALUE)),
                IppAttribute("sides-supported",
                    IppValue.Keyword("one-sided"), IppValue.Keyword("two-sided-long-edge"), IppValue.Keyword("two-sided-short-edge")),
                IppAttribute("media-col-database",
                    col(
                        IppAttribute("media-size", col(
                            IppAttribute("x-dimension", IppValue.Integer(21000)),
                            IppAttribute("y-dimension", IppValue.Integer(29700)),
                        )),
                        IppAttribute("media-type", IppValue.Keyword("stationery")),
                    ),
                    col(
                        IppAttribute("media-bottom-margin", IppValue.Integer(0)),
                        IppAttribute("media-source", IppValue.Keyword("main")),
                    ),
                ),
                IppAttribute("multi-member", col(
                    IppAttribute("sizes", IppValue.Integer(1), IppValue.Integer(2)),
                    IppAttribute("tail", IppValue.Keyword("x")),
                )),
                IppAttribute("odd", IppValue.Unknown(0x7F, byteArrayOf(9, 8))),
            )),
        ),
    )

    /** Data classes holding ByteArrays compare by reference, so verify via structure + re-encoding. */
    @Test
    fun roundTrip() {
        val bytes = IppCodec.encode(message)
        val decoded = IppCodec.decode(ByteArrayInputStream(bytes))
        assertEquals(message.code, decoded.code)
        assertEquals(message.requestId, decoded.requestId)
        assertEquals(message.groups.map { it.tag }, decoded.groups.map { it.tag })
        val printer = decoded.group(IppTag.PRINTER_ATTRIBUTES)!!
        val orig = message.group(IppTag.PRINTER_ATTRIBUTES)!!
        for (a in orig.attributes) {
            val got = printer[a.name]!!
            if (a.name == "blob") {
                assertArrayEquals(octets, (got.value as IppValue.OctetString).value)
            } else if (a.name == "printer-current-time") {
                assertArrayEquals(dateBytes, (got.value as IppValue.DateTime).value)
            } else if (a.name == "odd") {
                val u = got.value as IppValue.Unknown
                assertEquals(0x7F, u.tag)
                assertArrayEquals(byteArrayOf(9, 8), u.value)
            } else {
                assertEquals(a, got)
            }
        }
        assertEquals(message.group(IppTag.OPERATION_ATTRIBUTES), decoded.group(IppTag.OPERATION_ATTRIBUTES))
        assertEquals(IppGroup(IppTag.JOB_ATTRIBUTES, emptyList()), decoded.jobAttributes)
        assertEquals(3, printer["sides-supported"]!!.values.size)
        assertEquals(2, (printer["media-col-database"]!!.values).size)
        assertArrayEquals(bytes, IppCodec.encode(decoded))
    }

    @Test
    fun encodeToStreamMatchesByteArray() {
        val out = ByteArrayOutputStream()
        IppCodec.encode(message, out)
        assertArrayEquals(IppCodec.encode(message), out.toByteArray())
    }

    private fun bytes(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }
    private fun attr(tag: Int, name: String, value: ByteArray): ByteArray {
        val o = ByteArrayOutputStream()
        o.write(tag)
        o.write(name.length shr 8); o.write(name.length and 0xFF); o.write(name.toByteArray())
        o.write(value.size shr 8); o.write(value.size and 0xFF); o.write(value)
        return o.toByteArray()
    }

    @Test
    fun decodeGetPrinterAttributesLeavesTrailingBytes() {
        val o = ByteArrayOutputStream()
        o.write(bytes(0x02, 0x00, 0x00, 0x0B, 0, 0, 0, 1, 0x01))
        o.write(attr(0x47, "attributes-charset", "utf-8".toByteArray()))
        o.write(attr(0x48, "attributes-natural-language", "en".toByteArray()))
        o.write(attr(0x45, "printer-uri", "ipp://localhost/ipp/print".toByteArray()))
        o.write(attr(0x44, "requested-attributes", "all".toByteArray()))
        o.write(attr(0x44, "", "media-col-database".toByteArray()))
        o.write(0x03)
        o.write("DOC!".toByteArray())
        val input = ByteArrayInputStream(o.toByteArray())

        val m = IppCodec.decode(input)
        assertEquals(2, m.versionMajor)
        assertEquals(0, m.versionMinor)
        assertEquals(IppOperation.GET_PRINTER_ATTRIBUTES, m.code)
        assertEquals(1, m.requestId)
        val g = m.operationAttributes!!
        assertEquals(4, g.attributes.size)
        assertEquals("utf-8", g["attributes-charset"]!!.stringValue)
        assertEquals("en", g["attributes-natural-language"]!!.stringValue)
        assertEquals("ipp://localhost/ipp/print", g["printer-uri"]!!.stringValue)
        assertEquals(listOf("all", "media-col-database"), g["requested-attributes"]!!.stringValues)
        assertEquals(4, input.available())
        assertEquals("DOC!", String(input.readBytes()))
    }

    @Test
    fun truncatedInputThrows() {
        val full = IppCodec.encode(message)
        for (n in listOf(0, 3, 8, 9, 20, full.size - 1)) {
            try {
                IppCodec.decode(ByteArrayInputStream(full.copyOf(n)))
                fail("expected exception for length $n")
            } catch (e: IppDecodeException) {
                assertTrue(e.message!!.isNotEmpty())
            }
        }
    }

    @Test
    fun responseHeaderBytes() {
        val bytes = IppCodec.encode(IppMessage(IppStatus.OK, 1, emptyList()))
        assertArrayEquals(bytes(0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x03), bytes)
    }

    @Test
    fun endGroupIgnoredAndOversizeRejected() {
        val m = IppMessage(0, 1, listOf(IppGroup(IppTag.END_OF_ATTRIBUTES, emptyList())))
        assertEquals(9, IppCodec.encode(m).size)
        val big = IppMessage(0, 1, listOf(IppGroup(1, listOf(IppAttribute("a", IppValue.Keyword("x".repeat(70000)))))))
        try {
            IppCodec.encode(big)
            fail()
        } catch (_: IllegalArgumentException) {
        }
    }
}
