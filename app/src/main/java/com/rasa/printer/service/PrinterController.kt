package com.rasa.printer.service

import android.app.Application
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import com.rasa.printer.printer.JobStore
import com.rasa.printer.printer.PrinterConfig
import java.io.File
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

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
    @Volatile private var appContext: Context? = null
    private val lock = Any()
    private val _status = MutableStateFlow(PrinterStatus())
    private var _config: MutableStateFlow<PrinterConfig>? = null
    private var store: JobStore? = null

    val status: StateFlow<PrinterStatus> get() = _status.asStateFlow()

    /** Persisted configuration (SharedPreferences). First access generates a default name + uuid. */
    val config: StateFlow<PrinterConfig> get() = configFlow(null).asStateFlow()

    /** Called from [com.rasa.printer.PrinterApp.onCreate]. */
    internal fun attach(app: Application) {
        appContext = app
    }

    /** Starts the foreground service (no-op if running). */
    fun start(context: Context) {
        val ctx = context.applicationContext
        val cfg = configFlow(ctx).value
        synchronized(lock) {
            val s = _status.value.state
            if (s == ServiceState.STARTING || s == ServiceState.RUNNING) return
            _status.value = PrinterStatus(ServiceState.STARTING, cfg.port)
        }
        ContextCompat.startForegroundService(ctx, serviceIntent(ctx, PrinterForegroundService.ACTION_START))
    }

    /** Stops the foreground service (no-op if stopped). */
    fun stop(context: Context) {
        val ctx = context.applicationContext
        val s = _status.value.state
        if (s == ServiceState.STOPPED) return
        if (s == ServiceState.ERROR) {
            _status.value = PrinterStatus(ServiceState.STOPPED, _status.value.port)
            return
        }
        ctx.startService(serviceIntent(ctx, PrinterForegroundService.ACTION_STOP))
    }

    /** Persists [config]; if the service is running it is restarted with the new config. */
    fun updateConfig(context: Context, config: PrinterConfig) {
        val ctx = context.applicationContext
        val flow = configFlow(ctx)
        val fixed = config.copy(port = PrinterPrefs.validPort(config.port))
        PrinterPrefs.save(ctx, fixed)
        flow.value = fixed
        val s = _status.value.state
        if (s == ServiceState.RUNNING || s == ServiceState.STARTING) {
            _status.value = _status.value.copy(state = ServiceState.STARTING, port = fixed.port)
            ctx.startService(serviceIntent(ctx, PrinterForegroundService.ACTION_RESTART))
        }
    }

    /** Process-wide JobStore singleton (file-backed under context.filesDir/jobs). */
    fun jobStore(context: Context): JobStore = synchronized(lock) {
        store ?: FileJobStore(File(context.applicationContext.filesDir, "jobs")).also { store = it }
    }

    internal fun publishStatus(status: PrinterStatus) {
        _status.value = status
    }

    private fun serviceIntent(ctx: Context, action: String) =
        Intent(ctx, PrinterForegroundService::class.java).setAction(action)

    private fun configFlow(context: Context?): MutableStateFlow<PrinterConfig> = synchronized(lock) {
        _config ?: run {
            val ctx = context?.applicationContext ?: appContext
                ?: error("PrinterController not attached; PrinterApp must be the Application class")
            MutableStateFlow(PrinterPrefs.load(ctx)).also { _config = it }
        }
    }
}
