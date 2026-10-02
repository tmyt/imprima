package com.rasa.printer.service

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import com.rasa.printer.printer.DocumentExporter
import java.io.File
import java.io.IOException

/** Copies finished documents into Documents/Rasa Printer via MediaStore (no permission needed on API 29+). */
class MediaStoreExporter(context: Context) : DocumentExporter {
    private val resolver = context.applicationContext.contentResolver

    override fun export(source: File, format: String, displayName: String): String {
        val collection = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        var uri: Uri? = insert(collection, displayName, format)
            ?: insert(collection, withSuffix(displayName), format)
        if (uri == null) throw IOException("MediaStore insert failed for $displayName")
        try {
            val out = resolver.openOutputStream(uri) ?: throw IOException("Cannot open $uri")
            out.use { o -> source.inputStream().use { it.copyTo(o) } }
            val done = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            resolver.update(uri, done, null, null)
            return uri.toString()
        } catch (e: Exception) {
            try { resolver.delete(uri!!, null, null) } catch (_: Exception) {}
            throw if (e is IOException) e else IOException("Export failed", e)
        }
    }

    override fun delete(uri: String) {
        try {
            resolver.delete(Uri.parse(uri), null, null)
        } catch (e: Exception) {
            Log.w("RasaPrinter", "Export delete failed for $uri", e)
        }
    }

    private fun insert(collection: Uri, name: String, mime: String): Uri? = try {
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOCUMENTS + "/Rasa Printer")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        resolver.insert(collection, values)
    } catch (e: Exception) {
        Log.w("RasaPrinter", "MediaStore insert failed for $name", e)
        null
    }

    private fun withSuffix(name: String): String {
        val dot = name.lastIndexOf('.')
        return if (dot > 0) name.substring(0, dot) + " (2)" + name.substring(dot) else "$name (2)"
    }
}
