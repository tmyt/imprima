package com.rasa.printer.service

import android.app.Service
import android.content.Intent
import android.os.IBinder

class PrinterForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null
    // unit D
}
