package com.rasa.printer.service

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.ext.SdkExtensions
import android.util.Log
import com.rasa.printer.printer.PrinterAttributes
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
            val withSubtypes = Build.VERSION.SDK_INT >= 33
            registerVariant(nsd, withSubtypes)
        }
    }

    // Must hold lock.
    private fun registerVariant(nsd: NsdManager, withSubtypes: Boolean) {
        val info = NsdServiceInfo().apply {
            serviceName = config.name
            serviceType = "_ipp._tcp"
            port = this@NsdAdvertiser.port
            PrinterAttributes.bonjourTxt(config).forEach { (k, v) -> setAttribute(k, v) }
            if (withSubtypes && Build.VERSION.SDK_INT >= 33 && SdkExtensions.getExtensionVersion(Build.VERSION_CODES.TIRAMISU) >= 12) {
                subtypes = if (config.compatibilityMode) setOf("_universal", "_print") else setOf("_print")
            }
        }
        val variant = if (withSubtypes) "with subtypes" else "without subtypes"
        val l = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(i: NsdServiceInfo) {
                Log.i(TAG, "NSD registered ($variant) as '${i.serviceName}' on port $port")
            }
            override fun onRegistrationFailed(i: NsdServiceInfo, errorCode: Int) {
                Log.e(TAG, "NSD registration failed ($variant): $errorCode")
                if (withSubtypes) {
                    synchronized(lock) {
                        if (listener === this) {
                            listener = null
                            try { registerVariant(nsd, false) } catch (e: Exception) { Log.e(TAG, "retry threw", e) }
                        }
                    }
                }
            }
            override fun onServiceUnregistered(i: NsdServiceInfo) {
                Log.i(TAG, "NSD unregistered '${i.serviceName}'")
            }
            override fun onUnregistrationFailed(i: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "NSD unregistration failed: $errorCode")
            }
        }
        try {
            listener = l
            nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, l)
        } catch (e: Exception) {
            listener = null
            Log.e(TAG, "registerService threw ($variant)", e)
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

    private companion object { const val TAG = "RasaPrinter" }
}
