package com.rasa.printer

import android.app.Application
import com.rasa.printer.service.PrinterController

class PrinterApp : Application() {
    override fun onCreate() {
        super.onCreate()
        PrinterController.attach(this)
    }
}
