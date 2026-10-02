package com.rasa.printer.printer

import com.rasa.printer.http.HttpRequest
import com.rasa.printer.ipp.IppAttribute
import com.rasa.printer.ipp.IppCodec
import com.rasa.printer.ipp.IppGroup
import com.rasa.printer.ipp.IppMessage
import com.rasa.printer.ipp.IppOperation
import com.rasa.printer.ipp.IppStatus
import com.rasa.printer.ipp.IppTag
import com.rasa.printer.ipp.IppValue
import java.io.ByteArrayInputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class IppHttpHandlerTest {
    private var cfg = PrinterConfig(name = "Rasa <Office>", uuid = "abcd-ef", compatibilityMode = true)
    private val store = InMemoryJobStore()
    private var icon: ByteArray? = null
    private val http = IppHttpHandler(IppPrinterHandler({ cfg }, store), { cfg }, store, { icon })

    private fun req(method: String, path: String, contentType: String? = null, body: ByteArray = ByteArray(0), host: String? = "10.0.0.2:8631") =
        HttpRequest(
            method, path,
            buildMap {
                if (contentType != null) put("content-type", contentType)
                if (host != null) put("host", host)
            },
            ByteArrayInputStream(body),
        )

    private fun ippRequest(op: Int, vararg extra: IppAttribute) = IppMessage(
        op, 7,
        listOf(
            IppGroup(
                IppTag.OPERATION_ATTRIBUTES,
                listOf(
                    IppAttribute("attributes-charset", IppValue.Charset("utf-8")),
                    IppAttribute("attributes-natural-language", IppValue.NaturalLanguage("en")),
                    IppAttribute("printer-uri", IppValue.Uri("ipp://10.0.0.2:8631/ipp/print")),
                ) + extra,
            ),
        ),
    )

    @Test
    fun statusPage() {
        store.create("<script>", "u", "application/pdf")
        val r = http.handle(req("GET", "/"))
        assertEquals(200, r.status)
        assertTrue(r.contentType.startsWith("text/html"))
        val html = r.body.toString(Charsets.UTF_8)
        assertTrue(html.contains("Rasa &lt;Office&gt;"))
        assertTrue(html.contains("abcd-ef"))
        assertFalse(html.contains("<script>"))
        assertTrue(html.contains("Compatibility"))
        cfg = cfg.copy(compatibilityMode = false)
        assertTrue(http.handle(req("GET", "/")).body.toString(Charsets.UTF_8).contains("PDF-only"))
    }

    @Test
    fun icon() {
        assertEquals(404, http.handle(req("GET", "/icon.png")).status)
        icon = byteArrayOf(1, 2, 3)
        val r = http.handle(req("GET", "/icon.png"))
        assertEquals(200, r.status)
        assertEquals("image/png", r.contentType)
        assertArrayEquals(byteArrayOf(1, 2, 3), r.body)
    }

    @Test
    fun otherRoutes() {
        assertEquals(404, http.handle(req("GET", "/nope")).status)
        assertEquals(405, http.handle(req("PUT", "/")).status)
        assertEquals(415, http.handle(req("POST", "/ipp/print", "text/plain", byteArrayOf(1))).status)
        assertEquals(415, http.handle(req("POST", "/ipp/print", null)).status)
        assertEquals(400, http.handle(req("POST", "/ipp/print", "application/ipp", byteArrayOf(2, 0))).status)
    }

    @Test
    fun postGetPrinterAttributes() {
        val bytes = IppCodec.encode(ippRequest(IppOperation.GET_PRINTER_ATTRIBUTES))
        val r = http.handle(req("POST", "/", "Application/IPP; charset=utf-8", bytes))
        assertEquals(200, r.status)
        assertEquals("application/ipp", r.contentType)
        val resp = IppCodec.decode(ByteArrayInputStream(r.body))
        assertEquals(IppStatus.OK, resp.code)
        assertEquals(7, resp.requestId)
        assertEquals(
            "ipp://10.0.0.2:8631/ipp/print",
            resp.attr(IppTag.PRINTER_ATTRIBUTES, "printer-uri-supported")?.stringValue,
        )
    }

    @Test
    fun postPrintJobStreamsDocumentAndFallsBackHost() {
        val doc = "%PDF-1.4 document after attributes".toByteArray()
        val bytes = IppCodec.encode(ippRequest(IppOperation.PRINT_JOB)) + doc
        val r = http.handle(req("POST", "/ipp/print", "application/ipp", bytes, host = null))
        val resp = IppCodec.decode(ByteArrayInputStream(r.body))
        assertEquals(IppStatus.OK, resp.code)
        assertEquals("ipp://localhost:8631/ipp/print/1", resp.attr(IppTag.JOB_ATTRIBUTES, "job-uri")?.stringValue)
        assertEquals("application/pdf", store.get(1)!!.format)
        assertArrayEquals(doc, store.document(1))
    }
}
