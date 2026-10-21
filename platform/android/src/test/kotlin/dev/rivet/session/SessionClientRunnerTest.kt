package dev.rivet.session

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.util.Date
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlin.test.assertFailsWith

class SessionClientRunnerTest {
    private val applicationID = "com.example.app"
    private val deviceID = SessionUuid(ByteArray(16) { it.toByte() })
    private val sessionID = SessionUuid(ByteArray(16) { (it + 32).toByte() })
    private val credential = ByteArray(SESSION_CREDENTIAL_SIZE) { 0x33 }
    private val fingerprint = ByteArray(SESSION_FINGERPRINT_SIZE) { 0x55 }
    private val clientNonce = ByteArray(SESSION_NONCE_SIZE) { 0x11 }
    private val serverNonce = ByteArray(SESSION_NONCE_SIZE) { 0x22 }

    private fun reconnect(startedAt: Date) = DeviceSessionClient.forReconnect(
        applicationID, deviceID, credential, fingerprint, clientNonce, startedAt = startedAt,
    )

    @Test
    fun acceptanceHandsTheOriginalStreamsToApplicationOnce() {
        val responses = encodeSessionRecord(SessionMessage.AuthChallenge(serverNonce)) +
            encodeSessionRecord(SessionMessage.Accept(sessionID, listOf("reader"), 524288L, 64L))
        val input = ByteArrayInputStream(responses)
        val output = ByteArrayOutputStream()
        var handoffs = 0
        var delivered: SessionAcceptance? = null
        val runner = SessionClientRunner(
            input, output, ::reconnect, null,
            applicationHandler = { acceptance, actualInput, actualOutput ->
                handoffs++
                delivered = acceptance
                assertSame(input, actualInput)
                assertSame(output, actualOutput)
            },
        )
        val accepted = runner.run()
        assertEquals(1, handoffs)
        assertEquals(accepted, delivered)
        assertEquals(sessionID, accepted.sessionID)
        assertEquals(deviceID, accepted.deviceID)
        assertTrue(output.size() > 0)
    }

    @Test
    fun rejectionCannotReachApplication() {
        val input = ByteArrayInputStream(
            encodeSessionRecord(SessionMessage.Reject(SessionRejectCode.AUTHENTICATION_FAILED)),
        )
        var handoffs = 0
        val runner = SessionClientRunner(
            input, ByteArrayOutputStream(), ::reconnect, null,
            applicationHandler = { _, _, _ -> handoffs++ },
        )
        val thrown = assertFailsWith<SessionClientRunner.SessionClientFailureException> {
            runner.run()
        }
        assertEquals(SessionClientRunner.SessionClientFailure.REJECTED, thrown.failure)
        assertEquals(0, handoffs)
    }

    @Test
    fun cancellationClosesStreamsAndUnblocksRVD1Read() {
        val enteredRead = CountDownLatch(1)
        val monitor = Object()
        val input = object : InputStream() {
            private var closed = false
            override fun read(): Int = synchronized(monitor) {
                enteredRead.countDown()
                while (!closed) monitor.wait()
                -1
            }
            override fun read(bytes: ByteArray, offset: Int, length: Int): Int = read()
            override fun close() {
                synchronized(monitor) {
                    closed = true
                    monitor.notifyAll()
                }
            }
        }
        val failure = AtomicReference<Throwable?>()
        val runner = SessionClientRunner(input, ByteArrayOutputStream(), ::reconnect, null)
        val worker = Thread {
            try {
                runner.run()
            } catch (thrown: Throwable) {
                failure.set(thrown)
            }
        }
        worker.isDaemon = true
        worker.start()
        try {
            assertTrue(enteredRead.await(3, TimeUnit.SECONDS))
            runner.cancel()
            worker.join(3000)
            assertFalse(worker.isAlive, "cancel must unblock a blocked read")
            val thrown = assertIs<SessionClientRunner.SessionClientFailureException>(failure.get())
            assertEquals(SessionClientRunner.SessionClientFailure.CANCELLED, thrown.failure)
            runner.cancel()
        } finally {
            runner.cancel()
            input.close()
        }
    }
}
