package com.rasa.printer.service

import android.content.Context
import com.rasa.printer.printer.JobStore
import com.rasa.printer.printer.PrinterConfig
import kotlinx.coroutines.flow.StateFlow

enum class ServiceState { STOPPED, STARTING, RUNNING, ERROR }

data class PrinterStatus(
    val state: ServiceState = ServiceState.STOPPED,
    val port: Int = PrinterConfig.DEFAULT_PORT,
    /** IPv4 addresses of this device on local networks (for display). */
    val addresses: List<String> = emptyList(),
    val error: String? = null,
)

/**
 * Process-wide facade between UI and the foreground service. FROZEN INTERFACE.
 * All functions are safe to call from the main thread.
 */
object PrinterController {
    val status: StateFlow<PrinterStatus> get() = TODO("unit D")

    /** Persisted configuration (SharedPreferences). First access generates a default name + uuid. */
    val config: StateFlow<PrinterConfig> get() = TODO("unit D")

    /** Starts the foreground service (no-op if running). */
    fun start(context: Context): Unit = TODO("unit D")

    /** Stops the foreground service (no-op if stopped). */
    fun stop(context: Context): Unit = TODO("unit D")

    /** Persists [config]; if the service is running it is restarted with the new config. */
    fun updateConfig(context: Context, config: PrinterConfig): Unit = TODO("unit D")

    /** Process-wide JobStore singleton (file-backed under context.filesDir/jobs). */
    fun jobStore(context: Context): JobStore = TODO("unit D")
}
