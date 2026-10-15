package dev.rivet.session

import java.util.Date
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SessionClientTest {
    private val applicationID = "com.example.app"
    private val deviceID = SessionUuid(ByteArray(16) { it.toByte() })
    private val windowID = SessionUuid(ByteArray(16) { 1 })
    private val attemptID = SessionUuid(ByteArray(16) { 2 })
    private val sessionID = SessionUuid(ByteArray(16) { 3 })
    private val fingerprint = ByteArray(SESSION_FINGERPRINT_SIZE) { 0x55 }
    private val clientNonce = ByteArray(SESSION_NONCE_SIZE) { 0x11 }
    private val serverNonce = ByteArray(SESSION_NONCE_SIZE) { 0x22 }
    private val credential = ByteArray(SESSION_CREDENTIAL_SIZE) { 0x33 }

    private class Clock(var millis: Long = 20_000) {
        fun now(): Date = Date(millis)
        fun advance(seconds: Double) {
            millis += (seconds * 1000).toLong()
        }
    }

    private fun reconnectClient(clock: Clock) = DeviceSessionClient.forReconnect(
        applicationID, deviceID, credential, fingerprint, clientNonce,
        startedAt = clock.now(), clock = clock::now,
    )

    private fun pairingClient(clock: Clock) = DeviceSessionClient.forPairing(
        applicationID, windowID, "Test Phone", fingerprint, clientNonce,
        startedAt = clock.now(), clock = clock::now,
    )

    private fun accept() = SessionMessage.Accept(sessionID, listOf("reader"), 524288L, 64L)

    @Test
    fun reconnectProducesProofAndAcceptsOnlyAfterServerAccept() {
        val clock = Clock()
        val client = reconnectClient(clock)
        val startActions = client.start(clock.now())
        assertEquals(
            listOf(SessionClientAction.Send(SessionMessage.Authenticate(applicationID, deviceID, clientNonce))),
            startActions,
        )
        assertNull(client.acceptance())

        val proofActions = client.receive(SessionMessage.AuthChallenge(serverNonce), clock.now())
        val sent = (proofActions.single() as SessionClientAction.Send).message as SessionMessage.AuthProof
        assertEquals(
            sessionAuthenticationProof(credential, applicationID, fingerprint, deviceID, clientNonce, serverNonce).toList(),
            sent.proof.toList(),
        )

        val accepted = client.receive(accept(), clock.now())
        val expected = SessionAcceptance(sessionID, deviceID, listOf("reader"), 524288L, 64L)
        assertEquals(listOf(SessionClientAction.Accepted(expected)), accepted)
        assertEquals(expected, client.acceptance())
    }

    @Test
    fun reconnectRejectionClosesWithoutPairingFallback() {
        val clock = Clock()
        val client = reconnectClient(clock)
        client.start(clock.now())
        val actions = client.receive(SessionMessage.Reject(SessionRejectCode.AUTHENTICATION_FAILED), clock.now())
        assertEquals(
            listOf(
                SessionClientAction.Rejected(SessionRejectCode.AUTHENTICATION_FAILED),
                SessionClientAction.Close,
            ),
            actions,
        )
        assertFailsWith<SessionStateException> {
            client.receive(SessionMessage.AuthChallenge(serverNonce), clock.now())
        }
    }

    @Test
    fun pairingSurfacesCodeAndGatesOnPersistence() {
        val clock = Clock()
        val client = pairingClient(clock)
        client.start(clock.now())

        val codeActions = client.receive(SessionMessage.PairChallenge(attemptID, serverNonce), clock.now())
        assertEquals(
            listOf(
                SessionClientAction.ShowPairingCode(
                    attemptID,
                    sessionPairingCode(applicationID, fingerprint, clientNonce, serverNonce),
                ),
            ),
            codeActions,
        )
        assertNull(client.acceptance())

        val decisionActions = client.confirmPairing(true, clock.now())
        assertEquals(listOf(SessionClientAction.Send(SessionMessage.PairDecision(attemptID, true))), decisionActions)

        val newCredential = ByteArray(SESSION_CREDENTIAL_SIZE) { 0xb5 }
        val persistActions = client.receive(
            SessionMessage.Paired(deviceID, newCredential, sessionID, listOf("reader"), 524288L, 64L),
            clock.now(),
        )
        assertEquals(
            listOf(SessionClientAction.PersistPairing(deviceID, newCredential, fingerprint)),
            persistActions,
        )
        assertNull(client.acceptance())

        val accepted = client.notifyPairingPersisted()
        val expected = SessionAcceptance(sessionID, deviceID, listOf("reader"), 524288L, 64L)
        assertEquals(listOf(SessionClientAction.Accepted(expected)), accepted)
        assertEquals(expected, client.acceptance())
    }

    @Test
    fun persistenceFailureClosesWithoutAcceptance() {
        val clock = Clock()
        val client = pairingClient(clock)
        client.start(clock.now())
        client.receive(SessionMessage.PairChallenge(attemptID, serverNonce), clock.now())
        client.confirmPairing(true, clock.now())
        client.receive(
            SessionMessage.Paired(deviceID, credential, sessionID, listOf("reader"), 524288L, 64L),
            clock.now(),
        )

        val closeActions = client.notifyPairingPersistenceFailed()
        assertEquals(listOf(SessionClientAction.Close), closeActions)
        assertNull(client.acceptance())
    }

    @Test
    fun decisionWithoutActivePairingThrows() {
        val clock = Clock()
        val client = pairingClient(clock)
        val failure = assertFailsWith<SessionStateException> { client.confirmPairing(true, clock.now()) }
        assertEquals(SessionStateFailure.PAIRING_NOT_ACTIVE, failure.failure)
    }

    @Test
    fun expiryClosesThroughExpire() {
        val clock = Clock()
        val client = reconnectClient(clock)
        client.start(clock.now())
        clock.advance(SESSION_POST_TLS_TIMEOUT_SECONDS + 1.0)
        assertEquals(listOf(SessionClientAction.Close), client.expire(clock.now()))
        assertFailsWith<SessionStateException> { client.start(clock.now()) }
    }

    @Test
    fun wrongMessageTypeInAwaitingStateClosesPoisonously() {
        val clock = Clock()
        val client = reconnectClient(clock)
        client.start(clock.now())
        val failure = assertFailsWith<SessionStateException> {
            client.receive(accept(), clock.now())
        }
        assertEquals(SessionStateFailure.PROTOCOL_VIOLATION, failure.failure)
        assertFailsWith<SessionStateException> { client.start(clock.now()) }
        assertTrue(client.acceptance() == null)
    }
}
