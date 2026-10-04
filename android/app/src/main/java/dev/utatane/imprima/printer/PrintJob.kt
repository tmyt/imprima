package dev.utatane.imprima.printer

import java.io.File

/** IPP job-state enum values (RFC 8011 §5.3.7). FROZEN INTERFACE. */
enum class JobState(val ippValue: Int) {
    PENDING(3), PENDING_HELD(4), PROCESSING(5), PROCESSING_STOPPED(6),
    CANCELED(7), ABORTED(8), COMPLETED(9);

    companion object {
        fun fromIpp(value: Int): JobState = entries.first { it.ippValue == value }
    }
}

/** One received print job. FROZEN INTERFACE. */
data class PrintJob(
    val id: Int,
    val name: String,
    val userName: String,
    /** MIME type of the stored document, e.g. "application/pdf", "image/pwg-raster", "image/urf". */
    val format: String,
    val state: JobState,
    /** epoch milliseconds */
    val createdAt: Long,
    val sizeBytes: Long,
    /** Internal document file; null until a document has been received, and null once exported to [uri]. */
    val file: File?,
    /** content:// URI of the exported document in shared storage (MediaStore), null while not exported. */
    val uri: String? = null,
) {
    /** True when a document is available either internally or in shared storage. */
    val hasDocument: Boolean get() = file != null || uri != null
}
