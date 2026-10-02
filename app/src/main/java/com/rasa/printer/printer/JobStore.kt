package com.rasa.printer.printer

import java.io.InputStream
import kotlinx.coroutines.flow.StateFlow

/**
 * Job persistence. FROZEN INTERFACE. Implementations must be thread-safe
 * (called from HTTP connection threads and the UI).
 */
interface JobStore {
    /** All jobs, newest first. Emits on every change. */
    val jobs: StateFlow<List<PrintJob>>

    /** Creates a job in state PENDING with no document. Ids are monotonically increasing, starting at 1. */
    fun create(name: String, userName: String, format: String): PrintJob

    /**
     * Stores the document for [jobId], reading [data] to EOF, then sets sizeBytes, format and
     * state = COMPLETED. Returns the updated job. Throws IllegalArgumentException if the job
     * does not exist; IOException on storage failure (job state becomes ABORTED).
     */
    fun writeDocument(jobId: Int, format: String, data: InputStream): PrintJob

    fun get(jobId: Int): PrintJob?

    /** Returns the updated job, or null if it does not exist. */
    fun setState(jobId: Int, state: JobState): PrintJob?

    /** Removes job and its file. No-op if absent. */
    fun delete(jobId: Int)

    fun list(): List<PrintJob>
}
