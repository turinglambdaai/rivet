package dev.rivet.session

import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.Date
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Persists the credential issued by an explicit pairing attempt. The
 * session enters RVT1 only after this succeeds; a failed save must leave no
 * partial trust behind. Loading stored reconnect material stays
 * product-owned.
 */
fun interface SessionCredentialStore {
    @Throws(Exception::class)
    fun savePairingCredential(deviceID: SessionUuid, credential: ByteArray, serverFingerprint: ByteArray)
}

/** The pairing code surfaced to the device user; nothing auto-confirms it. */
data class DevicePairingCode(
    val attemptID: SessionUuid,
    val verificationCode: String,
    val expiresAt: Date,
)

/**
 * Drives one byte stream through the RVD1 preface on the calling thread.
 * `run` blocks (call it from a worker or coroutine on IO); the desktop
 * user's pairing decision arrives from another thread through
 * [confirmPairingOnDesktop]; [cancel] requests a clean stop and wakes the
 * decision wait — a blocking transport read is unblocked by closing the
 * stream, exactly as on the Apple and Windows hosts.
 */
class SessionClientRunner(
    private val input: InputStream,
    private val output: OutputStream,
    private val clientFactory: (startedAt: Date) -> DeviceSessionClient,
    private val credentialStore: SessionCredentialStore?,
    private val pairingCodeHandler: ((DevicePairingCode) -> Unit)? = null,
    // Plain function type so `run` stays a blocking call; products launch
    // their own coroutine scope inside the handler when they need one.
    private val applicationHandler: (SessionAcceptance, InputStream, OutputStream) -> Unit = { _, _, _ -> },
    private val nowMillis: () -> Long = System::currentTimeMillis,
    private val waitMillis: (Long) -> Unit = { Thread.sleep(it) },
    private val postTLSTimeoutSeconds: Double = SESSION_POST_TLS_TIMEOUT_SECONDS,
    private val pairingResponseTimeoutSeconds: Double = SESSION_DEFAULT_PAIRING_WINDOW_SECONDS,
) {
    private val cancelled = AtomicBoolean(false)
    private val lock = Object()
    private var decisionMade = false

    fun cancel() {
        cancelled.set(true)
        synchronized(lock) {
            decisionMade = true
            lock.notifyAll()
        }
    }

    /** The desktop user's explicit decision; throws when no pairing is active. */
    fun confirmPairingOnDesktop(confirmed: Boolean) {
        val actions: List<SessionClientAction>
        synchronized(lock) {
            val active = client ?: throw SessionStateException(SessionStateFailure.PAIRING_NOT_ACTIVE, "Rivet device pairing is not active")
            actions = active.confirmPairing(confirmed, Date(nowMillis()))
            decisionMade = true
            lock.notifyAll()
        }
        executeSends(actions)
    }

    private var client: DeviceSessionClient? = null

    /**
     * Runs the preface and, after acceptance, lends the authenticated
     * stream to the application handler. Returns the acceptance; throws
     * [SessionClientFailure] on a server reject, timeout, or persistence
     * failure and rethrows transport or protocol errors as-is.
     */
    fun run(): SessionAcceptance {
        val startedAt = Date(nowMillis())
        val client = clientFactory(startedAt).also { this.client = it }
        var nextDeadline = startedAt.time + secondsToMillis(postTLSTimeoutSeconds)
        try {
            executeActions(client.start(Date(nowMillis())))
            while (true) {
                val message = receiveMessage()
                val receivedAt = Date(nowMillis())
                if (cancelled.get()) {
                    throwAsCleanFailureOrNull()
                }
                if (receivedAt.time >= nextDeadline) {
                    executeActions(client.expire(receivedAt))
                    throw SessionClientFailure.TIMED_OUT.toException()
                }
                nextDeadline = receivedAt.time + secondsToMillis(postTLSTimeoutSeconds)

                val actions = client.receive(message, receivedAt)
                var sawCode = false
                for (action in actions) {
                    when (action) {
                        is SessionClientAction.ShowPairingCode -> {
                            sawCode = true
                            pairingCodeHandler?.invoke(
                                DevicePairingCode(
                                    action.attemptID,
                                    action.code,
                                    Date(receivedAt.time + secondsToMillis(pairingResponseTimeoutSeconds)),
                                ),
                            )
                        }
                        else -> executeActions(listOf(action))
                    }
                }
                client.acceptance()?.let { return it }

                if (sawCode && message is SessionMessage.PairChallenge) {
                    waitForDesktopDecision(pairingResponseTimeoutSeconds)
                    if (cancelled.get()) {
                        throw SessionClientFailure.CANCELLED.toException()
                    }
                    client.acceptance()?.let { return it }
                    // The decision is still pending (or was a rejection
                    // without a response); keep reading on the same rolling
                    // deadline semantics.
                    if (decisionAwaitedAndUnresolved()) {
                        continue
                    }
                }
            }
        } catch (failure: SessionClientFailureException) {
            throw failure
        } catch (failure: SessionStateException) {
            throw mapStateFailure(failure)
        } catch (_: EOFException) {
            throw SessionClientFailure.CONNECTION_CLOSED.toException()
        } catch (failure: IOException) {
            if (cancelled.get()) {
                throw SessionClientFailure.CANCELLED.toException()
            }
            throw SessionClientFailure.CONNECTION_CLOSED.toException()
        }
    }

    private fun decisionAwaitedAndUnresolved(): Boolean =
        !cancelled.get() && (this.client?.acceptance() == null)

    private fun waitForDesktopDecision(boundSeconds: Double) {
        synchronized(lock) {
            val bound = secondsToMillis(boundSeconds)
            val deadline = nowMillis() + bound
            while (!decisionMade && !cancelled.get()) {
                val remaining = deadline - nowMillis()
                if (remaining <= 0) break
                lock.wait(minOf(remaining, 100))
            }
            decisionMade = false
        }
    }

    private fun receiveMessage(): SessionMessage {
        val stream = DataInputStream(input)
        val header = ByteArray(8)
        stream.readFully(header)
        if (!header.copyOfRange(0, 4).contentEquals(byteArrayOf(0x52, 0x56, 0x44, 0x31))) {
            throw SessionProtocolException(SessionProtocolFailure.INVALID_MAGIC, "invalid Rivet device session magic")
        }
        if (header[4].toInt() != SESSION_VERSION) {
            throw SessionProtocolException(SessionProtocolFailure.UNSUPPORTED_VERSION, "unsupported Rivet device session version ${header[4]}")
        }
        SessionMessageType.entries.firstOrNull { it.wireValue == header[5].toInt() }
            ?: throw SessionProtocolException(SessionProtocolFailure.UNKNOWN_MESSAGE_TYPE, "unknown Rivet device session message type")
        val payloadLength = (header[6].toInt() and 0xff) or ((header[7].toInt() and 0xff) shl 8)
        if (payloadLength > SESSION_MAXIMUM_PAYLOAD_SIZE) {
            throw SessionProtocolException(SessionProtocolFailure.RECORD_TOO_LARGE, "Rivet device session record exceeds its size limit")
        }
        val payload = ByteArray(payloadLength)
        if (payloadLength > 0) stream.readFully(payload)
        return decodeSessionRecord(header + payload)
    }

    private fun executeActions(actions: List<SessionClientAction>) {
        for (action in actions) {
            when (action) {
                is SessionClientAction.Send -> {
                    synchronized(lock) {
                        output.write(encodeSessionRecord(action.message))
                        output.flush()
                    }
                }
                is SessionClientAction.PersistPairing -> persistPairing(action)
                is SessionClientAction.Accepted -> Unit
                is SessionClientAction.Close -> throw SessionClientFailure.CLOSED.toException()
                is SessionClientAction.Rejected -> throw SessionClientFailureException(SessionClientFailure.REJECTED, action.code)
                is SessionClientAction.ShowPairingCode -> Unit
            }
        }
    }

    private fun persistPairing(action: SessionClientAction.PersistPairing) {
        val active = this.client
        val store = credentialStore
        if (active == null || store == null) {
            active?.let { executeActions(it.notifyPairingPersistenceFailed()) }
            throw SessionClientFailure.PERSISTENCE_FAILED.toException()
        }
        try {
            store.savePairingCredential(action.deviceID, action.credential, action.serverFingerprint)
        } catch (_: Throwable) {
            executeActions(active.notifyPairingPersistenceFailed())
            throw SessionClientFailure.PERSISTENCE_FAILED.toException()
        }
        executeActions(active.notifyPairingPersisted())
    }

    private fun executeSends(actions: List<SessionClientAction>) {
        for (action in actions) {
            if (action is SessionClientAction.Send) {
                synchronized(lock) {
                    output.write(encodeSessionRecord(action.message))
                    output.flush()
                }
            }
        }
    }

    private fun throwAsCleanFailureOrNull() {
        if (cancelled.get()) {
            throw SessionClientFailure.CANCELLED.toException()
        }
    }

    private fun mapStateFailure(failure: SessionStateException): Exception =
        when (failure.failure) {
            SessionStateFailure.SESSION_CLOSED -> SessionClientFailure.TIMED_OUT.toException()
            SessionStateFailure.PROTOCOL_VIOLATION -> failure
            SessionStateFailure.PAIRING_NOT_ACTIVE -> failure
        }

    private fun secondsToMillis(seconds: Double): Long = (seconds * 1000).toLong()

    enum class SessionClientFailure {
        REJECTED,
        TIMED_OUT,
        PERSISTENCE_FAILED,
        CONNECTION_CLOSED,
        CANCELLED,
        CLOSED,
    }

    class SessionClientFailureException(
        val failure: SessionClientFailure,
        val rejectCode: SessionRejectCode? = null,
        message: String = "Rivet device session client failure: $failure${rejectCode?.let { " ($it)" } ?: ""}",
    ) : Exception(message)

    private fun SessionClientFailure.toException(): SessionClientFailureException = SessionClientFailureException(this)
}
