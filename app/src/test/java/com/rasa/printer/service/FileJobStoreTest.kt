package com.rasa.printer.service

import com.rasa.printer.printer.JobState
import com.rasa.printer.printer.ConvertedDocument
import com.rasa.printer.printer.DocumentConverter
import java.io.ByteArrayInputStream
import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

class FileJobStoreTest {
    private lateinit var dir: File

    @Before fun setUp() { dir = Files.createTempDirectory("jobs").toFile() }
    @After fun tearDown() { dir.deleteRecursively() }

    @Test fun createWriteGet() {
        val store = FileJobStore(dir)
        val job = store.create("doc", "alice", "application/pdf")
        assertEquals(1, job.id)
        assertEquals(JobState.PENDING, job.state)
        assertNull(job.file)
        val bytes = ByteArray(1000) { it.toByte() }
        val done = store.writeDocument(job.id, "application/pdf", ByteArrayInputStream(bytes))
        assertEquals(JobState.COMPLETED, done.state)
        assertEquals(1000L, done.sizeBytes)
        assertEquals("pdf", done.file!!.extension)
        assertArrayEquals(bytes, done.file!!.readBytes())
        assertEquals(done, store.get(job.id))
    }

    @Test fun idsSurviveReopen() {
        val a = FileJobStore(dir)
        a.create("a", "u", "image/urf")
        val j2 = a.create("b", "u", "image/urf")
        a.writeDocument(j2.id, "image/urf", ByteArrayInputStream(byteArrayOf(1, 2)))
        a.delete(j2.id)
        val b = FileJobStore(dir)
        assertEquals(1, b.list().size)
        assertEquals(3, b.create("c", "u", "image/png").id)
    }

    @Test fun reopenKeepsDocument() {
        val a = FileJobStore(dir)
        val j = a.create("a", "u", "image/jpeg")
        a.writeDocument(j.id, "image/jpeg", ByteArrayInputStream(byteArrayOf(9)))
        val got = FileJobStore(dir).get(j.id)!!
        assertEquals(JobState.COMPLETED, got.state)
        assertEquals("jpg", got.file!!.extension)
    }

    @Test fun setStateAndDelete() {
        val s = FileJobStore(dir)
        val j = s.create("a", "u", "application/pdf")
        assertEquals(JobState.CANCELED, s.setState(j.id, JobState.CANCELED)!!.state)
        assertNull(s.setState(99, JobState.CANCELED))
        val f = s.writeDocument(j.id, "application/pdf", ByteArrayInputStream(byteArrayOf(1))).file!!
        assertTrue(f.exists())
        s.delete(j.id)
        assertFalse(f.exists())
        assertNull(s.get(j.id))
        s.delete(j.id)
    }

    @Test fun unknownIdThrows() {
        assertThrows(IllegalArgumentException::class.java) {
            FileJobStore(dir).writeDocument(5, "application/pdf", ByteArrayInputStream(ByteArray(0)))
        }
    }

    @Test fun flowNewestFirst() {
        val s = FileJobStore(dir)
        s.create("a", "u", "x"); s.create("b", "u", "x"); s.create("c", "u", "x")
        assertEquals(listOf(3, 2, 1), s.jobs.value.map { it.id })
    }

    @Test fun corruptMetadataStartsEmpty() {
        File(dir, "jobs.json").writeText("{not json")
        val s = FileJobStore(dir)
        assertTrue(s.list().isEmpty())
        assertEquals(1, s.create("a", "u", "x").id)
    }

    @Test fun converterReplacesFile() {
        val s = FileJobStore(dir, DocumentConverter { src, _, target ->
            val out = target("pdf"); out.writeText("PDF"); ConvertedDocument(out, "application/pdf")
        })
        val j = s.create("a", "u", "image/urf")
        val done = s.writeDocument(j.id, "image/urf", ByteArrayInputStream(byteArrayOf(1, 2, 3)))
        assertEquals("application/pdf", done.format)
        assertEquals("pdf", done.file!!.extension)
        assertEquals(3L, done.sizeBytes)
        assertFalse(File(dir, "${j.id}.urf").exists())
        assertEquals(JobState.COMPLETED, done.state)
    }

    @Test fun converterNullKeepsOriginal() {
        val s = FileJobStore(dir, DocumentConverter { _, _, _ -> null })
        val j = s.create("a", "u", "image/urf")
        val done = s.writeDocument(j.id, "image/urf", ByteArrayInputStream(byteArrayOf(1, 2)))
        assertEquals("image/urf", done.format)
        assertEquals("urf", done.file!!.extension)
    }

    @Test fun converterThrowKeepsOriginal() {
        val s = FileJobStore(dir, DocumentConverter { _, _, _ -> throw IllegalStateException("boom") })
        val j = s.create("a", "u", "image/urf")
        val done = s.writeDocument(j.id, "image/urf", ByteArrayInputStream(byteArrayOf(1, 2)))
        assertEquals(JobState.COMPLETED, done.state)
        assertEquals("image/urf", done.format)
        assertTrue(done.file!!.exists())
    }
}
