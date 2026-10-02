package com.rasa.printer

import com.rasa.printer.http.HttpServer
import com.rasa.printer.printer.IppHttpHandler
import com.rasa.printer.printer.IppPrinterHandler
import com.rasa.printer.printer.JobState
import com.rasa.printer.printer.PrinterConfig
import com.rasa.printer.service.FileJobStore
import java.io.File
import java.util.concurrent.TimeUnit
import java.util.zip.GZIPInputStream
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

    @Before
    fun setUp() {
        assumeTrue("ipptool not installed", ipptool.canExecute() && testDir != null)
        dir = createTempDir("rasa-ipptool")
        store = FileJobStore(dir)
        val config = PrinterConfig(name = "Rasa Test Printer", port = 0, uuid = "12345678-1234-1234-1234-123456789abc")
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
        val (code, out) = run("-f", File(testDir, "document-a4.pdf").path, File(testDir, "get-printer-attributes.test").path)
        assertEquals(out, 0, code)
    }

    @Test
    fun ippEverywhereConformance() {
        val (code, out) = run("-f", File(testDir, "document-a4.pdf").path, File(testDir, "ipp-everywhere.test").path)
        assertEquals(out, 0, code)
    }

    @Test
    fun printJobStoresPdf() {
        val pdf = File(testDir, "document-a4.pdf")
        val (code, out) = run("-f", pdf.path, File(testDir, "print-job.test").path)
        assertEquals(out, 0, code)
        val job = store.list().first()
        assertEquals(JobState.COMPLETED, job.state)
        assertEquals("application/pdf", job.format)
        // macOS ships the sample documents gzip-compressed; ipptool inflates them before sending.
        val expected = pdf.readBytes().let { b ->
            if (b.size > 2 && b[0] == 0x1f.toByte() && b[1] == 0x8b.toByte()) GZIPInputStream(b.inputStream()).readBytes() else b
        }
        assertEquals(expected.size.toLong(), job.file!!.length())
        assertTrue(expected.contentEquals(job.file!!.readBytes()))
    }

    @Test
    fun ipp11Conformance() {
        val (code, out) = run("-f", File(testDir, "document-a4.pdf").path, File(testDir, "ipp-1.1.test").path)
        assertEquals(out, 0, code)
    }
}
