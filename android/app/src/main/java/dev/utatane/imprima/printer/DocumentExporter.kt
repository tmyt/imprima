package dev.utatane.imprima.printer

import java.io.File
import java.io.IOException

/**
 * Moves a finished document into shared storage visible to other apps (e.g. MediaStore
 * "Documents/Imprima"). FROZEN INTERFACE. Implementations must be thread-safe.
 */
interface DocumentExporter {
    /**
     * Copies [source] to shared storage and returns its content URI as a string.
     * @param displayName suggested file name including extension (already sanitised, unique enough)
     * @param format MIME type of the document
     * @throws IOException on failure (the caller keeps the internal file)
     */
    @Throws(IOException::class)
    fun export(source: File, format: String, displayName: String): String

    /** Deletes an exported document; no-op if it no longer exists. Never throws. */
    fun delete(uri: String)
}
