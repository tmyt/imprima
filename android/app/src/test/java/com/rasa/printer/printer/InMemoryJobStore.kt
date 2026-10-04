package com.rasa.printer.printer

import java.io.File
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** Test-only JobStore: documents kept in memory and mirrored to temp files. */
class InMemoryJobStore(
    private val clock: () -> Long = System::currentTimeMillis,
    private val dir: File = Files.createTempDirectory("rasa-jobs").toFile().apply { deleteOnExit() },
) : JobStore {
    private val lock = Any()
    private val map = LinkedHashMap<Int, PrintJob>()
    private val docs = HashMap<Int, ByteArray>()
    private var nextId = 1
    private val flow = MutableStateFlow<List<PrintJob>>(emptyList())

    /** When true, writeDocument fails with IOException (job becomes ABORTED). */
    @Volatile var failWrites = false

    override val jobs: StateFlow<List<PrintJob>> get() = flow

    fun document(jobId: Int): ByteArray? = synchronized(lock) { docs[jobId] }

    override fun create(name: String, userName: String, format: String): PrintJob = synchronized(lock) {
        val job = PrintJob(nextId++, name, userName, format, JobState.PENDING, clock(), 0, null)
        map[job.id] = job
        publish()
        job
    }

    override fun writeDocument(jobId: Int, format: String, data: InputStream): PrintJob {
        synchronized(lock) { require(jobId in map) { "No job $jobId" } }
        val bytes = try {
            if (failWrites) throw IOException("simulated failure")
            data.readBytes()
        } catch (e: IOException) {
            setState(jobId, JobState.ABORTED)
            throw e
        }
        val file = File(dir, "job-$jobId.bin").apply { writeBytes(bytes); deleteOnExit() }
        return synchronized(lock) {
            val job = map.getValue(jobId).copy(format = format, sizeBytes = bytes.size.toLong(), state = JobState.COMPLETED, file = file)
            map[jobId] = job
            docs[jobId] = bytes
            publish()
            job
        }
    }

    override fun get(jobId: Int): PrintJob? = synchronized(lock) { map[jobId] }

    override fun setState(jobId: Int, state: JobState): PrintJob? = synchronized(lock) {
        val job = map[jobId]?.copy(state = state) ?: return null
        map[jobId] = job
        publish()
        job
    }

    override fun delete(jobId: Int): Unit = synchronized(lock) {
        map.remove(jobId)?.file?.delete()
        docs.remove(jobId)
        publish()
    }

    override fun list(): List<PrintJob> = synchronized(lock) { map.values.sortedByDescending { it.id } }

    private fun publish() { flow.value = map.values.sortedByDescending { it.id } }
}
