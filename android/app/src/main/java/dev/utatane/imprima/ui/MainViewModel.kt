package dev.utatane.imprima.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import dev.utatane.imprima.printer.PrintJob
import dev.utatane.imprima.printer.PrinterConfig
import dev.utatane.imprima.service.PrinterController
import dev.utatane.imprima.service.PrinterStatus
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn

class MainViewModel(app: Application) : AndroidViewModel(app) {
    val status: StateFlow<PrinterStatus> get() = PrinterController.status
    val config: StateFlow<PrinterConfig> get() = PrinterController.config

    private val jobStore get() = PrinterController.jobStore(getApplication())

    val jobs: StateFlow<List<PrintJob>> by lazy {
        jobStore.jobs.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), jobStore.jobs.value)
    }

    fun start() = PrinterController.start(getApplication())
    fun stop() = PrinterController.stop(getApplication())
    fun save(config: PrinterConfig) = PrinterController.updateConfig(getApplication(), config)
    fun delete(jobId: Int) = jobStore.delete(jobId)
    fun deleteAll() = jobStore.list().forEach { jobStore.delete(it.id) }
}
