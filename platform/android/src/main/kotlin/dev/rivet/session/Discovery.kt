package dev.rivet.session

// The privacy-bounded discovery advertisement shared by every Rivet
// companion platform: a DNS-SD TXT record carrying only the session
// protocol version, a per-listener ephemeral identifier, and the
// pairing-window bit. Decoding is canonical — a record must re-encode to
// the exact same bytes — so advertisements from any platform are
// byte-identical for the same logical content.

const val DEVICE_DISCOVERY_SERVICE_TYPE = "_rivet-device._tcp"
const val DEVICE_DISCOVERY_MAXIMUM_TXT_RECORD_SIZE = 128

data class DeviceAdvertisement(
    val advertisementID: String,
    val pairingWindowOpen: Boolean,
) {
    val protocolVersion: Int = SESSION_VERSION

    init {
        if (!validDiscoveryAdvertisementID(advertisementID)) {
            throw SessionProtocolException(
                SessionProtocolFailure.INVALID_FIELD,
                "invalid Rivet device advertisement identifier",
            )
        }
    }
}

fun validDiscoveryAdvertisementID(value: String): Boolean =
    value.length == 32 && value.all { it in '0'..'9' || it in 'a'..'f' }

/** Canonical wire form: `id=…`, `pair=…`, `v=…`, RFC 6763 TXT encoding. */
fun encodeDiscoveryTXT(advertisement: DeviceAdvertisement): ByteArray {
    if (!validDiscoveryAdvertisementID(advertisement.advertisementID)) {
        throw SessionProtocolException(SessionProtocolFailure.INVALID_FIELD, "invalid Rivet device advertisement identifier")
    }
    val entries = listOf(
        "id=${advertisement.advertisementID}",
        "pair=${if (advertisement.pairingWindowOpen) "1" else "0"}",
        "v=${advertisement.protocolVersion}",
    )
    var record = ByteArray(0)
    for (entry in entries) {
        val encoded = entry.encodeToByteArray()
        if (encoded.size > 255) {
            throw SessionProtocolException(SessionProtocolFailure.RECORD_TOO_LARGE, "Rivet device discovery TXT entry is too large")
        }
        record += byteArrayOf(encoded.size.toByte()) + encoded
    }
    if (record.size > DEVICE_DISCOVERY_MAXIMUM_TXT_RECORD_SIZE) {
        throw SessionProtocolException(SessionProtocolFailure.RECORD_TOO_LARGE, "Rivet device discovery TXT record is too large")
    }
    return record
}

/** Throws on any deviation from the canonical encoding. */
fun decodeDiscoveryTXT(txtRecord: ByteArray): DeviceAdvertisement {
    if (txtRecord.isEmpty()) {
        throw SessionProtocolException(SessionProtocolFailure.MALFORMED_PAYLOAD, "invalid Rivet device discovery TXT record")
    }
    if (txtRecord.size > DEVICE_DISCOVERY_MAXIMUM_TXT_RECORD_SIZE) {
        throw SessionProtocolException(SessionProtocolFailure.RECORD_TOO_LARGE, "Rivet device discovery TXT record is too large")
    }
    val fields = LinkedHashMap<String, String>()
    var offset = 0
    while (offset < txtRecord.size) {
        val length = txtRecord[offset].toInt() and 0xff
        offset += 1
        if (length == 0 || offset + length > txtRecord.size) {
            throw SessionProtocolException(SessionProtocolFailure.MALFORMED_PAYLOAD, "invalid Rivet device discovery TXT record")
        }
        val entry = try {
            String(txtRecord, offset, length, Charsets.UTF_8)
        } catch (_: Exception) {
            throw SessionProtocolException(SessionProtocolFailure.MALFORMED_PAYLOAD, "invalid Rivet device discovery TXT record")
        }
        val separator = entry.indexOf('=')
        if (separator <= 0) {
            throw SessionProtocolException(SessionProtocolFailure.MALFORMED_PAYLOAD, "invalid Rivet device discovery TXT record")
        }
        val key = entry.substring(0, separator)
        if (fields.containsKey(key)) {
            throw SessionProtocolException(SessionProtocolFailure.MALFORMED_PAYLOAD, "invalid Rivet device discovery TXT record")
        }
        fields[key] = entry.substring(separator + 1)
        offset += length
    }
    if (fields.size != 3) {
        throw SessionProtocolException(SessionProtocolFailure.MALFORMED_PAYLOAD, "invalid Rivet device discovery TXT record")
    }
    val versionText = fields["v"]
        ?: throw SessionProtocolException(SessionProtocolFailure.MALFORMED_PAYLOAD, "invalid Rivet device discovery TXT record")
    val advertisementID = fields["id"]
        ?: throw SessionProtocolException(SessionProtocolFailure.MALFORMED_PAYLOAD, "invalid Rivet device discovery TXT record")
    val pairingText = fields["pair"]
        ?: throw SessionProtocolException(SessionProtocolFailure.MALFORMED_PAYLOAD, "invalid Rivet device discovery TXT record")
    if (pairingText != "0" && pairingText != "1") {
        throw SessionProtocolException(SessionProtocolFailure.MALFORMED_PAYLOAD, "invalid Rivet device discovery TXT record")
    }
    if (versionText != SESSION_VERSION.toString()) {
        throw SessionProtocolException(
            SessionProtocolFailure.UNSUPPORTED_VERSION,
            "unsupported Rivet device discovery advertisement version $versionText",
        )
    }
    val advertisement = DeviceAdvertisement(advertisementID, pairingText == "1")
    if (!encodeDiscoveryTXT(advertisement).contentEquals(txtRecord)) {
        throw SessionProtocolException(SessionProtocolFailure.MALFORMED_PAYLOAD, "invalid Rivet device discovery TXT record")
    }
    return advertisement
}

