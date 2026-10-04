package dev.utatane.imprima.printer

import dev.utatane.imprima.ipp.IppAttribute
import dev.utatane.imprima.ipp.IppGroup
import dev.utatane.imprima.ipp.IppMessage
import dev.utatane.imprima.ipp.IppOperation
import dev.utatane.imprima.ipp.IppStatus
import dev.utatane.imprima.ipp.IppTag
import dev.utatane.imprima.ipp.IppValue
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.io.SequenceInputStream
import java.util.logging.Level
import java.util.logging.Logger

/**
 * IPP Everywhere operation handler, transport-agnostic. FROZEN INTERFACE.
 *
 * @param config current printer configuration (read on every request)
 * @param jobs job persistence
 * @param clock epoch millis provider (injectable for tests)
 */
class IppPrinterHandler(
    private val config: () -> PrinterConfig,
    private val jobs: JobStore,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    /**
     * @param request decoded IPP request
     * @param document document bytes following the attributes (may be empty); read to EOF for
     *                 Print-Job / Send-Document, ignored otherwise
     * @param printerUri the URI this printer is reachable at for this client,
     *                   e.g. "ipp://192.168.1.5:8631/ipp/print" (derived from the HTTP Host header)
     * @return IPP response (never throws for protocol errors; maps them to status codes)
     */
    fun handle(request: IppMessage, document: InputStream, printerUri: String): IppMessage = try {
        dispatch(request, document, printerUri)
    } catch (e: IppError) {
        response(request, e.status, e.message)
    } catch (e: Exception) {
        log.log(Level.WARNING, "IPP operation 0x%04x failed".format(request.code), e)
        response(request, IppStatus.SERVER_ERROR_INTERNAL_ERROR, "Internal error: ${e.message ?: e.javaClass.simpleName}")
    }

    private class IppError(val status: Int, message: String) : Exception(message)

    private fun dispatch(req: IppMessage, document: InputStream, printerUri: String): IppMessage {
        if (req.versionMajor != 1 && req.versionMajor != 2) {
            throw IppError(IppStatus.SERVER_ERROR_VERSION_NOT_SUPPORTED, "IPP version ${req.versionMajor}.${req.versionMinor} not supported")
        }
        if (req.requestId <= 0) throw IppError(IppStatus.CLIENT_ERROR_BAD_REQUEST, "Invalid request-id ${req.requestId}")
        val op = req.groups.firstOrNull()?.takeIf { it.tag == IppTag.OPERATION_ATTRIBUTES }
            ?: throw IppError(IppStatus.CLIENT_ERROR_BAD_REQUEST, "Missing operation attributes")
        // RFC 8011 §4.1.4: attributes-charset first, attributes-natural-language second.
        val first = op.attributes.getOrNull(0)
        val second = op.attributes.getOrNull(1)
        if (first?.name != "attributes-charset" || first.stringValue == null ||
            second?.name != "attributes-natural-language" || second.stringValue == null
        ) {
            throw IppError(IppStatus.CLIENT_ERROR_BAD_REQUEST, "attributes-charset and attributes-natural-language must be the first two attributes")
        }
        // RFC 8011 §4.2: every operation targets printer-uri (job operations may use job-uri instead).
        if (op["printer-uri"]?.stringValue == null && op["job-uri"]?.stringValue == null) {
            throw IppError(IppStatus.CLIENT_ERROR_BAD_REQUEST, "Missing printer-uri")
        }
        val ctx = Ctx(req, op, printerUri, config())
        return when (req.code) {
            IppOperation.GET_PRINTER_ATTRIBUTES -> getPrinterAttributes(ctx)
            IppOperation.VALIDATE_JOB -> { checkCompression(op); declaredFormat(ctx); ok(req) }
            IppOperation.PRINT_JOB -> printJob(ctx, document)
            IppOperation.CREATE_JOB -> createJob(ctx)
            IppOperation.SEND_DOCUMENT -> sendDocument(ctx, document)
            IppOperation.CLOSE_JOB -> closeJob(ctx)
            IppOperation.CANCEL_JOB -> cancelJob(ctx)
            IppOperation.GET_JOB_ATTRIBUTES -> getJobAttributes(ctx)
            IppOperation.GET_JOBS -> getJobs(ctx)
            IppOperation.IDENTIFY_PRINTER -> ok(req)
            PrinterAttributes.CANCEL_MY_JOBS -> cancelMyJobs(ctx)
            else -> throw IppError(IppStatus.SERVER_ERROR_OPERATION_NOT_SUPPORTED, "Operation 0x%04x not supported".format(req.code))
        }
    }

    /** [config] is read once per request, so a mode switch applies from the next request on. */
    private class Ctx(val req: IppMessage, val op: IppGroup, val printerUri: String, val config: PrinterConfig) {
        val userName: String get() = op["requesting-user-name"]?.stringValue?.takeIf { it.isNotBlank() } ?: "anonymous"
        val requested: List<String>? get() = op["requested-attributes"]?.stringValues?.takeIf { it.isNotEmpty() }
    }

    // ---------------------------------------------------------------- printer

    private fun getPrinterAttributes(ctx: Ctx): IppMessage {
        val now = clock()
        val queued = jobs.list().count { !it.state.isTerminal }
        val all = PrinterAttributes.build(ctx.config, ctx.printerUri, queued, upTime(now), now, startMillis)
        val requested = ctx.requested?.toSet()
        val selected = if (requested == null || "all" in requested) all else all.filter { a ->
            a.name in requested ||
                ("printer-description" in requested && a.name in PrinterAttributes.DESCRIPTION_NAMES) ||
                ("job-template" in requested && a.name in PrinterAttributes.JOB_TEMPLATE_NAMES)
        }
        return ok(ctx.req, listOf(IppGroup(IppTag.PRINTER_ATTRIBUTES, selected)))
    }

    /** Printer config/state never change while this handler lives: both change times are its construction time. */
    private val startMillis = clock()

    /** printer-up-time in epoch seconds (as CUPS ippeveprinter does), so time-at-* attributes share its scale. */
    private fun upTime(now: Long = clock()): Int = maxOf(1L, now / 1000).toInt()

    // ---------------------------------------------------------------- jobs

    private fun printJob(ctx: Ctx, document: InputStream): IppMessage {
        checkCompression(ctx.op)
        val declared = declaredFormat(ctx)
        val job = jobs.create(jobName(ctx.op), ctx.userName, declared ?: OCTET_STREAM)
        val stored = store(ctx, job.id, declared, document)
        return ok(ctx.req, listOf(shortJobGroup(stored, ctx.printerUri)))
    }

    private fun createJob(ctx: Ctx): IppMessage {
        checkCompression(ctx.op)
        val declared = declaredFormat(ctx)
        val job = jobs.create(jobName(ctx.op), ctx.userName, declared ?: OCTET_STREAM)
        return ok(ctx.req, listOf(shortJobGroup(job, ctx.printerUri)))
    }

    private fun sendDocument(ctx: Ctx, document: InputStream): IppMessage {
        checkCompression(ctx.op)
        val declared = declaredFormat(ctx)
        if (ctx.op["last-document"]?.value !is IppValue.Bool) {
            throw IppError(IppStatus.CLIENT_ERROR_BAD_REQUEST, "Missing last-document")
        }
        val job = findJob(ctx)
        // Only single-document jobs: the document is stored and the job completed whatever last-document says.
        val head = readHead(document)
        val result = if (head.isEmpty()) {
            if (job.file != null || job.state.isTerminal) job
            else store(ctx, job.id, declared ?: job.format.takeIf { it != OCTET_STREAM }, ByteArrayInputStream(head))
        } else {
            if (job.state.isTerminal) {
                throw IppError(IppStatus.CLIENT_ERROR_NOT_POSSIBLE, "Job ${job.id} is already ${job.state.name.lowercase()}")
            }
            val format = declared ?: job.format.takeIf { it != OCTET_STREAM }
            store(ctx, job.id, format, SequenceInputStream(ByteArrayInputStream(head), document), head)
        }
        return ok(ctx.req, listOf(shortJobGroup(result, ctx.printerUri)))
    }

    private fun closeJob(ctx: Ctx): IppMessage {
        val job = findJob(ctx)
        val result = if (job.file != null && !job.state.isTerminal) jobs.setState(job.id, JobState.COMPLETED) ?: job else job
        return ok(ctx.req, listOf(shortJobGroup(result, ctx.printerUri)))
    }

    private fun cancelJob(ctx: Ctx): IppMessage {
        val job = findJob(ctx)
        if (job.state.isTerminal) {
            throw IppError(IppStatus.CLIENT_ERROR_NOT_POSSIBLE, "Job ${job.id} is already ${job.state.name.lowercase()}")
        }
        jobs.setState(job.id, JobState.CANCELED) ?: throw IppError(IppStatus.CLIENT_ERROR_NOT_FOUND, "Job ${job.id} not found")
        return ok(ctx.req)
    }

    /** Cancel-My-Jobs (PWG 5100.11): the given job-ids, or every active job of requesting-user-name. */
    private fun cancelMyJobs(ctx: Ctx): IppMessage {
        val ids = ctx.op["job-ids"]?.values?.mapNotNull { it.intValue }
        val targets = if (ids != null) {
            ids.map { id -> jobs.get(id) ?: throw IppError(IppStatus.CLIENT_ERROR_NOT_FOUND, "Job $id not found") }
        } else {
            val user = ctx.userName
            jobs.list().filter { it.userName == user }
        }
        targets.filter { !it.state.isTerminal }.forEach { jobs.setState(it.id, JobState.CANCELED) }
        return ok(ctx.req)
    }

    private fun getJobAttributes(ctx: Ctx): IppMessage {
        val job = findJob(ctx)
        val attrs = filterJob(fullJobAttributes(job, ctx.printerUri), ctx.requested)
        return ok(ctx.req, listOf(IppGroup(IppTag.JOB_ATTRIBUTES, attrs)))
    }

    private fun getJobs(ctx: Ctx): IppMessage {
        val which = ctx.op["which-jobs"]?.stringValue ?: "not-completed"
        val predicate: (PrintJob) -> Boolean = when (which) {
            "completed" -> { j -> j.state.isTerminal }
            "not-completed" -> { j -> !j.state.isTerminal }
            "all" -> { _ -> true }
            else -> throw IppError(IppStatus.CLIENT_ERROR_ATTRIBUTES_OR_VALUES_NOT_SUPPORTED, "which-jobs '$which' not supported")
        }
        val myJobs = (ctx.op["my-jobs"]?.value as? IppValue.Bool)?.value == true
        val user = ctx.userName
        val limit = ctx.op["limit"]?.intValue?.takeIf { it > 0 } ?: Int.MAX_VALUE
        val requested = ctx.requested ?: listOf("job-id", "job-uri")
        val groups = jobs.list()
            .sortedByDescending { it.id }
            .filter(predicate)
            .filter { !myJobs || it.userName == user }
            .take(limit)
            .map { IppGroup(IppTag.JOB_ATTRIBUTES, filterJob(fullJobAttributes(it, ctx.printerUri), requested)) }
        return ok(ctx.req, groups)
    }

    // ---------------------------------------------------------------- helpers

    private fun findJob(ctx: Ctx): PrintJob {
        val id = ctx.op["job-id"]?.intValue
            ?: ctx.op["job-uri"]?.stringValue?.substringAfterLast('/')?.toIntOrNull()
            ?: throw IppError(IppStatus.CLIENT_ERROR_BAD_REQUEST, "Missing job-id or job-uri")
        return jobs.get(id) ?: throw IppError(IppStatus.CLIENT_ERROR_NOT_FOUND, "Job $id not found")
    }

    private fun jobName(op: IppGroup): String = op["job-name"]?.stringValue?.takeIf { it.isNotBlank() } ?: "Untitled"

    private fun checkCompression(op: IppGroup) {
        val c = op["compression"]?.stringValue ?: return
        if (!c.equals("none", ignoreCase = true)) {
            throw IppError(IppStatus.CLIENT_ERROR_COMPRESSION_NOT_SUPPORTED, "Compression '$c' not supported")
        }
    }

    /** Validated document-format, or null when absent / application/octet-stream (= sniff). */
    private fun declaredFormat(ctx: Ctx): String? {
        val raw = ctx.op["document-format"]?.stringValue ?: return null
        val format = raw.substringBefore(';').trim().lowercase()
        if (format !in PrinterAttributes.documentFormats(ctx.config)) {
            val hint = if (ctx.config.compatibilityMode) "" else " (PDF-only mode)"
            throw IppError(IppStatus.CLIENT_ERROR_DOCUMENT_FORMAT_NOT_SUPPORTED, "Document format '$raw' not supported$hint")
        }
        return format.takeIf { it != OCTET_STREAM }
    }

    /**
     * Writes the document; sniffs the format from the first bytes when [format] is null.
     * [head] are bytes already read from [data] (data still yields them), if any.
     * In PDF-only mode a sniffed non-PDF document is drained and discarded and the job ABORTED.
     */
    private fun store(ctx: Ctx, jobId: Int, format: String?, data: InputStream, head: ByteArray? = null): PrintJob {
        var stream = data
        var actualFormat = format
        if (actualFormat == null) {
            val prefix = head ?: readHead(data).also { stream = SequenceInputStream(ByteArrayInputStream(it), data) }
            actualFormat = sniff(prefix)
            if (!ctx.config.compatibilityMode && actualFormat != PrinterAttributes.PDF) {
                drain(stream)
                jobs.setState(jobId, JobState.ABORTED)
                throw IppError(
                    IppStatus.CLIENT_ERROR_DOCUMENT_FORMAT_NOT_SUPPORTED,
                    "Only PDF documents are accepted (PDF-only mode); received $actualFormat",
                )
            }
        }
        return try {
            jobs.writeDocument(jobId, actualFormat, stream)
        } catch (e: IOException) {
            log.log(Level.WARNING, "Storing document for job $jobId failed", e)
            throw IppError(IppStatus.SERVER_ERROR_INTERNAL_ERROR, "Failed to store document: ${e.message}")
        }
    }

    private fun drain(input: InputStream) {
        val buf = ByteArray(8192)
        while (input.read(buf) >= 0) { /* discard */ }
    }

    /** Reads up to [SNIFF_BYTES] bytes (fewer only at EOF). */
    private fun readHead(input: InputStream): ByteArray {
        val buf = ByteArray(SNIFF_BYTES)
        var n = 0
        while (n < buf.size) {
            val r = input.read(buf, n, buf.size - n)
            if (r < 0) break
            n += r
        }
        return buf.copyOf(n)
    }

    private fun sniff(b: ByteArray): String {
        fun starts(vararg p: Int) = b.size >= p.size && p.indices.all { (b[it].toInt() and 0xFF) == p[it] }
        fun startsAscii(s: String) = starts(*s.map { it.code }.toIntArray())
        return when {
            startsAscii("%PDF") -> "application/pdf"
            startsAscii("RaS2") -> "image/pwg-raster"
            startsAscii("UNIRAST") -> "image/urf"
            starts(0xFF, 0xD8) -> "image/jpeg"
            starts(0x89, 'P'.code, 'N'.code, 'G'.code) -> "image/png"
            else -> OCTET_STREAM
        }
    }

    private fun shortJobGroup(job: PrintJob, printerUri: String) = IppGroup(
        IppTag.JOB_ATTRIBUTES,
        listOf(
            IppAttribute("job-id", IppValue.Integer(job.id)),
            IppAttribute("job-uri", IppValue.Uri(jobUri(job, printerUri))),
            IppAttribute("job-state", IppValue.Enum(job.state.ippValue)),
            IppAttribute("job-state-reasons", IppValue.Keyword(job.state.reason)),
            IppAttribute("job-state-message", IppValue.Text(job.state.message)),
        ),
    )

    private fun fullJobAttributes(job: PrintJob, printerUri: String): List<IppAttribute> {
        val created = IppValue.Integer((job.createdAt / 1000).toInt())
        val noValue = IppValue.OutOfBand(IppTag.NO_VALUE)
        val processed = job.state != JobState.PENDING && job.state != JobState.PENDING_HELD
        return listOf(
            IppAttribute("job-id", IppValue.Integer(job.id)),
            IppAttribute("job-uri", IppValue.Uri(jobUri(job, printerUri))),
            IppAttribute("job-printer-uri", IppValue.Uri(printerUri)),
            IppAttribute("job-name", IppValue.Name(job.name)),
            IppAttribute("job-originating-user-name", IppValue.Name(job.userName)),
            IppAttribute("job-state", IppValue.Enum(job.state.ippValue)),
            IppAttribute("job-state-reasons", IppValue.Keyword(job.state.reason)),
            IppAttribute("job-state-message", IppValue.Text(job.state.message)),
            IppAttribute("time-at-creation", created),
            IppAttribute("time-at-processing", if (processed) created else noValue),
            IppAttribute("time-at-completed", if (job.state.isTerminal) created else noValue),
            IppAttribute("job-printer-up-time", IppValue.Integer(upTime())),
            IppAttribute("job-impressions-completed", IppValue.Integer(0)),
            IppAttribute("job-k-octets", IppValue.Integer(((job.sizeBytes + 1023) / 1024).toInt())),
            IppAttribute("document-format", IppValue.MimeMediaType(job.format)),
            IppAttribute("date-time-at-creation", PrinterAttributes.dateTime(job.createdAt)),
        )
    }

    private fun filterJob(attrs: List<IppAttribute>, requested: List<String>?): List<IppAttribute> {
        if (requested == null || requested.any { it == "all" || it == "job-description" || it == "job-template" }) return attrs
        val set = requested.toSet()
        return attrs.filter { it.name in set }
    }

    private fun jobUri(job: PrintJob, printerUri: String) = "$printerUri/${job.id}"

    private fun ok(req: IppMessage, groups: List<IppGroup> = emptyList()) = response(req, IppStatus.OK, null, groups)

    private fun response(req: IppMessage, status: Int, message: String?, groups: List<IppGroup> = emptyList()): IppMessage {
        val op = buildList {
            add(IppAttribute("attributes-charset", IppValue.Charset("utf-8")))
            add(IppAttribute("attributes-natural-language", IppValue.NaturalLanguage("en")))
            if (message != null) add(IppAttribute("status-message", IppValue.Text(message)))
        }
        // RFC 8011 §4.1.8: answer in the request's version when supported; 2.0 otherwise.
        val supported = req.versionMajor == 1 || req.versionMajor == 2
        val major = if (supported) req.versionMajor else 2
        val minor = if (supported) req.versionMinor else 0
        return IppMessage(status, req.requestId, listOf(IppGroup(IppTag.OPERATION_ATTRIBUTES, op)) + groups, major, minor)
    }

    private val JobState.isTerminal: Boolean
        get() = this == JobState.COMPLETED || this == JobState.CANCELED || this == JobState.ABORTED

    private val JobState.reason: String
        get() = when (this) {
            JobState.COMPLETED -> "job-completed-successfully"
            JobState.CANCELED -> "job-canceled-by-user"
            JobState.ABORTED -> "job-aborted-by-system"
            JobState.PROCESSING -> "job-printing"
            JobState.PENDING_HELD -> "job-hold-until-specified"
            JobState.PROCESSING_STOPPED -> "printer-stopped"
            JobState.PENDING -> "none"
        }

    private val JobState.message: String
        get() = when (this) {
            JobState.PENDING -> "Pending"
            JobState.PENDING_HELD -> "Held"
            JobState.PROCESSING -> "Processing"
            JobState.PROCESSING_STOPPED -> "Stopped"
            JobState.CANCELED -> "Canceled"
            JobState.ABORTED -> "Aborted"
            JobState.COMPLETED -> "Completed"
        }

    private companion object {
        val log: Logger = Logger.getLogger(IppPrinterHandler::class.java.name)
        const val OCTET_STREAM = PrinterAttributes.OCTET_STREAM
        const val SNIFF_BYTES = 8
    }
}
