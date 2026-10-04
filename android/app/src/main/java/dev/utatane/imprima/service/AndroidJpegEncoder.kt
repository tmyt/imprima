package dev.utatane.imprima.service

import android.graphics.Bitmap
import android.util.Log
import dev.utatane.imprima.raster.JpegEncoder
import dev.utatane.imprima.raster.PixelFormat
import java.io.ByteArrayOutputStream

/** JPEG encoding through android.graphics; returns null on any failure so callers fall back to Flate. */
object AndroidJpegEncoder : JpegEncoder {
    private const val MAX_PIXELS = 16_000_000L

    override fun encode(width: Int, height: Int, format: PixelFormat, pixels: ByteArray, quality: Int): ByteArray? {
        if (width <= 0 || height <= 0 || width.toLong() * height > MAX_PIXELS) return null
        var bmp: Bitmap? = null
        try {
            val n = width * height
            val argb = IntArray(n)
            when (format) {
                PixelFormat.GRAY_8 -> {
                    if (pixels.size < n) return null
                    for (i in 0 until n) {
                        val g = pixels[i].toInt() and 0xFF
                        argb[i] = (0xFF shl 24) or (g shl 16) or (g shl 8) or g
                    }
                }
                PixelFormat.RGB_24 -> {
                    if (pixels.size < n * 3) return null
                    for (i in 0 until n) {
                        val o = i * 3
                        argb[i] = (0xFF shl 24) or ((pixels[o].toInt() and 0xFF) shl 16) or
                            ((pixels[o + 1].toInt() and 0xFF) shl 8) or (pixels[o + 2].toInt() and 0xFF)
                    }
                }
                PixelFormat.BLACK_1 -> return null
            }
            bmp = Bitmap.createBitmap(argb, width, height, Bitmap.Config.ARGB_8888)
            val out = ByteArrayOutputStream()
            if (!bmp.compress(Bitmap.CompressFormat.JPEG, quality, out)) return null
            return out.toByteArray()
        } catch (t: Throwable) {
            Log.w("Imprima", "JPEG encode failed", t)
            return null
        } finally {
            bmp?.recycle()
        }
    }
}
