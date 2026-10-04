package dev.utatane.imprima.printer

import java.io.File

/** Result of a successful conversion. FROZEN INTERFACE. */
data class ConvertedDocument(val file: File, val format: String)

/**
 * Post-receive document conversion hook used by the job store. FROZEN INTERFACE.
 * Called after a document has been fully stored. Return null when no conversion applies
 * (the original is kept); return a ConvertedDocument to replace the stored file (the store
 * deletes [source] afterwards). Throw on failure (the store keeps the original and logs).
 *
 * @param source stored document
 * @param format its MIME type
 * @param target the file to write the converted output to (does not exist yet; same dir as source)
 */
fun interface DocumentConverter {
    fun convert(source: File, format: String, target: (extension: String) -> File): ConvertedDocument?
}
