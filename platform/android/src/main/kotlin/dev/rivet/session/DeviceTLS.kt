package dev.rivet.session

import java.io.Closeable
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509TrustManager

const val DEVICE_TLS_APPLICATION_PROTOCOL = "rivet-device/1"
const val DEVICE_TLS_CONNECT_TIMEOUT_MILLIS = 30_000

/**
 * A reconnect must supply the exact stored server SPKI fingerprint. A
 * provisional TLS identity is permitted only for an explicitly requested
 * foreground pairing; the RVD1 short code must still be confirmed by both
 * users before the device can persist credentials or send RVT1 traffic.
 */
sealed interface DeviceServerAuthentication {
    class Pinned(fingerprint: ByteArray) : DeviceServerAuthentication {
        private val expected = fingerprint.copyOf()

        init {
            require(expected.size == SESSION_FINGERPRINT_SIZE) {
                "a Rivet device server pin must contain 32 bytes"
            }
        }

        internal fun matches(observed: ByteArray): Boolean =
            MessageDigest.isEqual(expected, observed)
    }

    data object ProvisionalPairing : DeviceServerAuthentication
}

internal fun spkiFingerprint(encodedSPKI: ByteArray): ByteArray {
    require(encodedSPKI.isNotEmpty()) { "server SPKI must not be empty" }
    return MessageDigest.getInstance("SHA-256").digest(encodedSPKI)
}

internal fun DeviceServerAuthentication.permits(observed: ByteArray): Boolean =
    observed.size == SESSION_FINGERPRINT_SIZE &&
        (this is DeviceServerAuthentication.ProvisionalPairing ||
            (this is DeviceServerAuthentication.Pinned && matches(observed)))

/**
 * A private trust manager for exactly one connection. Self-signed desktop
 * identities are expected: matching the stored SPKI pin, not a public CA or
 * the service's discoverable DNS name, authorizes reconnect. Provisional
 * trust never authorizes RVT1: the RVD1 pairing transcript must bind the
 * observed fingerprint to the on-screen confirmation before acceptance.
 */
private class DevicePeerTrustManager(
    private val authentication: DeviceServerAuthentication,
) : X509TrustManager {
    @Volatile private var observed: ByteArray? = null

    val verifiedFingerprint: ByteArray?
        get() = observed?.copyOf()

    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {
        throw CertificateException("client certificates are not Rivet device credentials")
    }

    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
        observed = null
        val certificate = chain?.firstOrNull()
            ?: throw CertificateException("Rivet device TLS peer certificate is missing")
        val key = certificate.publicKey
        if (key.format != "X.509") {
            throw CertificateException("Rivet device server SPKI is unavailable")
        }
        val encoded = key.encoded
            ?: throw CertificateException("Rivet device server SPKI is unavailable")
        if (encoded.isEmpty()) {
            throw CertificateException("Rivet device server SPKI is unavailable")
        }
        val fingerprint = spkiFingerprint(encoded)
        if (!authentication.permits(fingerprint)) {
            throw CertificateException("Rivet device server identity does not match its pin")
        }
        observed = fingerprint
    }

    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
}

private val deviceTLSProtocols = setOf("TLSv1.3", "TLSv1.2")

/** TLS 1.3 or ephemeral ECDH + AEAD only, matching the Apple transport. */
private val deviceTLSCipherSuites = setOf(
    "TLS_AES_128_GCM_SHA256",
    "TLS_AES_256_GCM_SHA384",
    "TLS_CHACHA20_POLY1305_SHA256",
    "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256",
    "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
    "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
    "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
    "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256",
    "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256",
)

internal fun deviceTLSAllowedProtocols(available: Array<String>): Array<String> =
    available.filter { it in deviceTLSProtocols }.toTypedArray()

internal fun deviceTLSAllowedCipherSuites(available: Array<String>): Array<String> =
    available.filter { it in deviceTLSCipherSuites }.toTypedArray()

/**
 * One authenticated TLS byte stream, ready for the RVD1 preface. Ownership
 * transfers to the caller, which must close the socket on cancellation,
 * rejection and application shutdown.
 */
class DeviceTLSConnection internal constructor(
    private val socket: SSLSocket,
    fingerprint: ByteArray,
) : Closeable {
    private val verifiedFingerprint = fingerprint.copyOf()

    val serverFingerprint: ByteArray
        get() = verifiedFingerprint.copyOf()

    val input: InputStream
        get() = socket.inputStream

    val output: OutputStream
        get() = socket.outputStream

    override fun close() = socket.close()
}

/**
 * Android/JVM-compatible TLS socket setup. The caller supplies one resolved
 * endpoint selected by the device user; discovery is never an authority
 * source. The socket enforces TLS 1.2+, FS+AEAD suites, ALPN, and SPKI pinning
 * before exposing streams to SessionClientRunner. Requires an Android TLS
 * provider with application-protocol support (API 29+).
 *
 * The caller supplies RVD1 reconnect/pairing state and verifies that its
 * fingerprint is the returned serverFingerprint. This connection helper
 * does not silently switch a failed reconnect into provisional pairing.
 */
object DeviceTLSClient {
    fun connect(
        host: String,
        port: Int,
        authentication: DeviceServerAuthentication,
        timeoutMillis: Int = DEVICE_TLS_CONNECT_TIMEOUT_MILLIS,
    ): DeviceTLSConnection {
        require(host.isNotBlank()) { "a resolved Rivet host is required" }
        require(port in 1..65535) { "invalid Rivet device port" }
        require(timeoutMillis in 1..DEVICE_TLS_CONNECT_TIMEOUT_MILLIS) {
            "invalid Rivet device connection timeout"
        }

        val verifier = DevicePeerTrustManager(authentication)
        val context = SSLContext.getInstance("TLS")
        context.init(null, arrayOf(verifier), SecureRandom())
        val socket = context.socketFactory.createSocket() as SSLSocket
        try {
            val protocols = deviceTLSAllowedProtocols(socket.supportedProtocols)
            val suites = deviceTLSAllowedCipherSuites(socket.supportedCipherSuites)
            if (protocols.isEmpty() || suites.isEmpty()) {
                throw SSLHandshakeException("Rivet device TLS policy is unsupported")
            }
            socket.enabledProtocols = protocols
            socket.enabledCipherSuites = suites
            val parameters = socket.sslParameters
            parameters.applicationProtocols = arrayOf(DEVICE_TLS_APPLICATION_PROTOCOL)
            socket.sslParameters = parameters

            // Connection and TLS receive phases are individually bounded;
            // endpoint resolution remains an OS/network responsibility.
            socket.connect(InetSocketAddress(host, port), timeoutMillis)
            socket.soTimeout = timeoutMillis
            socket.startHandshake()
            if (socket.applicationProtocol != DEVICE_TLS_APPLICATION_PROTOCOL ||
                socket.session.protocol !in deviceTLSProtocols ||
                socket.session.cipherSuite !in deviceTLSCipherSuites
            ) {
                throw SSLHandshakeException("Rivet device TLS negotiation violated policy")
            }
            val fingerprint = verifier.verifiedFingerprint
                ?: throw SSLHandshakeException("Rivet device TLS peer identity is unavailable")
            socket.soTimeout = (SESSION_POST_TLS_TIMEOUT_SECONDS * 1000).toInt()
            return DeviceTLSConnection(socket, fingerprint)
        } catch (failure: Throwable) {
            try {
                socket.close()
            } catch (_: Exception) {
                // Preserve the original failure, not close's secondary error.
            }
            throw failure
        }
    }
}
