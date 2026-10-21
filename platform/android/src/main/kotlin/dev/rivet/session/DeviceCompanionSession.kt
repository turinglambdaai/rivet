package dev.rivet.session

import java.io.Closeable
import java.io.InputStream
import java.io.OutputStream
import java.security.SecureRandom
import java.util.Date
import javax.net.ssl.SSLHandshakeException

/** A user-selected, resolved service endpoint. Discovery is not authentication. */
data class DeviceCompanionEndpoint(val host: String, val port: Int) {
    init {
        require(host.isNotBlank()) { "an explicit selected host is required" }
        require(port in 1..65535) { "invalid selected device port" }
    }
}

/** No fallback from a failed reconnect to unauthenticated pairing. */
sealed interface DeviceCompanionIntent {
    class Reconnect(
        val applicationID: String,
        val deviceID: SessionUuid,
        credential: ByteArray,
        serverFingerprint: ByteArray,
    ) : DeviceCompanionIntent {
        private val storedCredential = credential.copyOf()
        private val storedFingerprint = serverFingerprint.copyOf()
        val credential: ByteArray get() = storedCredential.copyOf()
        val serverFingerprint: ByteArray get() = storedFingerprint.copyOf()
    }

    data class Pair(
        val applicationID: String,
        val windowID: SessionUuid,
        val deviceName: String,
    ) : DeviceCompanionIntent
}

/** The owned TLS stream used by the session runner, replaceable in JVM tests. */
interface DeviceCompanionTransport : Closeable {
    val serverFingerprint: ByteArray
    val input: InputStream
    val output: OutputStream
}

fun interface DeviceCompanionDialer {
    fun connect(
        endpoint: DeviceCompanionEndpoint,
        authentication: DeviceServerAuthentication,
    ): DeviceCompanionTransport
}

private val systemDeviceCompanionDialer = DeviceCompanionDialer { endpoint, authentication ->
    val connection = DeviceTLSClient.connect(
        endpoint.host, endpoint.port, authentication,
    )
    object : DeviceCompanionTransport {
        override val serverFingerprint: ByteArray
            get() = connection.serverFingerprint
        override val input: InputStream
            get() = connection.input
        override val output: OutputStream
            get() = connection.output
        override fun close() = connection.close()
    }
}

/**
 * One explicit Android companion connection attempt. Run on a background
 * thread: dial, verify the exact TLS identity or explicit provisional-pairing
 * mode, and drive RVD1 before lending the original streams to the product's
 * RVT1 client. Product code owns NSD resolution, secure credential storage,
 * the UI, and the RVT1 client lifecycle; it must call close() on disconnect.
 *
 * A failed pinned reconnect never silently retries with provisional trust.
 * A paired session only reaches the handler after RVD1 dual approval and
 * successful credential persistence. No application bytes are read here.
 */
class DeviceCompanionSession(
    private val endpoint: DeviceCompanionEndpoint,
    private val intent: DeviceCompanionIntent,
    private val credentialStore: SessionCredentialStore? = null,
    private val onPairingCode: ((DevicePairingCode) -> Unit)? = null,
    private val onAccepted: (SessionAcceptance, InputStream, OutputStream) -> Unit,
    private val dialer: DeviceCompanionDialer = systemDeviceCompanionDialer,
    private val nonceGenerator: () -> ByteArray = {
        ByteArray(SESSION_NONCE_SIZE).also { SecureRandom().nextBytes(it) }
    },
) : Closeable {
    private val lock = Any()
    private var started = false
    private var cancelled = false
    private var transport: DeviceCompanionTransport? = null
    private var runner: SessionClientRunner? = null

    fun run(): SessionAcceptance {
        synchronized(lock) {
            check(!started) { "a Rivet companion session cannot be restarted" }
            started = true
            if (cancelled) throw SessionClientRunner.SessionClientFailureException(
                SessionClientRunner.SessionClientFailure.CANCELLED,
            )
        }

        val authentication = when (intent) {
            is DeviceCompanionIntent.Reconnect ->
                DeviceServerAuthentication.Pinned(intent.serverFingerprint)
            is DeviceCompanionIntent.Pair ->
                DeviceServerAuthentication.ProvisionalPairing
        }

        var acquired: DeviceCompanionTransport? = null
        var accepted = false
        try {
            val candidate = dialer.connect(endpoint, authentication)
            acquired = candidate
            val cancelledBeforeRunner = synchronized(lock) {
                transport = candidate
                cancelled
            }
            if (cancelledBeforeRunner) throw SessionClientRunner.SessionClientFailureException(
                SessionClientRunner.SessionClientFailure.CANCELLED,
            )
            val observedFingerprint = candidate.serverFingerprint.copyOf()
            if (!authentication.permits(observedFingerprint)) {
                throw SSLHandshakeException("Rivet companion peer fingerprint does not match TLS policy")
            }

            val nonce = nonceGenerator()
            require(nonce.size == SESSION_NONCE_SIZE) { "client nonce must contain 32 bytes" }
            val worker = SessionClientRunner(
                input = candidate.input,
                output = candidate.output,
                clientFactory = { startedAt: Date ->
                    when (intent) {
                        is DeviceCompanionIntent.Reconnect -> DeviceSessionClient.forReconnect(
                            applicationID = intent.applicationID,
                            deviceID = intent.deviceID,
                            credential = intent.credential.copyOf(),
                            serverFingerprint = observedFingerprint,
                            clientNonce = nonce.copyOf(),
                            startedAt = startedAt,
                        )
                        is DeviceCompanionIntent.Pair -> DeviceSessionClient.forPairing(
                            applicationID = intent.applicationID,
                            windowID = intent.windowID,
                            deviceName = intent.deviceName,
                            serverFingerprint = observedFingerprint,
                            clientNonce = nonce.copyOf(),
                            startedAt = startedAt,
                        )
                    }
                },
                credentialStore = credentialStore,
                pairingCodeHandler = onPairingCode,
                applicationHandler = onAccepted,
            )
            val shouldCancel = synchronized(lock) {
                runner = worker
                cancelled
            }
            if (shouldCancel) {
                worker.cancel()
            }
            val result = worker.run()
            accepted = true
            return result
        } finally {
            if (!accepted) {
                synchronized(lock) {
                    if (transport === acquired) transport = null
                    runner = null
                }
                runCatching { acquired?.close() }
            }
        }
    }

    /** User decision only; never infer consent from discovery or TLS success. */
    fun confirmPairingOnDevice(confirmed: Boolean) {
        val current = synchronized(lock) { runner }
            ?: throw IllegalStateException("Rivet device pairing has not started")
        current.confirmPairingOnDesktop(confirmed)
    }

    /** Cancel a pending RVD1 read and tear down the owned TLS connection. */
    override fun close() {
        val currentRunner: SessionClientRunner?
        val currentTransport: DeviceCompanionTransport?
        synchronized(lock) {
            if (cancelled) return
            cancelled = true
            currentRunner = runner
            currentTransport = transport
            runner = null
            transport = null
        }
        currentRunner?.cancel()
        runCatching { currentTransport?.close() }
    }
}
