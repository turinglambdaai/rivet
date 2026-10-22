package dev.rivet.session

import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo

/**
 * Android SDK NSD implementation. Discovery only produces unauthenticated
 * candidates. The product still owns local-network permission UI, lifecycle,
 * explicit selection, secure storage, TLS pinning and RVD1 confirmation.
 *
 * Uses the legacy resolveService overload for API 29+ compatibility; Android
 * SDK 34+ also provides a continuous ServiceInfoCallback API.
 */
class AndroidNsdDriver(private val manager: NsdManager) :
    DeviceDiscoveryDriver, DeviceServiceResolutionDriver {
    private val lock = Any()
    private var generation = 0L
    private var sequence = 0L
    private var listener: NsdManager.DiscoveryListener? = null
    private var callback: ((String, ByteArray?, Boolean) -> Unit)? = null
    private val known = mutableMapOf<String, NsdServiceInfo>()
    private val tickets = mutableMapOf<String, Long>()

    override fun start(onResult: (String, ByteArray?, Boolean) -> Unit) {
        val current: Long
        val active: NsdManager.DiscoveryListener
        synchronized(lock) {
            check(listener == null) { "NSD discovery already started" }
            current = ++generation
            callback = onResult
            known.clear()
            tickets.clear()
            active = object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(serviceType: String) = Unit
                override fun onDiscoveryStopped(serviceType: String) = Unit

                override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                    if (!correctServiceType(serviceInfo.serviceType)) return
                    val name = serviceInfo.serviceName
                    if (name.isBlank()) return
                    val token = synchronized(lock) {
                        if (current != generation || listener !== this ||
                            (known.size >= 128 && name !in known)) null
                        else {
                            known[name] = serviceInfo
                            (++sequence).also { tickets[name] = it }
                        }
                    } ?: return
                    // A discovered service's TXT/endpoint fields may not be
                    // available until resolution. Never assume them present.
                    try {
                        manager.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                                emit(current, name, token, null)
                            }
                            override fun onServiceResolved(info: NsdServiceInfo) {
                                val txt = if (info.serviceName == name &&
                                    correctServiceType(info.serviceType))
                                    deviceDiscoveryTXTFromAttributes(info.attributes)
                                else null
                                emit(current, name, token, txt)
                            }
                        })
                    } catch (_: RuntimeException) {
                        emit(current, name, token, null)
                    }
                }

                override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                    val name = serviceInfo.serviceName
                    val send = synchronized(lock) {
                        if (current != generation || listener !== this) null
                        else {
                            known.remove(name)
                            tickets.remove(name)
                            callback
                        }
                    }
                    send?.invoke(name, null, true)
                }
                override fun onStartDiscoveryFailed(type: String, code: Int) {
                    fail(current, this)
                }
                override fun onStopDiscoveryFailed(type: String, code: Int) {
                    fail(current, this)
                }
            }
            listener = active
        }
        try {
            manager.discoverServices("_rivet-device._tcp.", NsdManager.PROTOCOL_DNS_SD, active)
        } catch (error: RuntimeException) {
            fail(current, active)
            throw error
        }
    }

    override fun stop() {
        val previous = synchronized(lock) {
            generation++
            listener.also {
                listener = null
                callback = null
                known.clear()
                tickets.clear()
            }
        }
        if (previous != null) try {
            manager.stopServiceDiscovery(previous)
        } catch (_: IllegalArgumentException) {
            // Android already discarded the discovery registration.
        } catch (_: IllegalStateException) {
            // Android already discarded the discovery registration.
        }
    }

    override fun resolve(serviceName: String, onResult: (DeviceResolvedService?) -> Unit) {
        val selected = synchronized(lock) {
            known[serviceName]?.let { Pair(generation, it) }
        }
        if (selected == null) {
            onResult(null)
            return
        }
        try {
            manager.resolveService(selected.second, object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                    onResult(null)
                }
                override fun onServiceResolved(info: NsdServiceInfo) {
                    val stillCurrent = synchronized(lock) {
                        selected.first == generation && known[serviceName] === selected.second
                    }
                    if (!stillCurrent || info.serviceName != serviceName ||
                        !correctServiceType(info.serviceType)) {
                        onResult(null)
                        return
                    }
                    val txt = deviceDiscoveryTXTFromAttributes(info.attributes)
                    val host = info.host?.hostAddress
                    onResult(if (txt != null && !host.isNullOrBlank() && info.port in 1..65535)
                        DeviceResolvedService(serviceName, host, info.port, txt)
                    else null)
                }
            })
        } catch (_: RuntimeException) {
            onResult(null)
        }
    }

    private fun emit(current: Long, name: String, token: Long, txt: ByteArray?) {
        val send = synchronized(lock) {
            if (generation == current && tickets[name] == token) callback else null
        }
        send?.invoke(name, txt, txt == null)
    }

    private fun fail(current: Long, active: NsdManager.DiscoveryListener) {
        val names: List<String>
        val send: ((String, ByteArray?, Boolean) -> Unit)?
        synchronized(lock) {
            if (current != generation || listener !== active) return
            generation++
            names = known.keys.toList()
            send = callback
            listener = null
            callback = null
            tickets.clear()
            known.clear()
        }
        names.forEach { send?.invoke(it, null, true) }
    }

    private fun correctServiceType(type: String): Boolean =
        type.removeSuffix(".").removeSuffix(".local") == DEVICE_DISCOVERY_SERVICE_TYPE
}
