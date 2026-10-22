package dev.rivet.session

/**
 * A platform NSD resolver's result. All fields are untrusted; an mDNS TXT
 * advertisement must not become a credential or authorize a device session.
 */
data class DeviceResolvedService(
    val serviceName: String,
    val host: String,
    val port: Int,
    val txtRecord: ByteArray?,
)

/**
 * Android's NsdManager supplies a resolver behind this boundary. It must
 * perform one service resolution without implicitly connecting to a host.
 * The callback may arrive after cancellation or after a newer selection.
 */
fun interface DeviceServiceResolutionDriver {
    fun resolve(
        serviceName: String,
        onResult: (DeviceResolvedService?) -> Unit,
    )
}

/** The validated endpoint metadata handed to explicit TLS pairing/reconnect. */
data class DeviceResolvedEndpoint(
    val host: String,
    val port: Int,
    val advertisementID: String,
    val pairingWindowOpen: Boolean,
)

/**
 * Resolves only an explicitly selected discovery candidate. An out-of-date,
 * malformed, changed, or missing DNS-SD result is rejected; the selected
 * service must still be in the current browser snapshot when resolution
 * completes. Only the last selection may complete. Repeated native callbacks
 * cannot trigger duplicate TLS attempts.
 *
 * This establishes a safe NSD resolution boundary, not the Android platform
 * driver itself. Consumers still choose whether to connect, enforce the
 * server SPKI pin, and complete RVD1 before sending RVT1 application bytes.
 */
class SelectedDeviceResolver(
    private val browser: DeviceDiscoveryBrowser,
    private val driver: DeviceServiceResolutionDriver,
) {
    private val lock = Any()
    private var generation = 0L
    private var delivered = false

    fun resolveSelected(
        selection: DeviceDiscovery,
        onResolved: (DeviceResolvedEndpoint?) -> Unit,
    ) {
        val token = synchronized(lock) {
            generation++
            delivered = false
            generation
        }
        if (browser.snapshot.none { it == selection }) {
            deliver(token, null, onResolved)
            return
        }
        try {
            driver.resolve(selection.serviceName) { result ->
                val endpoint = validate(selection, result)
                deliver(token, endpoint, onResolved)
            }
        } catch (_: RuntimeException) {
            // A broken platform resolver is failure, not an authorization
            // fallback to previously cached or externally supplied endpoints.
            deliver(token, null, onResolved)
        }
    }

    fun cancel() {
        synchronized(lock) {
            generation++
            delivered = false
        }
    }

    private fun validate(
        selection: DeviceDiscovery,
        result: DeviceResolvedService?,
    ): DeviceResolvedEndpoint? {
        if (result == null || result.serviceName != selection.serviceName ||
            result.host.isBlank() || result.port !in 1..65535
        ) {
            return null
        }
        val advertisement = try {
            result.txtRecord?.let(::decodeDiscoveryTXT)
        } catch (_: SessionProtocolException) {
            null
        } ?: return null
        if (advertisement.advertisementID != selection.advertisementID ||
            advertisement.pairingWindowOpen != selection.pairingWindowOpen ||
            browser.snapshot.none { it == selection }
        ) {
            return null
        }
        return DeviceResolvedEndpoint(
            host = result.host,
            port = result.port,
            advertisementID = advertisement.advertisementID,
            pairingWindowOpen = advertisement.pairingWindowOpen,
        )
    }

    private fun deliver(
        token: Long,
        value: DeviceResolvedEndpoint?,
        onResolved: (DeviceResolvedEndpoint?) -> Unit,
    ) {
        val isCurrent = synchronized(lock) {
            if (token != generation || delivered) {
                false
            } else {
                delivered = true
                true
            }
        }
        if (isCurrent) onResolved(value)
    }
}
