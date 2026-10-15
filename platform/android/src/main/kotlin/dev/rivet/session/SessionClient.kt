package dev.rivet.session

import java.util.Date

/** A verified-and-usable session acceptance handed to the application layer. */
data class SessionAcceptance(
    val sessionID: SessionUuid,
    val deviceID: SessionUuid,
    val scopeNames: List<String>,
    val maximumPayload: Long,
    val maximumPending: Long,
)

sealed interface SessionClientAction {
    data class Send(val message: SessionMessage) : SessionClientAction
    data class ShowPairingCode(val attemptID: SessionUuid, val code: String) : SessionClientAction
    data class PersistPairing(
        val deviceID: SessionUuid,
        val credential: ByteArray,
        val serverFingerprint: ByteArray,
    ) : SessionClientAction

    data class Accepted(val acceptance: SessionAcceptance) : SessionClientAction
    data class Rejected(val code: SessionRejectCode) : SessionClientAction
    data object Close : SessionClientAction
}

enum class SessionStateFailure {
    PROTOCOL_VIOLATION,
    SESSION_CLOSED,
    PAIRING_NOT_ACTIVE,
}

class SessionStateException(
    val failure: SessionStateFailure,
    message: String,
) : Exception(message)

/**
 * Client-side ordering and credential-persistence gate for the RVD1
 * preface. The stream adapter must complete the persist action (and call
 * [notifyPairingPersisted]) before handing RVT1 Hello bytes to the ordinary
 * client. Instances are not thread-safe; the owning runner serializes calls.
 */
