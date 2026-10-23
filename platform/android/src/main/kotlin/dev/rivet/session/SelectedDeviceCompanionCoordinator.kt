package dev.rivet.session

import java.io.Closeable
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.Executor

/** A selection or lifecycle rejection, never an alternative trust path. */
enum class DeviceSelectionFailure {
    STALE_SELECTION,
    PAIRING_WINDOW_CLOSED,
    CANCELLED,
}

class DeviceSelectionException(val failure: DeviceSelectionFailure) :
    IllegalStateException("Rivet selected device connection rejected: $failure")

/**
 * Turns one user-selected live NSD candidate into one TLS/RVD1 connection.
 *
 * Resolution may finish on an Android NSD callback thread. Actual TLS and
 * blocking RVD1 I/O run only on the product-supplied [worker] executor.
 * An authenticated stream reaches [onAccepted] only via the underlying
 * DeviceCompanionSession's persistence and confirmation gates.
 *
 * Own this coordinator through the connection lifecycle and close it on
 * navigation away, discovery shutdown, or disconnect. The caller must not
 * treat the advertisement ID as a pin or auto-retry failed reconnects.
 */
class SelectedDeviceCompanionCoordinator(
    private val browser: DeviceDiscoveryBrowser,
    resolutionDriver: DeviceServiceResolutionDriver,
    private val worker: Executor,
    private val credentialStore: SessionCredentialStore? = null,
    private val onPairingCode: ((DevicePairingCode) -> Unit)? = null,
    private val onAccepted: (SessionAcceptance, InputStream, OutputStream) -> Unit,
    private val dialer: DeviceCompanionDialer = systemDeviceCompanionDialer,
) : Closeable {
    private val resolver = SelectedDeviceResolver(browser, resolutionDriver)
    private val lock = Any()
    private var started = false
    private var closed = false
    private var finished = false
    private var current: DeviceCompanionSession? = null
    private var callback: ((Result<SessionAcceptance>) -> Unit)? = null

    /** Single-flight: a new user selection requires a new coordinator. */
    fun connectSelected(
        selection: DeviceDiscovery,
        intent: DeviceCompanionIntent,
        onFinished: (Result<SessionAcceptance>) -> Unit,
    ) {
        synchronized(lock) {
            check(!started && !closed) { "Rivet companion selection is single-use" }
            started = true
            callback = onFinished
        }
        if (browser.snapshot.none { it.namesSelectedDevice(selection) }) {
            complete(Result.failure(DeviceSelectionException(DeviceSelectionFailure.STALE_SELECTION)))
            return
        }
        if (intent is DeviceCompanionIntent.Pair && !selection.pairingWindowOpen) {
            complete(Result.failure(DeviceSelectionException(DeviceSelectionFailure.PAIRING_WINDOW_CLOSED)))
            return
        }
        resolver.resolveSelected(selection) { endpoint ->
            if (!isPending()) return@resolveSelected
            if (endpoint == null) {
                complete(Result.failure(DeviceSelectionException(DeviceSelectionFailure.STALE_SELECTION)))
                return@resolveSelected
            }
            try {
                worker.execute {
                    if (!isPending()) return@execute
                    // Discovery may change between the native resolution
                    // callback and this worker actually starting the dial.
                    // The pairing-window bit flips independently of device
                    // presence, so staleness matches stable identity and the
                    // window is judged from the fresh advertisement.
                    val fresh = browser.snapshot.firstOrNull { it.namesSelectedDevice(selection) }
                    if (fresh == null) {
                        complete(Result.failure(DeviceSelectionException(DeviceSelectionFailure.STALE_SELECTION)))
                        return@execute
                    }
                    if (intent is DeviceCompanionIntent.Pair && !fresh.pairingWindowOpen) {
                        complete(Result.failure(DeviceSelectionException(DeviceSelectionFailure.PAIRING_WINDOW_CLOSED)))
                        return@execute
                    }
                    val session = try {
                        DeviceCompanionSession(
                            endpoint = DeviceCompanionEndpoint(endpoint.host, endpoint.port),
                            intent = intent,
                            credentialStore = credentialStore,
                            onPairingCode = onPairingCode,
                            onAccepted = onAccepted,
                            dialer = dialer,
                        )
                    } catch (failure: Throwable) {
                        // A rejected endpoint or session configuration must
                        // still resolve the caller's callback instead of
                        // killing the shared worker thread.
                        complete(Result.failure(failure))
                        return@execute
                    }
                    val abandoned = synchronized(lock) {
                        if (closed || finished) true else {
                            current = session
                            false
                        }
                    }
                    if (abandoned) {
                        session.close()
                        return@execute
                    }
                    try {
                        val accepted = session.run()
                        complete(Result.success(accepted))
                    } catch (failure: Throwable) {
                        session.close()
                        complete(Result.failure(failure))
                    }
                }
            } catch (failure: RuntimeException) {
                complete(Result.failure(failure))
            }
        }
    }

    /** A separate user decision, never inferred from the discovery result. */
    fun confirmPairingOnDevice(confirmed: Boolean) {
        val session = synchronized(lock) { current }
            ?: throw IllegalStateException("Rivet selected pairing has not started")
        session.confirmPairingOnDevice(confirmed)
    }

    private fun isPending(): Boolean = synchronized(lock) { started && !closed && !finished }

    private fun complete(result: Result<SessionAcceptance>) {
        val notify = synchronized(lock) {
            if (finished) null else {
                finished = true
                callback.also { callback = null }
            }
        }
        notify?.invoke(result)
    }

    /** Idempotent and effective while resolving, queued, dialing, or connected. */
    override fun close() {
        val session: DeviceCompanionSession?
        synchronized(lock) {
            if (closed) return
            closed = true
            session = current
            current = null
        }
        resolver.cancel()
        session?.close()
        complete(Result.failure(DeviceSelectionException(DeviceSelectionFailure.CANCELLED)))
    }
}
