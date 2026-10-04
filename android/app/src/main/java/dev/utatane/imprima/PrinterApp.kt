package dev.utatane.imprima

import android.app.Application
import dev.utatane.imprima.service.PrinterController

class PrinterApp : Application() {
    override fun onCreate() {
        super.onCreate()
        PrinterController.attach(this)
    }
}