/** A discovery result is only an unauthenticated connection candidate. */
data class DeviceDiscovery(
    val serviceName: String,
    val advertisementID: String,
    val pairingWindowOpen: Boolean,
)

enum class DeviceDiscoveryEventKind { ADDED, REMOVED }

/**
 * A platform supplies this from its own discovery stack (NSD on Android):
 * canonical TXT records in, lifecycle events out. Discovery never opens a
 * connection and never grants authority.
 */
interface DeviceDiscoveryDriver {
    fun start(onResult: (serviceName: String, txtRecord: ByteArray?, removed: Boolean) -> Unit)
    fun stop()
}

/**
 * Bounded browser over a discovery driver: only canonical advertisements
 * become candidates, vanished results are removed, and the candidate set
 * is capped. Repeated stops are idempotent.
 */
class DeviceDiscoveryBrowser(
    private val driver: DeviceDiscoveryDriver,
    private val maximumDiscoveries: Int = 128,
    private val onEvent: (kind: DeviceDiscoveryEventKind, discovery: DeviceDiscovery) -> Unit,
) {
    private val discoveries = LinkedHashMap<String, DeviceDiscovery>()
    private var running = false
    // A previous discovery driver can deliver a queued callback after restart.
    // Only the generation that registered the callback may update candidates.
    private var discoveryGeneration = 0L

    val snapshot: List<DeviceDiscovery>
        get() = synchronized(this) { discoveries.values.toList() }

    fun start() {
        val generation = synchronized(this) {
            if (running) return
            running = true
            ++discoveryGeneration
        }
        driver.start { serviceName, txtRecord, removed ->
            synchronized(this) {
                if (!running || generation != discoveryGeneration) return@synchronized
                if (removed) {
                    discoveries.remove(serviceName)?.let { onEvent(DeviceDiscoveryEventKind.REMOVED, it) }
                    return@synchronized
                }
                if (txtRecord == null) return@synchronized
                val advertisement = try {
                    decodeDiscoveryTXT(txtRecord)
                } catch (_: SessionProtocolException) {
                    return@synchronized
                }
                val discovery = DeviceDiscovery(
                    serviceName,
                    advertisement.advertisementID,
                    advertisement.pairingWindowOpen,
                )
                val previous = discoveries[serviceName]
                if (previous != null) {
                    if (previous != discovery) {
                        discoveries[serviceName] = discovery
                        onEvent(DeviceDiscoveryEventKind.REMOVED, previous)
                        onEvent(DeviceDiscoveryEventKind.ADDED, discovery)
                    }
                    return@synchronized
                }
                if (discoveries.size >= maximumDiscoveries) {
                    fail()
                    return@synchronized
                }
                discoveries[serviceName] = discovery
                onEvent(DeviceDiscoveryEventKind.ADDED, discovery)
            }
        }
    }

    fun stop() {
        var removals: List<DeviceDiscovery> = emptyList()
        synchronized(this) {
            if (!running) return
            running = false
            discoveryGeneration++
            removals = discoveries.values.toList()
            discoveries.clear()
        }
        driver.stop()
        removals.forEach { onEvent(DeviceDiscoveryEventKind.REMOVED, it) }
    }

    private fun fail() {
        running = false
        discoveryGeneration++
        driver.stop()
        val removals = discoveries.values.toList()
        discoveries.clear()
        removals.forEach { onEvent(DeviceDiscoveryEventKind.REMOVED, it) }
    }
}
