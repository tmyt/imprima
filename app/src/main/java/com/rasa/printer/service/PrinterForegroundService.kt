package com.rasa.printer.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ComponentName
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import com.rasa.printer.R
import com.rasa.printer.http.HttpServer
import com.rasa.printer.printer.IppHttpHandler
import com.rasa.printer.printer.IppPrinterHandler
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.concurrent.Executors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onEach

class PrinterForegroundService : Service() {
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "rasa-service").apply { isDaemon = true } }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var server: HttpServer? = null
    private var advertiser: NsdAdvertiser? = null
    private var port = PrinterController.config.value.port
    private var jobCount = 0
    @Volatile private var running = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        scope.launchJobObserver()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                // If we were started via startForegroundService, we must still enter foreground first.
                enterForeground()
                worker.execute { teardown(); finish() }
            }
            ACTION_RESTART -> {
                enterForeground()
                worker.execute { teardown(); bringUp() }
            }
            else -> {
                enterForeground()
                worker.execute { if (!running) bringUp() }
            }
        }
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.i(TAG, "Task removed; service keeps running")
    }

    override fun onDestroy() {
        scope.cancel()
        worker.execute { teardown() }
        worker.shutdown()
        val cur = PrinterController.status.value
        if (cur.state != ServiceState.ERROR) {
            PrinterController.publishStatus(cur.copy(state = ServiceState.STOPPED, addresses = emptyList(), error = null))
        }
        super.onDestroy()
    }

    private fun CoroutineScope.launchJobObserver() {
        PrinterController.jobStore(this@PrinterForegroundService).jobs
            .map { it.size }
            .onEach { n ->
                jobCount = n
                if (running) notifyUpdate()
            }
            .launchIn(this)
    }

    private fun bringUp() {
        val cfg = PrinterController.config.value
        port = cfg.port
        PrinterController.publishStatus(PrinterStatus(ServiceState.STARTING, cfg.port))
        notifyUpdate()
        try {
            val jobs = PrinterController.jobStore(this)
            val handler = IppPrinterHandler({ PrinterController.config.value }, jobs)
            val http = IppHttpHandler(handler, { PrinterController.config.value }, jobs) { PrinterIcon.png() }
            val srv = HttpServer(cfg.port, http)
            srv.start()
            server = srv
            advertiser = NsdAdvertiser(this, cfg, srv.boundPort).also { it.register() }
            running = true
            PrinterController.publishStatus(
                PrinterStatus(ServiceState.RUNNING, srv.boundPort, localAddresses(), null)
            )
            notifyUpdate()
            Log.i(TAG, "Printer running on port ${srv.boundPort}")
        } catch (e: Throwable) {
            Log.e(TAG, "Failed to start", e)
            teardown()
            PrinterController.publishStatus(
                PrinterStatus(ServiceState.ERROR, cfg.port, emptyList(), e.message ?: e.javaClass.simpleName)
            )
            finish(keepStatus = true)
        }
    }

    private fun teardown() {
        running = false
        try { advertiser?.unregister() } catch (e: Throwable) { Log.w(TAG, "nsd stop", e) }
        advertiser = null
        try { server?.stop() } catch (e: Throwable) { Log.w(TAG, "server stop", e) }
        server = null
    }

    private fun finish(keepStatus: Boolean = false) {
        if (!keepStatus) {
            PrinterController.publishStatus(PrinterStatus(ServiceState.STOPPED, port))
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun enterForeground() {
        val n = buildNotification()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
    }

    private fun notifyUpdate() {
        try {
            getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, buildNotification())
        } catch (e: Exception) {
            Log.w(TAG, "notify failed", e)
        }
    }

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(
            this, 0,
            Intent().setComponent(ComponentName(this, com.rasa.printer.ui.MainActivity::class.java))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stop = PendingIntent.getService(
            this, 1,
            Intent(this, PrinterForegroundService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_launcher)
            .setContentTitle(getString(R.string.notification_title, port))
            .setContentText(getString(R.string.notification_jobs, jobCount))
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .addAction(0, getString(R.string.notification_stop), stop)
            .build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            val ch = NotificationChannel(CHANNEL_ID, getString(R.string.notification_channel), NotificationManager.IMPORTANCE_LOW)
            getSystemService(NotificationManager::class.java).createNotificationChannel(ch)
        }
    }

    private fun localAddresses(): List<String> = try {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { it.inetAddresses.toList() }
            .filterIsInstance<Inet4Address>()
            .filter { !it.isLoopbackAddress && !it.isLinkLocalAddress }
            .mapNotNull { it.hostAddress }
            .distinct()
    } catch (e: Exception) {
        emptyList()
    }

    companion object {
        const val ACTION_START = "com.rasa.printer.action.START"
        const val ACTION_STOP = "com.rasa.printer.action.STOP"
        const val ACTION_RESTART = "com.rasa.printer.action.RESTART"
        private const val CHANNEL_ID = "printer"
        private const val NOTIFICATION_ID = 1
        private const val TAG = "RasaPrinter"
    }
}
