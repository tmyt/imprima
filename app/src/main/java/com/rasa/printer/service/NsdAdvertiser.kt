package com.rasa.printer.service

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.util.Log
import com.rasa.printer.printer.PrinterConfig

/** Advertises the printer over DNS-SD as `_ipp._tcp` (+ AirPrint `_universal` subtype). */
class NsdAdvertiser(
    context: Context,
    private val config: PrinterConfig,
    private val port: Int,
) {
    private val appContext = context.applicationContext
    private val lock = Any()
    private var listener: NsdManager.RegistrationListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    fun register() {
        synchronized(lock) {
            if (listener != null) return
            try {
                val wifi = appContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                multicastLock = wifi?.createMulticastLock("rasa-printer")?.apply {
                    setReferenceCounted(false)
                    acquire()
                }
            } catch (e: Exception) {
                Log.w(TAG, "Multicast lock failed", e)
            }
            val nsd = appContext.getSystemService(Context.NSD_SERVICE) as? NsdManager
            if (nsd == null) { Log.w(TAG, "No NsdManager"); return }
            val info = NsdServiceInfo().apply {
                serviceName = config.name
                serviceType = "_ipp._tcp"
                port = this@NsdAdvertiser.port
                txt().forEach { (k, v) -> setAttribute(k, v) }
                if (Build.VERSION.SDK_INT >= 33) subtypes = setOf("universal", "print")
            }
            val l = object : NsdManager.RegistrationListener {
                override fun onServiceRegistered(i: NsdServiceInfo) {
                    Log.i(TAG, "NSD registered as '${i.serviceName}' on port $port")
                }
                override fun onRegistrationFailed(i: NsdServiceInfo, errorCode: Int) {
                    Log.e(TAG, "NSD registration failed: $errorCode")
                }
                override fun onServiceUnregistered(i: NsdServiceInfo) {
                    Log.i(TAG, "NSD unregistered '${i.serviceName}'")
                }
                override fun onUnregistrationFailed(i: NsdServiceInfo, errorCode: Int) {
                    Log.w(TAG, "NSD unregistration failed: $errorCode")
                }
            }
            try {
                nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, l)
                listener = l
            } catch (e: Exception) {
                Log.e(TAG, "registerService threw", e)
            }
        }
    }

    fun unregister() {
        synchronized(lock) {
            val l = listener
            listener = null
            if (l != null) {
                try {
                    (appContext.getSystemService(Context.NSD_SERVICE) as? NsdManager)?.unregisterService(l)
                } catch (e: Exception) {
                    Log.w(TAG, "unregisterService failed", e)
                }
            }
            try { multicastLock?.takeIf { it.isHeld }?.release() } catch (e: Exception) { Log.w(TAG, "release failed", e) }
            multicastLock = null
        }
    }

    private fun txt(): Map<String, String> {
        val m = linkedMapOf(
            "txtvers" to "1",
            "qtotal" to "1",
            "rp" to "ipp/print",
            "ty" to config.name,
            "product" to "(${config.makeAndModel})",
            "pdl" to "application/pdf,image/pwg-raster,image/urf,image/jpeg,image/png",
            "URF" to "V1.4,W8,SRGB24,CP1,RS300-600,IS1,MT1-2-3,OB9,PQ3-4-5,DM1",
            "Color" to "T",
            "Duplex" to "F",
            "Scan" to "F",
            "Fax" to "F",
            "kind" to "document",
            "UUID" to config.uuid,
            "priority" to "0",
        )
        if (config.location.isNotEmpty()) m["note"] = config.location
        return m
    }

    private companion object { const val TAG = "RasaPrinter" }
}