class DeviceSessionClient private constructor(
    private val serverFingerprint: ByteArray,
    private val timeoutSeconds: Double,
    private val pairingResponseTimeoutSeconds: Double,
    private val clock: () -> Date,
    private var state: State,
) {
    private data class ReconnectContext(
        val applicationID: String,
        val deviceID: SessionUuid,
        val credential: ByteArray,
        val clientNonce: ByteArray,
    )

    private data class PairingContext(
        val applicationID: String,
        val windowID: SessionUuid,
        val deviceName: String,
        val clientNonce: ByteArray,
        var attemptID: SessionUuid? = null,
    )

    private sealed interface State {
        data class ReconnectReady(val context: ReconnectContext, val deadline: Date) : State
        data class AwaitingAuthChallenge(val context: ReconnectContext, val deadline: Date) : State
        data class AwaitingAccept(val deviceID: SessionUuid, val deadline: Date) : State
        data class PairingReady(val context: PairingContext, val deadline: Date) : State
        data class AwaitingPairChallenge(val context: PairingContext, val deadline: Date) : State
        data class AwaitingPairDecision(val context: PairingContext, val deadline: Date) : State
        data class AwaitingPaired(val deadline: Date) : State
        data class AwaitingPersistence(val acceptance: SessionAcceptance) : State
        data class Accepted(val acceptance: SessionAcceptance) : State
        data object Closed : State
    }

    companion object {
        /** Reconnect with a stored pairing; authentication failure never falls back to pairing. */
        fun forReconnect(
            applicationID: String,
            deviceID: SessionUuid,
            credential: ByteArray,
            serverFingerprint: ByteArray,
            clientNonce: ByteArray,
            timeoutSeconds: Double = SESSION_POST_TLS_TIMEOUT_SECONDS,
            startedAt: Date = Date(),
            clock: () -> Date = Date::new,
        ): DeviceSessionClient {
            validateCommon(applicationID, serverFingerprint, clientNonce, timeoutSeconds)
            requireBytes(credential, SESSION_CREDENTIAL_SIZE)
            return DeviceSessionClient(
                serverFingerprint = serverFingerprint,
                timeoutSeconds = timeoutSeconds,
                pairingResponseTimeoutSeconds = SESSION_DEFAULT_PAIRING_WINDOW_SECONDS,
                clock = clock,
                state = State.ReconnectReady(
                    ReconnectContext(applicationID, deviceID, credential, clientNonce),
                    plusSeconds(startedAt, timeoutSeconds),
                ),
            )
        }

        /** Explicit provisional pairing against a freshly selected host. */
        fun forPairing(
            applicationID: String,
            windowID: SessionUuid,
            deviceName: String,
            serverFingerprint: ByteArray,
            clientNonce: ByteArray,
            timeoutSeconds: Double = SESSION_POST_TLS_TIMEOUT_SECONDS,
            pairingResponseTimeoutSeconds: Double = SESSION_DEFAULT_PAIRING_WINDOW_SECONDS,
            startedAt: Date = Date(),
            clock: () -> Date = Date::new,
        ): DeviceSessionClient {
            validateCommon(applicationID, serverFingerprint, clientNonce, timeoutSeconds)
            if (!validDeviceDisplayName(deviceName) || pairingResponseTimeoutSeconds <= 0) {
                throw SessionProtocolException(SessionProtocolFailure.INVALID_FIELD, "invalid Rivet device session field")
            }
            return DeviceSessionClient(
                serverFingerprint = serverFingerprint,
                timeoutSeconds = timeoutSeconds,
                pairingResponseTimeoutSeconds = pairingResponseTimeoutSeconds,
                clock = clock,
                state = State.PairingReady(
                    PairingContext(applicationID, windowID, deviceName, clientNonce),
                    plusSeconds(startedAt, timeoutSeconds),
                ),
            )
        }

        private fun validateCommon(
            applicationID: String,
            serverFingerprint: ByteArray,
            clientNonce: ByteArray,
            timeoutSeconds: Double,
        ) {
            if (!validDeviceApiName(applicationID) ||
                serverFingerprint.size != SESSION_FINGERPRINT_SIZE ||
                clientNonce.size != SESSION_NONCE_SIZE ||
                timeoutSeconds <= 0
            ) {
                throw SessionProtocolException(SessionProtocolFailure.INVALID_FIELD, "invalid Rivet device session field")
            }
        }

        private fun requireBytes(value: ByteArray, size: Int) {
            if (value.size != size) {
                throw SessionProtocolException(SessionProtocolFailure.INVALID_FIELD, "invalid Rivet device session field")
            }
        }

        private fun plusSeconds(instant: Date, seconds: Double): Date =
            Date(instant.time + (seconds * 1000).toLong())
    }

    fun start(now: Date = clock()): List<SessionClientAction> {
        requireNotExpired(now)
        return when (val state = this.state) {
            is State.ReconnectReady -> {
                this.state = State.AwaitingAuthChallenge(state.context, plusSeconds(now, timeoutSeconds))
                listOf(
                    SessionClientAction.Send(
                        SessionMessage.Authenticate(
                            state.context.applicationID,
                            state.context.deviceID,
                            state.context.clientNonce,
                        ),
                    ),
                )
            }
            is State.PairingReady -> {
                this.state = State.AwaitingPairChallenge(state.context, plusSeconds(now, timeoutSeconds))
                listOf(
                    SessionClientAction.Send(
                        SessionMessage.PairStart(
                            state.context.applicationID,
                            state.context.windowID,
                            state.context.deviceName,
                            state.context.clientNonce,
                        ),
                    ),
                )
            }
            is State.Closed -> throw SessionStateException(SessionStateFailure.SESSION_CLOSED, "Rivet device session is closed")
            else -> closeForProtocolViolation()
        }
    }

    fun receive(message: SessionMessage, now: Date = clock()): List<SessionClientAction> {
        requireNotExpired(now)
        if (message is SessionMessage.Reject) {
            return when (val state = this.state) {
                is State.AwaitingAuthChallenge, is State.AwaitingAccept, is State.AwaitingPairChallenge,
                is State.AwaitingPairDecision, is State.AwaitingPaired,
                -> {
                    this.state = State.Closed
                    listOf(SessionClientAction.Rejected(message.code), SessionClientAction.Close)
                }
                is State.Closed -> throw SessionStateException(SessionStateFailure.SESSION_CLOSED, "Rivet device session is closed")
                else -> closeForProtocolViolation()
            }
        }

        return when (val state = this.state) {
            is State.AwaitingAuthChallenge -> {
                val challenge = message as? SessionMessage.AuthChallenge ?: return closeForProtocolViolation()
                val proof = sessionAuthenticationProof(
                    state.context.credential,
                    state.context.applicationID,
                    serverFingerprint,
                    state.context.deviceID,
                    state.context.clientNonce,
                    challenge.serverNonce,
                )
                this.state = State.AwaitingAccept(state.context.deviceID, plusSeconds(now, timeoutSeconds))
                listOf(SessionClientAction.Send(SessionMessage.AuthProof(proof)))
            }
            is State.AwaitingAccept -> {
                val accept = message as? SessionMessage.Accept ?: return closeForProtocolViolation()
                val acceptance = SessionAcceptance(
                    accept.sessionID,
                    state.deviceID,
                    accept.scopeNames,
                    accept.maximumPayload,
                    accept.maximumPending,
                )
                this.state = State.Accepted(acceptance)
                listOf(SessionClientAction.Accepted(acceptance))
            }
            is State.AwaitingPairChallenge -> {
                val challenge = message as? SessionMessage.PairChallenge ?: return closeForProtocolViolation()
                val code = sessionPairingCode(
                    state.context.applicationID,
                    serverFingerprint,
                    state.context.clientNonce,
                    challenge.serverNonce,
                )
                state.context.attemptID = challenge.attemptID
                this.state = State.AwaitingPairDecision(state.context, plusSeconds(now, timeoutSeconds))
                listOf(SessionClientAction.ShowPairingCode(challenge.attemptID, code))
            }
            is State.AwaitingPaired -> {
                val paired = message as? SessionMessage.Paired ?: return closeForProtocolViolation()
                val acceptance = SessionAcceptance(
                    paired.sessionID,
                    paired.deviceID,
                    paired.scopeNames,
                    paired.maximumPayload,
                    paired.maximumPending,
                )
                this.state = State.AwaitingPersistence(acceptance)
                listOf(
                    SessionClientAction.PersistPairing(
                        paired.deviceID,
                        paired.credential,
                        serverFingerprint,
                    ),
                )
            }
            is State.Closed -> throw SessionStateException(SessionStateFailure.SESSION_CLOSED, "Rivet device session is closed")
            else -> closeForProtocolViolation()
        }
    }

    /** The device user's explicit decision on the surfaced pairing code. */
    fun confirmPairing(confirmed: Boolean, now: Date = clock()): List<SessionClientAction> {
        requireNotExpired(now)
        val context = (this.state as? State.AwaitingPairDecision)?.context
        if (context == null) {
            when (val state = this.state) {
                is State.Closed -> throw SessionStateException(SessionStateFailure.SESSION_CLOSED, "Rivet device session is closed")
                else -> throw SessionStateException(SessionStateFailure.PAIRING_NOT_ACTIVE, "Rivet device pairing is not active")
            }
        }
        val attemptID = context.attemptID
            ?: throw SessionStateException(SessionStateFailure.PAIRING_NOT_ACTIVE, "Rivet device pairing is not active")
        this.state = State.AwaitingPaired(plusSeconds(now, pairingResponseTimeoutSeconds))
        return listOf(SessionClientAction.Send(SessionMessage.PairDecision(attemptID, confirmed)))
    }

    /** Completes the credential-persistence gate and accepts the session. */
    fun notifyPairingPersisted(): List<SessionClientAction> {
        val acceptance = (this.state as? State.AwaitingPersistence)?.acceptance
        if (acceptance == null) {
            when (val state = this.state) {
                is State.Closed -> throw SessionStateException(SessionStateFailure.SESSION_CLOSED, "Rivet device session is closed")
                else -> throw SessionStateException(SessionStateFailure.PAIRING_NOT_ACTIVE, "Rivet device pairing is not active")
            }
        }
        this.state = State.Accepted(acceptance)
        return listOf(SessionClientAction.Accepted(acceptance))
    }

    /** A failed persistence closes the session without ever accepting. */
    fun notifyPairingPersistenceFailed(): List<SessionClientAction> {
        val acceptance = (this.state as? State.AwaitingPersistence)?.acceptance
        if (acceptance == null) {
            when (val state = this.state) {
                is State.Closed -> throw SessionStateException(SessionStateFailure.SESSION_CLOSED, "Rivet device session is closed")
                else -> throw SessionStateException(SessionStateFailure.PAIRING_NOT_ACTIVE, "Rivet device pairing is not active")
            }
        }
        this.state = State.Closed
        return listOf(SessionClientAction.Close)
    }

    fun expire(now: Date = clock()): List<SessionClientAction> =
        try {
            requireNotExpired(now)
            emptyList()
        } catch (_: SessionStateException) {
            listOf(SessionClientAction.Close)
        }

    fun acceptance(): SessionAcceptance? = (this.state as? State.Accepted)?.acceptance

    private fun requireNotExpired(now: Date) {
        val deadline = when (val state = this.state) {
            is State.ReconnectReady -> state.deadline
            is State.AwaitingAuthChallenge -> state.deadline
            is State.AwaitingAccept -> state.deadline
            is State.PairingReady -> state.deadline
            is State.AwaitingPairChallenge -> state.deadline
            is State.AwaitingPairDecision -> state.deadline
            is State.AwaitingPaired -> state.deadline
            else -> null
        }
        deadline ?: return
        if (!now.before(deadline)) {
            state = State.Closed
            throw SessionStateException(SessionStateFailure.SESSION_CLOSED, "Rivet device session is closed")
        }
    }

    private fun closeForProtocolViolation(): Nothing {
        state = State.Closed
        throw SessionStateException(SessionStateFailure.PROTOCOL_VIOLATION, "Rivet device session protocol violation")
    }
}
