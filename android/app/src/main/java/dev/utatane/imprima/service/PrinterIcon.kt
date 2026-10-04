package dev.utatane.imprima.service

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.util.Log
import java.io.ByteArrayOutputStream

/** Runtime-rendered 128x128 PNG printer glyph, used as the IPP printer-icons resource. */
object PrinterIcon {
    @Volatile private var cached: ByteArray? = null

    fun png(): ByteArray = cached ?: synchronized(this) { cached ?: render().also { cached = it } }

    private fun render(): ByteArray = try {
        val bmp = Bitmap.createBitmap(128, 128, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        val p = Paint(Paint.ANTI_ALIAS_FLAG)
        p.color = Color.parseColor("#37474F")
        c.drawRoundRect(RectF(8f, 40f, 120f, 100f), 12f, 12f, p)
        p.color = Color.WHITE
        c.drawRect(32f, 16f, 96f, 52f, p)
        c.drawRect(32f, 80f, 96f, 116f, p)
        p.color = Color.parseColor("#90A4AE")
        for (y in listOf(92f, 102f, 110f)) c.drawRect(40f, y, 88f, y + 3f, p)
        p.color = Color.parseColor("#4CAF50")
        c.drawCircle(100f, 56f, 5f, p)
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
        bmp.recycle()
        out.toByteArray()
    } catch (e: Throwable) {
        Log.w("Imprima", "Icon render failed", e)
        ByteArray(0)
    }
}
