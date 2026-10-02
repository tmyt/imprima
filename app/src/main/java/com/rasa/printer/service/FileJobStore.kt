package com.rasa.printer.service

import com.rasa.printer.printer.DocumentConverter
import com.rasa.printer.printer.JobState
import com.rasa.printer.printer.JobStore
import com.rasa.printer.printer.PrintJob
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.logging.Level
import java.util.logging.Logger
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** File-backed [JobStore]. Android-free so it can be unit tested on the JVM. */
class FileJobStore(
    private val dir: File,
    private val converter: DocumentConverter? = null,
) : JobStore {

    @Serializable
    private data class JobDto(
        val id: Int,
        val name: String,
        val userName: String,
        val format: String,
        val state: Int,
        val createdAt: Long,
        val sizeBytes: Long = 0,
        val fileName: String? = null,
    )

    @Serializable
    private data class StoreDto(val nextId: Int = 1, val jobs: List<JobDto> = emptyList())

    private val log = Logger.getLogger("FileJobStore")
    private val json = Json { ignoreUnknownKeys = true; prettyPrint = false }
    private val lock = Any()
    private val metaFile = File(dir, "jobs.json")
    private val byId = LinkedHashMap<Int, JobDto>()
    private var nextId = 1
    private val _jobs = MutableStateFlow<List<PrintJob>>(emptyList())

    override val jobs: StateFlow<List<PrintJob>> get() = _jobs

    init {
        dir.mkdirs()
        synchronized(lock) {
            try {
                if (metaFile.isFile) {
                    val s = json.decodeFromString(StoreDto.serializer(), metaFile.readText())
                    s.jobs.forEach { byId[it.id] = it }
                    nextId = maxOf(s.nextId, (byId.keys.maxOrNull() ?: 0) + 1)
                }
            } catch (e: Exception) {
                log.log(Level.WARNING, "Corrupt jobs.json, starting empty", e)
                byId.clear()
                nextId = 1
            }
            publish()
        }
    }

    override fun create(name: String, userName: String, format: String): PrintJob = synchronized(lock) {
        val dto = JobDto(nextId++, name, userName, format, JobState.PENDING.ippValue, System.currentTimeMillis())
        byId[dto.id] = dto
        persist()
        publish()
        toJob(dto)
    }

    override fun writeDocument(jobId: Int, format: String, data: InputStream): PrintJob {
        val existing = synchronized(lock) { byId[jobId] } ?: throw IllegalArgumentException("No such job: $jobId")
        val fileName = "$jobId.${extensionFor(format)}"
        val target = File(dir, fileName)
        val tmp = File(dir, "$fileName.tmp")
        try {
            dir.mkdirs()
            val size = tmp.outputStream().use { out -> data.copyTo(out) }
            synchronized(lock) {
                if (byId[jobId] == null) {
                    tmp.delete()
                    throw IllegalArgumentException("Job deleted: $jobId")
                }
                if (target.exists() && !target.delete()) throw IOException("Cannot replace $target")
                if (!tmp.renameTo(target)) throw IOException("Cannot rename $tmp")
            }
            var finalFile = target
            var finalFormat = format
            var finalSize = size
            if (converter != null) {
                try {
                    val result = converter.convert(target, format) { ext -> File(dir, "$jobId.$ext") }
                    if (result != null) {
                        finalFile = result.file
                        finalFormat = result.format
                        finalSize = result.file.length()
                        if (result.file.canonicalPath != target.canonicalPath) target.delete()
                    }
                } catch (e: Exception) {
                    log.log(Level.WARNING, "Conversion failed for job $jobId, keeping original", e)
                }
            }
            synchronized(lock) {
                val cur = byId[jobId]
                if (cur == null) {
                    finalFile.delete()
                    throw IllegalArgumentException("Job deleted: $jobId")
                }
                val updated = cur.copy(
                    format = finalFormat,
                    state = JobState.COMPLETED.ippValue,
                    sizeBytes = finalSize,
                    fileName = finalFile.name,
                )
                byId[jobId] = updated
                persist()
                publish()
                return toJob(updated)
            }
        } catch (e: IllegalArgumentException) {
            throw e
        } catch (e: Exception) {
            tmp.delete()
            synchronized(lock) {
                byId[jobId]?.let {
                    byId[jobId] = it.copy(state = JobState.ABORTED.ippValue)
                    try { persist() } catch (_: IOException) {}
                    publish()
                }
            }
            throw if (e is IOException) e else IOException("Failed to store document", e)
        }
    }

    override fun get(jobId: Int): PrintJob? = synchronized(lock) { byId[jobId]?.let(::toJob) }

    override fun setState(jobId: Int, state: JobState): PrintJob? = synchronized(lock) {
        val cur = byId[jobId] ?: return null
        val updated = cur.copy(state = state.ippValue)
        byId[jobId] = updated
        try { persist() } catch (e: IOException) { log.log(Level.WARNING, "persist failed", e) }
        publish()
        toJob(updated)
    }

    override fun delete(jobId: Int) {
        synchronized(lock) {
            val cur = byId.remove(jobId) ?: return
            cur.fileName?.let { File(dir, it).delete() }
            try { persist() } catch (e: IOException) { log.log(Level.WARNING, "persist failed", e) }
            publish()
        }
    }

    override fun list(): List<PrintJob> = _jobs.value

    // Must hold lock.
    private fun publish() {
        _jobs.value = byId.values.sortedByDescending { it.id }.map(::toJob)
    }

    // Must hold lock.
    private fun persist() {
        val text = json.encodeToString(StoreDto.serializer(), StoreDto(nextId, byId.values.toList()))
        val tmp = File(dir, "jobs.json.tmp")
        tmp.writeText(text)
        if (!tmp.renameTo(metaFile)) {
            metaFile.delete()
            if (!tmp.renameTo(metaFile)) throw IOException("Cannot write $metaFile")
        }
    }

    private fun toJob(d: JobDto) = PrintJob(
        id = d.id,
        name = d.name,
        userName = d.userName,
        format = d.format,
        state = JobState.entries.firstOrNull { it.ippValue == d.state } ?: JobState.ABORTED,
        createdAt = d.createdAt,
        sizeBytes = d.sizeBytes,
        file = d.fileName?.let { File(dir, it) }?.takeIf { it.exists() },
    )

    private fun extensionFor(format: String) = when (format.lowercase()) {
        "application/pdf" -> "pdf"
        "image/pwg-raster" -> "pwg"
        "image/urf" -> "urf"
        "image/jpeg" -> "jpg"
        "image/png" -> "png"
        else -> "bin"
    }
}
