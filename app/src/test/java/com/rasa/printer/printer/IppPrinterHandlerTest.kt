package com.rasa.printer.printer

import com.rasa.printer.ipp.IppAttribute
import com.rasa.printer.ipp.IppGroup
import com.rasa.printer.ipp.IppMessage
import com.rasa.printer.ipp.IppOperation
import com.rasa.printer.ipp.IppStatus
import com.rasa.printer.ipp.IppTag
import com.rasa.printer.ipp.IppValue
import java.io.ByteArrayInputStream
import java.io.InputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class IppPrinterHandlerTest {
    private val printerUri = "ipp://192.168.1.5:8631/ipp/print"
    private val config = PrinterConfig(name = "Rasa Test", uuid = "1234-5678", location = "Desk")
    private var now = 1_700_000_000_000L
    private lateinit var store: InMemoryJobStore
    private lateinit var handler: IppPrinterHandler
    private var requestId = 1

    @Before
    fun setUp() {
        store = InMemoryJobStore(clock = { now })
        handler = IppPrinterHandler({ config }, store, { now })
    }

    // ---------------------------------------------------------------- helpers

    private fun request(op: Int, vararg attrs: IppAttribute, charset: Boolean = true, major: Int = 2, minor: Int = 0): IppMessage {
        val base = if (charset) listOf(
            IppAttribute("attributes-charset", IppValue.Charset("utf-8")),
            IppAttribute("attributes-natural-language", IppValue.NaturalLanguage("en")),
            IppAttribute("printer-uri", IppValue.Uri(printerUri)),
        ) else listOf(IppAttribute("printer-uri", IppValue.Uri(printerUri)))
        return IppMessage(op, requestId++, listOf(IppGroup(IppTag.OPERATION_ATTRIBUTES, base + attrs)), major, minor)
    }

    private fun kw(name: String, vararg v: String) = IppAttribute(name, v.map { IppValue.Keyword(it) })
    private fun mime(v: String) = IppAttribute("document-format", IppValue.MimeMediaType(v))
    private fun jobId(id: Int) = IppAttribute("job-id", IppValue.Integer(id))
    private fun lastDoc(v: Boolean) = IppAttribute("last-document", IppValue.Bool(v))
    private fun bytes(s: String) = s.toByteArray(Charsets.ISO_8859_1)
    private fun body(b: ByteArray): InputStream = ByteArrayInputStream(b)
    private val empty: InputStream get() = ByteArrayInputStream(ByteArray(0))

    private fun send(req: IppMessage, doc: InputStream = empty): IppMessage {
        val resp = handler.handle(req, doc, printerUri)
        assertEquals(req.requestId, resp.requestId)
        if (req.versionMajor == 1 || req.versionMajor == 2) {
            assertEquals(req.versionMajor, resp.versionMajor)
            assertEquals(req.versionMinor, resp.versionMinor)
        } else {
            assertEquals(2, resp.versionMajor)
            assertEquals(0, resp.versionMinor)
        }
        val op = resp.groups.first()
        assertEquals(IppTag.OPERATION_ATTRIBUTES, op.tag)
        assertEquals("utf-8", op["attributes-charset"]?.stringValue)
        assertEquals("en", op["attributes-natural-language"]?.stringValue)
        return resp
    }

    private fun printerAttrs(vararg requested: String): IppGroup {
        val attrs = if (requested.isEmpty()) emptyArray() else arrayOf(kw("requested-attributes", *requested))
        val resp = send(request(IppOperation.GET_PRINTER_ATTRIBUTES, *attrs))
        assertEquals(IppStatus.OK, resp.code)
        return resp.group(IppTag.PRINTER_ATTRIBUTES)!!
    }

    private fun createJob(user: String = "alice"): Int {
        val resp = send(request(IppOperation.CREATE_JOB, IppAttribute("requesting-user-name", IppValue.Name(user))))
        assertEquals(IppStatus.OK, resp.code)
        return resp.jobAttributes!!["job-id"]!!.intValue!!
    }

    private fun printPdf(): Int {
        val resp = send(request(IppOperation.PRINT_JOB, mime("application/pdf")), body(bytes("%PDF-1.4 x")))
        assertEquals(IppStatus.OK, resp.code)
        return resp.jobAttributes!!["job-id"]!!.intValue!!
    }

    // ---------------------------------------------------------------- Get-Printer-Attributes

    @Test
    fun getPrinterAttributesAll() {
        val g = printerAttrs()
        assertEquals(printerUri, g["printer-uri-supported"]?.stringValue)
        val ops = g["operations-supported"]!!.values.map { it.intValue }
        listOf(
            IppOperation.PRINT_JOB, IppOperation.VALIDATE_JOB, IppOperation.CREATE_JOB, IppOperation.SEND_DOCUMENT,
            IppOperation.CANCEL_JOB, IppOperation.GET_JOB_ATTRIBUTES, IppOperation.GET_JOBS,
            IppOperation.GET_PRINTER_ATTRIBUTES, IppOperation.CLOSE_JOB, IppOperation.IDENTIFY_PRINTER,
        ).forEach { assertTrue("op $it", it in ops) }
        val formats = g["document-format-supported"]!!.stringValues
        assertTrue(formats.containsAll(listOf("application/pdf", "image/pwg-raster", "image/urf")))
        assertTrue("V1.4" in g["urf-supported"]!!.stringValues)
        assertNotNull(g["media-col-database"])
        assertEquals("urn:uuid:1234-5678", g["printer-uuid"]?.stringValue)
        assertEquals("http://192.168.1.5:8631/icon.png", g["printer-icons"]?.stringValue)
        assertEquals("http://192.168.1.5:8631/", g["printer-more-info"]?.stringValue)
        assertEquals(listOf("ipp-everywhere"), g["ipp-features-supported"]?.stringValues)
        assertEquals(11, (g["printer-current-time"]!!.value as IppValue.DateTime).value.size)
        // names unique
        val names = g.attributes.map { it.name }
        assertEquals(names.size, names.toSet().size)
    }

    @Test
    fun getPrinterAttributesExplicitAll() {
        assertNotNull(printerAttrs("all")["media-col-database"])
    }

    @Test
    fun printerDescriptionExcludesMediaColDatabase() {
        val g = printerAttrs("printer-description")
        assertNull(g["media-col-database"])
        assertNotNull(g["printer-uri-supported"])
        assertNull(g["media-default"]) // job-template, not description
    }

    @Test
    fun mediaColDatabaseByName() {
        val g = printerAttrs("media-col-database")
        assertEquals(listOf("media-col-database"), g.attributes.map { it.name })
        assertEquals(5, g["media-col-database"]!!.values.size)
    }

    @Test
    fun jobTemplateGroupAndUnknownNames() {
        val g = printerAttrs("job-template", "printer-name", "no-such-attribute")
        assertNotNull(g["media-col-default"])
        assertNotNull(g["copies-supported"])
        assertNotNull(g["printer-name"])
        assertNull(g["printer-uri-supported"])
        assertNull(g["media-col-database"])
    }

    // ---------------------------------------------------------------- Print-Job

    @Test
    fun printJobPdf() {
        val doc = bytes("%PDF-1.4\n%âã body bytes \u0000ÿ end")
        val resp = send(
            request(
                IppOperation.PRINT_JOB, mime("application/pdf"),
                IppAttribute("requesting-user-name", IppValue.Name("bob")),
                IppAttribute("job-name", IppValue.Name("report.pdf")),
            ),
            body(doc),
        )
        assertEquals(IppStatus.OK, resp.code)
        val job = resp.jobAttributes!!
        assertEquals(1, job["job-id"]?.intValue)
        assertEquals(9, job["job-state"]?.intValue)
        assertEquals("$printerUri/1", job["job-uri"]?.stringValue)
        val stored = store.list().single()
        assertEquals(JobState.COMPLETED, stored.state)
        assertEquals("application/pdf", stored.format)
        assertEquals("bob", stored.userName)
        assertEquals("report.pdf", stored.name)
        assertArrayEquals(doc, store.document(1))
        assertArrayEquals(doc, stored.file!!.readBytes())
    }

    @Test
    fun printJobDefaultsNames() {
        printPdf()
        val j = store.get(1)!!
        assertEquals("anonymous", j.userName)
        assertEquals("Untitled", j.name)
    }

    @Test
    fun printJobSniffsPwgRasterWithoutLosingBytes() {
        val doc = bytes("RaS2PwgRaster\u0000\u0001\u0002 rest of raster data")
        val resp = send(request(IppOperation.PRINT_JOB), body(doc))
        assertEquals(IppStatus.OK, resp.code)
        assertEquals("image/pwg-raster", store.get(1)!!.format)
        assertArrayEquals(doc, store.document(1))
    }

    @Test
    fun printJobSniffsOctetStreamAndShortBodies() {
        send(request(IppOperation.PRINT_JOB, mime("application/octet-stream")), body(bytes("UNIRAST\u0000xyz")))
        assertEquals("image/urf", store.get(1)!!.format)
        send(request(IppOperation.PRINT_JOB), body(byteArrayOf(0xFF.toByte(), 0xD8.toByte())))
        assertEquals("image/jpeg", store.get(2)!!.format)
        assertArrayEquals(byteArrayOf(0xFF.toByte(), 0xD8.toByte()), store.document(2))
        send(request(IppOperation.PRINT_JOB), body(bytes("hi")))
        assertEquals("application/octet-stream", store.get(3)!!.format)
        assertArrayEquals(bytes("hi"), store.document(3))
    }

    @Test
    fun printJobUnsupportedFormat() {
        val resp = send(request(IppOperation.PRINT_JOB, mime("application/vnd.foo")), body(bytes("xx")))
        assertEquals(IppStatus.CLIENT_ERROR_DOCUMENT_FORMAT_NOT_SUPPORTED, resp.code)
        assertNotNull(resp.operationAttributes!!["status-message"])
        assertTrue(store.list().isEmpty())
    }

    @Test
    fun printJobCompressionNotSupported() {
        val resp = send(request(IppOperation.PRINT_JOB, kw("compression", "gzip")), body(bytes("%PDF")))
        assertEquals(IppStatus.CLIENT_ERROR_COMPRESSION_NOT_SUPPORTED, resp.code)
        assertTrue(store.list().isEmpty())
    }

    @Test
    fun printJobStorageFailure() {
        store.failWrites = true
        val resp = send(request(IppOperation.PRINT_JOB, mime("application/pdf")), body(bytes("%PDF")))
        assertEquals(IppStatus.SERVER_ERROR_INTERNAL_ERROR, resp.code)
        assertEquals(JobState.ABORTED, store.get(1)!!.state)
    }

    @Test
    fun validateJob() {
        assertEquals(IppStatus.OK, send(request(IppOperation.VALIDATE_JOB, mime("image/urf"))).code)
        assertNull(send(request(IppOperation.VALIDATE_JOB)).jobAttributes)
        assertEquals(
            IppStatus.CLIENT_ERROR_DOCUMENT_FORMAT_NOT_SUPPORTED,
            send(request(IppOperation.VALIDATE_JOB, mime("text/plain"))).code,
        )
        assertTrue(store.list().isEmpty())
    }

    // ---------------------------------------------------------------- Create-Job / Send-Document

    @Test
    fun createSendGet() {
        val id = createJob()
        assertEquals(JobState.PENDING, store.get(id)!!.state)

        val doc = bytes("%PDF-1.7 hello")
        val sendResp = send(request(IppOperation.SEND_DOCUMENT, jobId(id), lastDoc(true)), body(doc))
        assertEquals(IppStatus.OK, sendResp.code)
        assertEquals(9, sendResp.jobAttributes!!["job-state"]?.intValue)
        assertEquals(JobState.COMPLETED, store.get(id)!!.state)
        assertArrayEquals(doc, store.document(id))

        val get = send(request(IppOperation.GET_JOB_ATTRIBUTES, jobId(id)))
        assertEquals(IppStatus.OK, get.code)
        val g = get.jobAttributes!!
        assertEquals(9, g["job-state"]?.intValue)
        assertEquals("application/pdf", g["document-format"]?.stringValue)
        assertEquals("job-completed-successfully", g["job-state-reasons"]?.stringValue)
        assertEquals("alice", g["job-originating-user-name"]?.stringValue)
        assertEquals(printerUri, g["job-printer-uri"]?.stringValue)
        assertEquals(1, g["job-k-octets"]?.intValue)
        assertEquals((now / 1000).toInt(), g["time-at-completed"]?.intValue)
        assertEquals(11, (g["date-time-at-creation"]!!.value as IppValue.DateTime).value.size)

        val again = send(request(IppOperation.SEND_DOCUMENT, jobId(id), lastDoc(true)))
        assertEquals(IppStatus.OK, again.code)
        assertArrayEquals(doc, store.document(id))

        val notPossible = send(request(IppOperation.SEND_DOCUMENT, jobId(id), lastDoc(true)), body(bytes("%PDF more")))
        assertEquals(IppStatus.CLIENT_ERROR_NOT_POSSIBLE, notPossible.code)
    }

    @Test
    fun sendDocumentByJobUriAndLastDocumentFalse() {
        val id = createJob()
        val doc = bytes("\u0089PNG\r\n\u001a\n...")
        val resp = send(
            request(IppOperation.SEND_DOCUMENT, IppAttribute("job-uri", IppValue.Uri("$printerUri/$id")), lastDoc(false)),
            body(doc),
        )
        assertEquals(IppStatus.OK, resp.code)
        assertEquals("image/png", store.get(id)!!.format)
        assertArrayEquals(doc, store.document(id))
    }

    @Test
    fun sendDocumentUnknownJob() {
        assertEquals(IppStatus.CLIENT_ERROR_NOT_FOUND, send(request(IppOperation.SEND_DOCUMENT, jobId(42), lastDoc(true))).code)
        assertEquals(IppStatus.CLIENT_ERROR_BAD_REQUEST, send(request(IppOperation.SEND_DOCUMENT, lastDoc(true))).code)
    }

    @Test
    fun getJobAttributesFiltered() {
        val id = printPdf()
        val g = send(request(IppOperation.GET_JOB_ATTRIBUTES, jobId(id), kw("requested-attributes", "job-state", "job-name"))).jobAttributes!!
        assertEquals(setOf("job-state", "job-name"), g.attributes.map { it.name }.toSet())
        assertEquals(IppStatus.CLIENT_ERROR_NOT_FOUND, send(request(IppOperation.GET_JOB_ATTRIBUTES, jobId(99))).code)
    }

    @Test
    fun closeJob() {
        val id = createJob()
        val resp = send(request(IppOperation.CLOSE_JOB, jobId(id)))
        assertEquals(IppStatus.OK, resp.code)
        assertEquals(JobState.PENDING, store.get(id)!!.state)
    }

    // ---------------------------------------------------------------- Cancel-Job

    @Test
    fun cancelJob() {
        val done = printPdf()
        assertEquals(IppStatus.CLIENT_ERROR_NOT_POSSIBLE, send(request(IppOperation.CANCEL_JOB, jobId(done))).code)
        assertEquals(JobState.COMPLETED, store.get(done)!!.state)

        val pending = createJob()
        assertEquals(IppStatus.OK, send(request(IppOperation.CANCEL_JOB, jobId(pending))).code)
        assertEquals(JobState.CANCELED, store.get(pending)!!.state)
        assertEquals(IppStatus.CLIENT_ERROR_NOT_FOUND, send(request(IppOperation.CANCEL_JOB, jobId(77))).code)
    }

    // ---------------------------------------------------------------- Get-Jobs

    @Test
    fun getJobsCompleted() {
        val a = printPdf()
        val pending = createJob()
        val b = printPdf()
        val c = printPdf()

        val resp = send(request(IppOperation.GET_JOBS, kw("which-jobs", "completed")))
        assertEquals(IppStatus.OK, resp.code)
        val groups = resp.groups.filter { it.tag == IppTag.JOB_ATTRIBUTES }
        assertEquals(listOf(c, b, a), groups.map { it["job-id"]!!.intValue })
        groups.forEach { assertEquals(listOf("job-id", "job-uri"), it.attributes.map { a -> a.name }) }

        val limited = send(request(IppOperation.GET_JOBS, kw("which-jobs", "completed"), IppAttribute("limit", IppValue.Integer(2))))
        assertEquals(listOf(c, b), limited.groups.filter { it.tag == IppTag.JOB_ATTRIBUTES }.map { it["job-id"]!!.intValue })

        val notCompleted = send(request(IppOperation.GET_JOBS))
        assertEquals(listOf(pending), notCompleted.groups.drop(1).map { it["job-id"]!!.intValue })

        val all = send(request(IppOperation.GET_JOBS, kw("which-jobs", "all"), kw("requested-attributes", "all")))
        assertEquals(4, all.groups.size - 1)
        assertNotNull(all.groups[1]["job-state"])
    }

    @Test
    fun getJobsEmptyAndMyJobs() {
        val empty = send(request(IppOperation.GET_JOBS))
        assertEquals(IppStatus.OK, empty.code)
        assertEquals(1, empty.groups.size)

        createJob("alice")
        createJob("bob")
        val mine = send(
            request(
                IppOperation.GET_JOBS, IppAttribute("my-jobs", IppValue.Bool(true)),
                IppAttribute("requesting-user-name", IppValue.Name("bob")),
            ),
        )
        assertEquals(listOf(2), mine.groups.drop(1).map { it["job-id"]!!.intValue })
    }

    // ---------------------------------------------------------------- errors

    @Test
    fun unknownOperation() {
        assertEquals(IppStatus.SERVER_ERROR_OPERATION_NOT_SUPPORTED, send(request(0x0099)).code)
        assertEquals(IppStatus.SERVER_ERROR_OPERATION_NOT_SUPPORTED, send(request(IppOperation.PAUSE_PRINTER)).code)
        assertEquals(IppStatus.SERVER_ERROR_OPERATION_NOT_SUPPORTED, send(request(IppOperation.CUPS_GET_PRINTERS)).code)
    }

    @Test
    fun missingCharset() {
        assertEquals(IppStatus.CLIENT_ERROR_BAD_REQUEST, send(request(IppOperation.GET_PRINTER_ATTRIBUTES, charset = false)).code)
        val noGroups = IppMessage(IppOperation.GET_PRINTER_ATTRIBUTES, 5, emptyList())
        assertEquals(IppStatus.CLIENT_ERROR_BAD_REQUEST, send(noGroups).code)
    }

    @Test
    fun unsupportedVersion() {
        val resp = send(request(IppOperation.GET_PRINTER_ATTRIBUTES, major = 3))
        assertEquals(IppStatus.SERVER_ERROR_VERSION_NOT_SUPPORTED, resp.code)
        assertFalse(resp.groups.any { it.tag == IppTag.PRINTER_ATTRIBUTES })
    }

    @Test
    fun identifyPrinter() {
        assertEquals(IppStatus.OK, send(request(IppOperation.IDENTIFY_PRINTER)).code)
    }

    @Test
    fun responseEchoesSupportedRequestVersion() {
        val v11 = send(request(IppOperation.GET_PRINTER_ATTRIBUTES, major = 1, minor = 1))
        assertEquals(IppStatus.OK, v11.code)
        assertEquals(1 to 1, v11.versionMajor to v11.versionMinor)

        val v20 = send(request(IppOperation.GET_PRINTER_ATTRIBUTES))
        assertEquals(IppStatus.OK, v20.code)
        assertEquals(2 to 0, v20.versionMajor to v20.versionMinor)

        // errors on a supported version still echo it
        val err11 = send(request(0x0099, major = 1, minor = 1))
        assertEquals(1 to 1, err11.versionMajor to err11.versionMinor)

        val v30 = send(request(IppOperation.GET_PRINTER_ATTRIBUTES, major = 3))
        assertEquals(IppStatus.SERVER_ERROR_VERSION_NOT_SUPPORTED, v30.code)
        assertEquals(2 to 0, v30.versionMajor to v30.versionMinor)
    }

    @Test
    fun requestIdZeroIsBadRequest() {
        val resp = send(request(IppOperation.GET_PRINTER_ATTRIBUTES).copy(requestId = 0))
        assertEquals(IppStatus.CLIENT_ERROR_BAD_REQUEST, resp.code)
        assertNull(resp.group(IppTag.PRINTER_ATTRIBUTES))
    }

    @Test
    fun charsetAndLanguageMustComeFirstInOrder() {
        val swapped = IppMessage(
            IppOperation.GET_PRINTER_ATTRIBUTES, 9,
            listOf(
                IppGroup(
                    IppTag.OPERATION_ATTRIBUTES,
                    listOf(
                        IppAttribute("attributes-natural-language", IppValue.NaturalLanguage("en")),
                        IppAttribute("attributes-charset", IppValue.Charset("utf-8")),
                        IppAttribute("printer-uri", IppValue.Uri(printerUri)),
                    ),
                ),
            ),
        )
        assertEquals(IppStatus.CLIENT_ERROR_BAD_REQUEST, send(swapped).code)
    }

    @Test
    fun missingPrinterUriIsBadRequest() {
        val req = request(IppOperation.GET_PRINTER_ATTRIBUTES)
        val noUri = req.copy(groups = listOf(IppGroup(IppTag.OPERATION_ATTRIBUTES, req.groups[0].attributes.filter { it.name != "printer-uri" })))
        val resp = send(noUri)
        assertEquals(IppStatus.CLIENT_ERROR_BAD_REQUEST, resp.code)
        assertNull(resp.group(IppTag.PRINTER_ATTRIBUTES))
    }

    @Test
    fun sendDocumentRequiresLastDocument() {
        val id = createJob()
        assertEquals(IppStatus.CLIENT_ERROR_BAD_REQUEST, send(request(IppOperation.SEND_DOCUMENT, jobId(id)), body(bytes("%PDF"))).code)
        assertEquals(JobState.PENDING, store.get(id)!!.state)
    }

    @Test
    fun cancelMyJobsByUser() {
        val done = printPdf() // anonymous, completed
        val a1 = createJob("alice")
        val b1 = createJob("bob")
        val a2 = createJob("alice")
        val g = printerAttrs("operations-supported")
        assertTrue(0x0039 in g["operations-supported"]!!.values.map { it.intValue })

        val resp = send(request(0x0039, IppAttribute("requesting-user-name", IppValue.Name("alice"))))
        assertEquals(IppStatus.OK, resp.code)
        assertEquals(JobState.CANCELED, store.get(a1)!!.state)
        assertEquals(JobState.CANCELED, store.get(a2)!!.state)
        assertEquals(JobState.PENDING, store.get(b1)!!.state)
        assertEquals(JobState.COMPLETED, store.get(done)!!.state)
    }

    @Test
    fun cancelMyJobsByJobIds() {
        val a = createJob("alice")
        val b = createJob("alice")
        val done = printPdf()
        val ids = IppAttribute("job-ids", IppValue.Integer(a), IppValue.Integer(done))
        val resp = send(request(0x0039, IppAttribute("requesting-user-name", IppValue.Name("alice")), ids))
        assertEquals(IppStatus.OK, resp.code)
        assertEquals(JobState.CANCELED, store.get(a)!!.state)
        assertEquals(JobState.PENDING, store.get(b)!!.state)
        assertEquals(JobState.COMPLETED, store.get(done)!!.state)
        val missing = IppAttribute("job-ids", IppValue.Integer(99))
        assertEquals(IppStatus.CLIENT_ERROR_NOT_FOUND, send(request(0x0039, missing)).code)
    }

    @Test
    fun everywhereRequiredAttributes() {
        val g = printerAttrs("all", "media-col-database")
        listOf(
            "finishings-default", "finishings-supported", "pages-per-minute", "pages-per-minute-color",
            "preferred-attributes-supported", "multiple-operation-time-out-action", "overrides-supported",
            "print-content-optimize-default", "print-content-optimize-supported", "print-rendering-intent-default",
            "print-rendering-intent-supported", "printer-config-change-date-time", "printer-config-change-time",
            "printer-get-attributes-supported", "printer-state-change-date-time", "printer-state-change-time",
            "printer-supply", "printer-supply-description", "printer-supply-info-uri",
        ).forEach { assertNotNull(it, g[it]) }
        assertTrue(g["printer-supply"]!!.value is IppValue.OctetString)
        assertEquals(true, (g["page-ranges-supported"]!!.value as IppValue.Bool).value)
        assertEquals((now / 1000).toInt(), g["printer-config-change-time"]?.intValue)
        assertEquals("http://192.168.1.5:8631/", g["printer-supply-info-uri"]?.stringValue)
    }

    @Test
    fun internalErrorDoesNotThrow() {
        val broken = object : JobStore by store {
            override fun list(): List<PrintJob> = throw IllegalStateException("boom")
        }
        val h = IppPrinterHandler({ config }, broken, { now })
        val resp = h.handle(request(IppOperation.GET_JOBS), empty, printerUri)
        assertEquals(IppStatus.SERVER_ERROR_INTERNAL_ERROR, resp.code)
        assertNotNull(resp.operationAttributes!!["status-message"])
    }
}
