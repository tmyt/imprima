package dev.utatane.imprima

import dev.utatane.imprima.http.HttpServer
import dev.utatane.imprima.printer.IppHttpHandler
import dev.utatane.imprima.printer.IppPrinterHandler
import dev.utatane.imprima.printer.JobState
import dev.utatane.imprima.printer.PrinterConfig
import dev.utatane.imprima.service.FileJobStore
import java.io.File
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test

/**
 * End-to-end check against CUPS' `ipptool` (present on macOS and most Linux distros).
 * Skipped when ipptool or its standard test files are not installed.
 */
class IpptoolIntegrationTest {
    private val ipptool = File("/usr/bin/ipptool")
    private val testDir = listOf("/usr/share/cups/ipptool", "/usr/share/cups/ipptool").map(::File).firstOrNull { it.isDirectory }

    private lateinit var dir: File
    private lateinit var store: FileJobStore
    private lateinit var server: HttpServer
    private lateinit var uri: String
    /** A small valid PDF generated per test: the CUPS sample documents are not shipped on every platform. */
    private lateinit var samplePdf: File
    /** Read per request by the handler; the conformance suites need compatibility mode (URF/PWG attributes). */
    @Volatile private var config = PrinterConfig(name = "Imprima Test Printer", port = 0, uuid = "12345678-1234-1234-1234-123456789abc", compatibilityMode = true)

    @Before
    fun setUp() {
        assumeTrue("ipptool not installed", ipptool.canExecute() && testDir != null)
        dir = createTempDir("imprima-ipptool")
        samplePdf = File(dir, "sample.pdf").apply { writeBytes(minimalPdf()) }
        store = FileJobStore(dir)
        val handler = IppPrinterHandler({ config }, store)
        server = HttpServer(0, IppHttpHandler(handler, { config }, store) { null })
        server.start()
        uri = "ipp://localhost:${server.boundPort}${PrinterConfig.RESOURCE_PATH}"
    }

    @After
    fun tearDown() {
        if (::server.isInitialized) server.stop()
        if (::dir.isInitialized) dir.deleteRecursively()
    }

    private fun run(vararg args: String): Pair<Int, String> {
        val opts = args.toList().dropLast(1)
        val testFile = args.last()
        val p = ProcessBuilder(listOf(ipptool.path, "-t", "-T", "30") + opts + listOf(uri, testFile))
            .redirectErrorStream(true).start()
        val out = p.inputStream.bufferedReader().readText()
        assertTrue("ipptool timed out", p.waitFor(90, TimeUnit.SECONDS))
        println(out)
        return p.exitValue() to out
    }

    @Test
    fun getPrinterAttributes() {
        val (code, out) = run("-f", samplePdf.path, File(testDir, "get-printer-attributes.test").path)
        assertEquals(out, 0, code)
    }

    @Test
    fun ippEverywhereConformance() {
        val (code, out) = run("-f", samplePdf.path, File(testDir, "ipp-everywhere.test").path)
        assertEquals(out, 0, code)
    }

    @Test
    fun printJobStoresPdf() {
        val pdf = samplePdf
        val (code, out) = run("-f", pdf.path, File(testDir, "print-job.test").path)
        assertEquals(out, 0, code)
        val job = store.list().first()
        assertEquals(JobState.COMPLETED, job.state)
        assertEquals("application/pdf", job.format)
        // macOS ships the sample documents gzip-compressed; ipptool inflates them before sending.
        val expected = pdf.readBytes()
        assertEquals(expected.size.toLong(), job.file!!.length())
        assertTrue(expected.contentEquals(job.file!!.readBytes()))
    }

    @Test
    fun pdfOnlyModeAttributesAndPrintJob() {
        config = config.copy(compatibilityMode = false)
        val pdf = samplePdf
        val (attrCode, attrOut) = run("-f", pdf.path, File(testDir, "get-printer-attributes.test").path)
        assertEquals(attrOut, 0, attrCode)
        val (code, out) = run("-f", pdf.path, File(testDir, "print-job.test").path)
        assertEquals(out, 0, code)
        val job = store.list().first()
        assertEquals(JobState.COMPLETED, job.state)
        assertEquals("application/pdf", job.format)
    }

    @Test
    fun ipp11Conformance() {
        val (code, out) = run("-f", samplePdf.path, File(testDir, "ipp-1.1.test").path)
        assertEquals(out, 0, code)
    }

    private fun minimalPdf(): ByteArray {
        val objects = listOf(
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            "<< /Length 44 >>\nstream\nBT /F1 24 Tf 72 720 Td (Imprima test) Tj ET\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        )
        val sb = StringBuilder("%PDF-1.4\n")
        val offsets = ArrayList<Int>()
        objects.forEachIndexed { i, body ->
            offsets += sb.length
            sb.append("${'$'}{i + 1} 0 obj\n").append(body).append("\nendobj\n")
        }
        val xref = sb.length
        sb.append("xref\n0 ${'$'}{objects.size + 1}\n0000000000 65535 f \n")
        offsets.forEach { sb.append(String.format("%010d 00000 n \n", it)) }
        sb.append("trailer\n<< /Size ${'$'}{objects.size + 1} /Root 1 0 R >>\nstartxref\n${'$'}xref\n%%EOF\n")
        return sb.toString().toByteArray(Charsets.ISO_8859_1)
    }
}
