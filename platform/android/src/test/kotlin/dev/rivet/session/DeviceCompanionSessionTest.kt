package dev.rivet.session

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import javax.net.ssl.SSLHandshakeException
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertSame
import kotlin.test.assertTrue

class DeviceCompanionSessionTest {
    private val endpoint = DeviceCompanionEndpoint("127.0.0.1", 48123)
    private val deviceID = SessionUuid(ByteArray(16) { it.toByte() })
    private val sessionID = SessionUuid(ByteArray(16) { (it + 32).toByte() })
    private val fingerprint = ByteArray(SESSION_FINGERPRINT_SIZE) { 0x55 }
    private val credential = ByteArray(SESSION_CREDENTIAL_SIZE) { 0x33 }
    private val clientNonce = ByteArray(SESSION_NONCE_SIZE) { 0x11 }
    private val serverNonce = ByteArray(SESSION_NONCE_SIZE) { 0x22 }

    private fun reconnect() = DeviceCompanionIntent.Reconnect(
        "com.example.app", deviceID, credential, fingerprint,
    )

    private class FakeTransport(
        val response: ByteArray,
        val fingerprintBytes: ByteArray,
    ) : DeviceCompanionTransport {
        val incoming = ByteArrayInputStream(response)
        val outgoing = ByteArrayOutputStream()
        var closed = false
        override val serverFingerprint: ByteArray
            get() = fingerprintBytes.copyOf()
        override val input: InputStream
            get() = incoming
        override val output: OutputStream
            get() = outgoing
        override fun close() {
            closed = true
            incoming.close()
            outgoing.close()
        }
    }

    @Test
    fun acceptedReconnectHandsOverOnlyVerifiedStreams() {
        val responses = encodeSessionRecord(SessionMessage.AuthChallenge(serverNonce)) +
            encodeSessionRecord(SessionMessage.Accept(sessionID, listOf("reader"), 524288L, 64L))
        val transport = FakeTransport(responses, fingerprint)
        var called = 0
        var observedPin: DeviceServerAuthentication? = null
        val session = DeviceCompanionSession(
            endpoint, reconnect(),
            onAccepted = { acceptance, input, output ->
                called++
                assertEquals(sessionID, acceptance.sessionID)
                assertSame(transport.incoming, input)
                assertSame(transport.outgoing, output)
                assertFalse(transport.closed)
            },
            dialer = DeviceCompanionDialer { selected, auth ->
                assertEquals(endpoint, selected)
                observedPin = auth
                transport
            },
            nonceGenerator = { clientNonce.copyOf() },
        )

        val result = session.run()
        assertEquals(sessionID, result.sessionID)
        assertEquals(deviceID, result.deviceID)
        assertEquals(1, called)
        assertTrue(observedPin is DeviceServerAuthentication.Pinned)
        val output = transport.outgoing.toByteArray()
        assertTrue(output.isNotEmpty())
        val first = decodeSessionRecord(output.copyOfRange(0, 8 + ((output[6].toInt() and 255) or
            ((output[7].toInt() and 255) shl 8))))
        assertEquals(SessionMessage.Authenticate("com.example.app", deviceID, clientNonce), first)
        assertFalse(transport.closed)
        session.close()
        assertTrue(transport.closed)
        assertFailsWith<IllegalStateException> { session.run() }
    }

    @Test
    fun wrongPinIsRejectedBeforeAnySessionMessage() {
        val transport = FakeTransport(byteArrayOf(), ByteArray(SESSION_FINGERPRINT_SIZE) { 0x66 })
        var accepted = false
        val session = DeviceCompanionSession(
            endpoint, reconnect(),
            onAccepted = { _, _, _ -> accepted = true },
            dialer = DeviceCompanionDialer { _, _ -> transport },
        )
        assertFailsWith<SSLHandshakeException> { session.run() }
        assertFalse(accepted)
        assertEquals(0, transport.outgoing.size())
        assertTrue(transport.closed)
    }

    @Test
    fun rejectedReconnectClosesTransportWithoutPairingFallback() {
        val transport = FakeTransport(
            encodeSessionRecord(SessionMessage.Reject(SessionRejectCode.AUTHENTICATION_FAILED)),
            fingerprint,
        )
        var accepted = false
        var dialCount = 0
        val session = DeviceCompanionSession(
            endpoint, reconnect(),
            onAccepted = { _, _, _ -> accepted = true },
            dialer = DeviceCompanionDialer { _, auth ->
                dialCount++
                assertTrue(auth is DeviceServerAuthentication.Pinned)
                transport
            },
            nonceGenerator = { clientNonce },
        )
        val thrown = assertFailsWith<SessionClientRunner.SessionClientFailureException> {
            session.run()
        }
        assertEquals(SessionClientRunner.SessionClientFailure.REJECTED, thrown.failure)
        assertFalse(accepted)
        assertTrue(transport.closed)
        assertEquals(1, dialCount)
    }

    @Test
    fun explicitPairingUsesProvisionalTLSButRejectNeverHandsOff() {
        val transport = FakeTransport(
            encodeSessionRecord(SessionMessage.Reject(SessionRejectCode.PAIRING_UNAVAILABLE)),
            fingerprint,
        )
        var accepted = false
        val intent = DeviceCompanionIntent.Pair(
            "com.example.app", SessionUuid(ByteArray(16) { 0x22 }), "My Android",
        )
        val session = DeviceCompanionSession(
            endpoint, intent,
            onAccepted = { _, _, _ -> accepted = true },
            dialer = DeviceCompanionDialer { _, auth ->
                assertSame(DeviceServerAuthentication.ProvisionalPairing, auth)
                transport
            },
            nonceGenerator = { clientNonce },
        )
        val failure = assertFailsWith<SessionClientRunner.SessionClientFailureException> {
            session.run()
        }
        assertEquals(SessionClientRunner.SessionClientFailure.REJECTED, failure.failure)
        assertFalse(accepted)
        assertTrue(transport.closed)
    }

    @Test
    fun earlyClosePreventsAnyConnection() {
        var dialed = false
        val session = DeviceCompanionSession(
            endpoint, reconnect(),
            onAccepted = { _, _, _ -> },
            dialer = DeviceCompanionDialer { _, _ ->
                dialed = true
                error("unexpected TLS connect")
            },
        )
        session.close()
        val failure = assertFailsWith<SessionClientRunner.SessionClientFailureException> {
            session.run()
        }
        assertEquals(SessionClientRunner.SessionClientFailure.CANCELLED, failure.failure)
        assertFalse(dialed)
    }

    @Test
    fun invalidSelectedEndpointFailsClosed() {
        assertFailsWith<IllegalArgumentException> { DeviceCompanionEndpoint("", 1234) }
        assertFailsWith<IllegalArgumentException> { DeviceCompanionEndpoint("host", 0) }
        assertFailsWith<IllegalArgumentException> { DeviceCompanionEndpoint("host", 65536) }
    }
}
