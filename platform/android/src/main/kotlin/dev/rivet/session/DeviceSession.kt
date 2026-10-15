package dev.rivet.session

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

// RVD1 v1 session preface: the bounded record dialect spoken over a device
// TLS connection before the ordinary RVT1 stream starts. The wire contract
// is pinned by rivet/tests/device-session-golden.txt; Android companions
// run the client side of this preface.

const val SESSION_VERSION: Int = 1
const val SESSION_MAXIMUM_RECORD_SIZE: Int = 8 * 1024
const val SESSION_MAXIMUM_PAYLOAD_SIZE: Int = SESSION_MAXIMUM_RECORD_SIZE - 8
const val SESSION_MAXIMUM_SCOPE_COUNT: Int = 64
const val SESSION_NONCE_SIZE: Int = 32
const val SESSION_CREDENTIAL_SIZE: Int = 32
const val SESSION_FINGERPRINT_SIZE: Int = 32
const val SESSION_UUID_SIZE: Int = 16
const val SESSION_DEFAULT_MAXIMUM_PAYLOAD: Long = 512L * 1024
const val SESSION_DEFAULT_MAXIMUM_PENDING: Int = 64
const val SESSION_POST_TLS_TIMEOUT_SECONDS: Double = 10.0
const val SESSION_DEFAULT_PAIRING_WINDOW_SECONDS: Double = 5.0 * 60

enum class SessionRejectCode(val wireValue: String) {
    AUTHENTICATION_FAILED("authentication_failed"),
    PAIRING_UNAVAILABLE("pairing_unavailable"),
    PAIRING_REJECTED("pairing_rejected"),
    PAIRING_EXPIRED("pairing_expired"),
    SERVER_BUSY("server_busy"),
    INTERNAL_ERROR("internal_error");

    companion object {
        fun fromWire(value: String): SessionRejectCode? = entries.firstOrNull { it.wireValue == value }
    }
}

enum class SessionProtocolFailure {
    TRUNCATED,
    INVALID_MAGIC,
    UNSUPPORTED_VERSION,
    UNKNOWN_MESSAGE_TYPE,
    RECORD_TOO_LARGE,
    MALFORMED_PAYLOAD,
    INVALID_FIELD,
    DECODER_FAILED,
}

class SessionProtocolException(
    val failure: SessionProtocolFailure,
    message: String,
) : Exception(message)

/** A RFC-4122 layout UUID carried as 16 wire bytes in records. */
class SessionUuid(bytes: ByteArray) {
    val bytes: ByteArray = bytes.copyOf()

    init {
        require(this.bytes.size == SESSION_UUID_SIZE) { "session uuid must be 16 bytes" }
    }

    override fun equals(other: Any?): Boolean = other is SessionUuid && bytes.contentEquals(other.bytes)
    override fun hashCode(): Int = bytes.contentHashCode()
    override fun toString(): String = "SessionUuid(${bytes.toHexString()})"

    companion object {
        fun random(): SessionUuid = SessionUuid(ByteArray(SESSION_UUID_SIZE).also { java.security.SecureRandom().nextBytes(it) })
    }
}

private fun ByteArray.toHexString(): String = joinToString("") { "%02x".format(it) }

sealed interface SessionMessage {
    data class Authenticate(
        val applicationID: String,
        val deviceID: SessionUuid,
        val clientNonce: ByteArray,
    ) : SessionMessage {
        override fun equals(other: Any?): Boolean =
            other is Authenticate &&
                applicationID == other.applicationID &&
                deviceID == other.deviceID &&
                clientNonce.contentEquals(other.clientNonce)

        override fun hashCode(): Int = applicationID.hashCode() * 31 + deviceID.hashCode()
    }

    data class AuthChallenge(val serverNonce: ByteArray) : SessionMessage {
        override fun equals(other: Any?): Boolean = other is AuthChallenge && serverNonce.contentEquals(other.serverNonce)
        override fun hashCode(): Int = serverNonce.contentHashCode()
    }

    data class AuthProof(val proof: ByteArray) : SessionMessage {
        override fun equals(other: Any?): Boolean = other is AuthProof && proof.contentEquals(other.proof)
        override fun hashCode(): Int = proof.contentHashCode()
    }

    data class PairStart(
        val applicationID: String,
        val windowID: SessionUuid,
        val deviceName: String,
        val clientNonce: ByteArray,
    ) : SessionMessage {
        override fun equals(other: Any?): Boolean =
            other is PairStart &&
                applicationID == other.applicationID &&
                windowID == other.windowID &&
                deviceName == other.deviceName &&
                clientNonce.contentEquals(other.clientNonce)

        override fun hashCode(): Int = windowID.hashCode() * 31 + clientNonce.contentHashCode()
    }

    data class PairChallenge(val attemptID: SessionUuid, val serverNonce: ByteArray) : SessionMessage {
        override fun equals(other: Any?): Boolean =
            other is PairChallenge && attemptID == other.attemptID && serverNonce.contentEquals(other.serverNonce)

        override fun hashCode(): Int = attemptID.hashCode() * 31 + serverNonce.contentHashCode()
    }
    data class PairDecision(val attemptID: SessionUuid, val confirmed: Boolean) : SessionMessage

    data class Accept(
        val sessionID: SessionUuid,
        val scopeNames: List<String>,
        val maximumPayload: Long,
        val maximumPending: Long,
    ) : SessionMessage

    data class Paired(
        val deviceID: SessionUuid,
        val credential: ByteArray,
        val sessionID: SessionUuid,
        val scopeNames: List<String>,
        val maximumPayload: Long,
        val maximumPending: Long,
    ) : SessionMessage {
        override fun equals(other: Any?): Boolean =
            other is Paired &&
                deviceID == other.deviceID &&
                credential.contentEquals(other.credential) &&
                sessionID == other.sessionID &&
                scopeNames == other.scopeNames &&
                maximumPayload == other.maximumPayload &&
                maximumPending == other.maximumPending

        override fun hashCode(): Int = credential.contentHashCode() * 31 + sessionID.hashCode()
    }

    data class Reject(val code: SessionRejectCode) : SessionMessage
}

private val SESSION_MAGIC = byteArrayOf(0x52, 0x56, 0x44, 0x31) // RVD1

internal enum class SessionMessageType(val wireValue: Int) {
    AUTHENTICATE(1),
    AUTH_CHALLENGE(2),
    AUTH_PROOF(3),
    PAIR_START(4),
    PAIR_CHALLENGE(5),
    PAIR_DECISION(6),
    ACCEPT(7),
    PAIRED(8),
    REJECT(9),
}

private fun SessionMessage.wireType(): SessionMessageType =
    when (this) {
        is SessionMessage.Authenticate -> SessionMessageType.AUTHENTICATE
        is SessionMessage.AuthChallenge -> SessionMessageType.AUTH_CHALLENGE
        is SessionMessage.AuthProof -> SessionMessageType.AUTH_PROOF
        is SessionMessage.PairStart -> SessionMessageType.PAIR_START
        is SessionMessage.PairChallenge -> SessionMessageType.PAIR_CHALLENGE
        is SessionMessage.PairDecision -> SessionMessageType.PAIR_DECISION
        is SessionMessage.Accept -> SessionMessageType.ACCEPT
        is SessionMessage.Paired -> SessionMessageType.PAIRED
        is SessionMessage.Reject -> SessionMessageType.REJECT
    }

fun validDeviceApiName(name: String): Boolean {
    if (name.isEmpty() || name.encodeToByteArray().size > 128) return false
    return name.all {
        it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it == '.' || it == '-' || it == '_'
    }
}

fun validDeviceDisplayName(name: String): Boolean {
    if (name.isEmpty() || name.encodeToByteArray().size > 128) return false
    if (name != name.trim()) return false
    return name.none { it.code < 0x20 || it.code == 0x7f }
}

fun validScopeNames(names: List<String>): Boolean =
    names.size <= SESSION_MAXIMUM_SCOPE_COUNT &&
        names.toSet().size == names.size &&
        names.all(::validDeviceApiName)

/** Canonical scope form: deduplicated, sorted by unsigned UTF-8 byte order. */
fun canonicalScopeNames(names: List<String>): List<String> =
    names.distinct().sortedWith { lhs, rhs ->
        val left = lhs.encodeToByteArray()
        val right = rhs.encodeToByteArray()
        val count = minOf(left.size, right.size)
        var difference = 0
        for (index in 0 until count) {
            difference = (left[index].toInt() and 0xff) - (right[index].toInt() and 0xff)
            if (difference != 0) return@sortedWith difference
        }
        left.size - right.size
    }

private fun requireBytes(value: ByteArray, size: Int) {
    if (value.size != size) {
        throw SessionProtocolException(SessionProtocolFailure.INVALID_FIELD, "invalid Rivet device session field")
    }
}

private fun requireApiName(name: String) {
    if (!validDeviceApiName(name)) {
        throw SessionProtocolException(SessionProtocolFailure.INVALID_FIELD, "invalid Rivet device session field")
    }
}

private fun requireLimits(maximumPayload: Long, maximumPending: Long) {
    if (maximumPayload <= 0 || maximumPayload > SESSION_DEFAULT_MAXIMUM_PAYLOAD ||
        maximumPending <= 0 || maximumPending > SESSION_DEFAULT_MAXIMUM_PENDING
    ) {
        throw SessionProtocolException(SessionProtocolFailure.INVALID_FIELD, "invalid Rivet device session field")
    }
}

private fun requireCanonicalScopes(names: List<String>) {
    if (!validScopeNames(names) || names != canonicalScopeNames(names)) {
        throw SessionProtocolException(SessionProtocolFailure.INVALID_FIELD, "invalid Rivet device session field")
    }
}

private fun uuidBytes(id: SessionUuid): ByteArray = id.bytes

private fun requireUuidBytes(value: ByteArray): SessionUuid {
    requireBytes(value, SESSION_UUID_SIZE)
    return SessionUuid(value)
}

private fun SessionMessage.payloadFields(): List<Any> =
    when (this) {
        is SessionMessage.Authenticate -> {
            requireApiName(applicationID)
            requireBytes(clientNonce, SESSION_NONCE_SIZE)
            listOf(applicationID, uuidBytes(deviceID), clientNonce)
        }
        is SessionMessage.AuthChallenge -> {
            requireBytes(serverNonce, SESSION_NONCE_SIZE)
            listOf(serverNonce)
        }
        is SessionMessage.AuthProof -> {
            requireBytes(proof, SESSION_CREDENTIAL_SIZE)
            listOf(proof)
        }
        is SessionMessage.PairStart -> {
            requireApiName(applicationID)
            if (!validDeviceDisplayName(deviceName)) {
                throw SessionProtocolException(SessionProtocolFailure.INVALID_FIELD, "invalid Rivet device session field")
            }
            requireBytes(clientNonce, SESSION_NONCE_SIZE)
            listOf(applicationID, uuidBytes(windowID), deviceName, clientNonce)
        }
        is SessionMessage.PairChallenge -> {
            requireBytes(serverNonce, SESSION_NONCE_SIZE)
            listOf(uuidBytes(attemptID), serverNonce)
        }
        is SessionMessage.PairDecision -> listOf(uuidBytes(attemptID), confirmed)
        is SessionMessage.Accept -> {
            requireLimits(maximumPayload, maximumPending)
            requireCanonicalScopes(scopeNames)
            listOf(uuidBytes(sessionID), scopeNames, maximumPayload, maximumPending)
        }
        is SessionMessage.Paired -> {
            requireBytes(credential, SESSION_CREDENTIAL_SIZE)
            requireLimits(maximumPayload, maximumPending)
            requireCanonicalScopes(scopeNames)
            listOf(uuidBytes(deviceID), credential, uuidBytes(sessionID), scopeNames, maximumPayload, maximumPending)
        }
        is SessionMessage.Reject -> listOf(code.wireValue)
    }

private fun encodePayloadField(value: Any): ByteArray =
    when (value) {
        is String -> {
            val encoded = value.encodeToByteArray()
            byteArrayOf(0x04) + encoded.size.toLittleEndianByteArray() + encoded
        }
        is ByteArray -> byteArrayOf(0x05) + value.size.toLittleEndianByteArray() + value
        is Boolean -> byteArrayOf(if (value) 0x02 else 0x01)
        is Long -> byteArrayOf(0x03) + ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(value).array()
        is List<*> -> {
            var out = byteArrayOf(0x06) + value.size.toLittleEndianByteArray()
            value.forEach { out += encodePayloadField(it!!) }
            out
        }
        else -> throw SessionProtocolException(SessionProtocolFailure.MALFORMED_PAYLOAD, "malformed Rivet device session payload")
    }

private fun Int.toLittleEndianByteArray(): ByteArray =
    ByteBuffer.allocate(Int.SIZE_BYTES).order(ByteOrder.LITTLE_ENDIAN).putInt(this).array()

fun encodeSessionRecord(message: SessionMessage): ByteArray {
    // The payload is one complete RVT1 list value: tag, count, then fields.
    val encodedFields = message.payloadFields().map(::encodePayloadField)
    var payload = byteArrayOf(0x06) + encodedFields.size.toLittleEndianByteArray()
    for (field in encodedFields) {
        payload += field
    }
    if (payload.size > SESSION_MAXIMUM_PAYLOAD_SIZE) {
        throw SessionProtocolException(SessionProtocolFailure.RECORD_TOO_LARGE, "Rivet device session record exceeds its size limit")
    }
    return SESSION_MAGIC +
        byteArrayOf(SESSION_VERSION.toByte(), message.wireType().wireValue.toByte()) +
        payload.size.toLittleEndianByteArray().copyOf(2) +
        payload
}

private class RecordReader(private val data: ByteArray) {
    private var offset = 0
    val remaining: Int get() = data.size - offset

    fun byte(): Int {
        if (remaining < 1) failTruncated()
        return data[offset++].toInt() and 0xff
    }

    fun bytes(count: Int): ByteArray {
        if (count < 0 || count > remaining) failTruncated()
        return data.copyOfRange(offset, offset + count).also { offset += count }
    }

    fun uint32(): Long {
        val raw = bytes(4)
        return ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN).int.toLong() and 0xffff_ffffL
    }

    fun string(): String {
        val bytes = bytes(checkedLength(uint32()))
        return try {
            String(bytes, Charsets.UTF_8)
        } catch (_: Exception) {
            throw SessionProtocolException(SessionProtocolFailure.MALFORMED_PAYLOAD, "malformed Rivet device session payload")
        }
    }

    fun payloadBytes(): ByteArray = bytes(checkedLength(uint32()))

    fun expectEnd() {
        if (!isAtEnd) {
            throw SessionProtocolException(SessionProtocolFailure.MALFORMED_PAYLOAD, "malformed Rivet device session payload")
        }
    }

    private val isAtEnd: Boolean get() = offset == data.size

    companion object {
        internal fun failTruncated(): Nothing =
            throw SessionProtocolException(SessionProtocolFailure.TRUNCATED, "truncated Rivet device session record")

        internal fun failMalformed(): Nothing =
            throw SessionProtocolException(SessionProtocolFailure.MALFORMED_PAYLOAD, "malformed Rivet device session payload")

        internal fun checkedLength(length: Long): Int {
            if (length > SESSION_MAXIMUM_PAYLOAD_SIZE || length > Int.MAX_VALUE) {
                throw SessionProtocolException(SessionProtocolFailure.RECORD_TOO_LARGE, "Rivet device session record exceeds its size limit")
            }
            return length.toInt()
        }
    }
}

fun decodeSessionRecord(record: ByteArray): SessionMessage {
    val reader = RecordReader(record)
    if (!reader.bytes(SESSION_MAGIC.size).contentEquals(SESSION_MAGIC)) {
        throw SessionProtocolException(SessionProtocolFailure.INVALID_MAGIC, "invalid Rivet device session magic")
    }
    val version = reader.byte()
    if (version != SESSION_VERSION) {
        throw SessionProtocolException(SessionProtocolFailure.UNSUPPORTED_VERSION, "unsupported Rivet device session version $version")
    }
    val rawType = reader.byte()
    val type = SessionMessageType.entries.firstOrNull { it.wireValue == rawType }
        ?: throw SessionProtocolException(SessionProtocolFailure.UNKNOWN_MESSAGE_TYPE, "unknown Rivet device session message type")
    val payloadLength =
        (reader.byte() and 0xff) or ((reader.byte() and 0xff) shl 8)
    if (payloadLength > SESSION_MAXIMUM_PAYLOAD_SIZE) {
        throw SessionProtocolException(SessionProtocolFailure.RECORD_TOO_LARGE, "Rivet device session record exceeds its size limit")
    }
    val payload = RecordReader(reader.bytes(payloadLength))

    fun fields(): List<Any> {
        val count = payload.uint32()
        if (count > payload.remaining) RecordReader.failMalformed()
        return List(count.toInt()) {
            when (val tag = payload.byte()) {
                0x01 -> false
                0x02 -> true
                0x03 -> {
                    val raw = payload.bytes(8)
                    ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN).long
                }
                0x04 -> payload.string()
                0x05 -> payload.payloadBytes()
                0x06 -> {
                    val inner = payload.uint32()
                    if (inner > payload.remaining) RecordReader.failMalformed()
                    List(inner.toInt()) {
                        when (payload.byte()) {
                            0x04 -> payload.string()
                            else -> RecordReader.failMalformed()
                        }
                    }
                }
                else -> RecordReader.failMalformed()
            }
        }
    }

    val list = fields()
    fun bytesAt(index: Int): ByteArray = list[index] as? ByteArray ?: RecordReader.failMalformed()
    fun stringAt(index: Int): String = list[index] as? String ?: RecordReader.failMalformed()
    fun longAt(index: Int): Long = list[index] as? Long ?: RecordReader.failMalformed()
    fun scopesAt(index: Int): List<String> {
        val names = list[index] as? List<*> ?: RecordReader.failMalformed()
        val scopeNames = names.map { it as? String ?: RecordReader.failMalformed() }
        requireCanonicalScopes(scopeNames)
        return scopeNames
    }
    fun expectSize(size: Int) {
        if (list.size != size) RecordReader.failMalformed()
    }

    return when (type) {
        SessionMessageType.AUTHENTICATE -> {
            expectSize(3)
            val applicationID = stringAt(0)
            requireApiName(applicationID)
            val clientNonce = bytesAt(2)
            requireBytes(clientNonce, SESSION_NONCE_SIZE)
            SessionMessage.Authenticate(applicationID, requireUuidBytes(bytesAt(1)), clientNonce)
        }
        SessionMessageType.AUTH_CHALLENGE -> {
            expectSize(1)
            val serverNonce = bytesAt(0)
            requireBytes(serverNonce, SESSION_NONCE_SIZE)
            SessionMessage.AuthChallenge(serverNonce)
        }
        SessionMessageType.AUTH_PROOF -> {
            expectSize(1)
            val proof = bytesAt(0)
            requireBytes(proof, SESSION_CREDENTIAL_SIZE)
            SessionMessage.AuthProof(proof)
        }
        SessionMessageType.PAIR_START -> {
            expectSize(4)
            val applicationID = stringAt(0)
            requireApiName(applicationID)
            val deviceName = stringAt(2)
            if (!validDeviceDisplayName(deviceName)) {
                throw SessionProtocolException(SessionProtocolFailure.INVALID_FIELD, "invalid Rivet device session field")
            }
            val clientNonce = bytesAt(3)
            requireBytes(clientNonce, SESSION_NONCE_SIZE)
            SessionMessage.PairStart(applicationID, requireUuidBytes(bytesAt(1)), deviceName, clientNonce)
        }
        SessionMessageType.PAIR_CHALLENGE -> {
            expectSize(2)
            val serverNonce = bytesAt(1)
            requireBytes(serverNonce, SESSION_NONCE_SIZE)
            SessionMessage.PairChallenge(requireUuidBytes(bytesAt(0)), serverNonce)
        }
        SessionMessageType.PAIR_DECISION -> {
            expectSize(2)
            val confirmed = list[1] as? Boolean ?: RecordReader.failMalformed()
            SessionMessage.PairDecision(requireUuidBytes(bytesAt(0)), confirmed)
        }
        SessionMessageType.ACCEPT -> {
            expectSize(4)
            val limits = checkedLimits(longAt(2), longAt(3))
            SessionMessage.Accept(requireUuidBytes(bytesAt(0)), scopesAt(1), limits.first, limits.second)
        }
        SessionMessageType.PAIRED -> {
            expectSize(6)
            val credential = bytesAt(1)
            requireBytes(credential, SESSION_CREDENTIAL_SIZE)
            val limits = checkedLimits(longAt(4), longAt(5))
            SessionMessage.Paired(requireUuidBytes(bytesAt(0)), credential, requireUuidBytes(bytesAt(2)), scopesAt(3), limits.first, limits.second)
        }
        SessionMessageType.REJECT -> {
            expectSize(1)
            val code = SessionRejectCode.fromWire(stringAt(0))
                ?: RecordReader.failMalformed()
            SessionMessage.Reject(code)
        }
    }
}

private fun checkedLimits(maximumPayload: Long, maximumPending: Long): Pair<Long, Long> {
    requireLimits(maximumPayload, maximumPending)
    return maximumPayload to maximumPending
}

/** Incrementally consumes an ordered byte stream while retaining at most one bounded record. */
class SessionRecordDecoder {
    private var buffer: ByteArray = ByteArray(0)
    private var expectedRecordLength: Int? = null
    private var failed = false

    fun append(input: ByteArray): List<SessionMessage> {
        if (failed) {
            throw SessionProtocolException(SessionProtocolFailure.DECODER_FAILED, "Rivet device session decoder is closed after a protocol failure")
        }
        var messages: MutableList<SessionMessage> = mutableListOf()
        var offset = 0
        try {
            while (offset < input.size) {
                val target = expectedRecordLength ?: 8
                val needed = target - buffer.size
                val available = input.size - offset
                val count = minOf(needed, available)
                buffer += input.copyOfRange(offset, offset + count)
                offset += count

                if (expectedRecordLength == null && buffer.size == 8) {
                    validateHeader()
                }
                val expected = expectedRecordLength
                if (expected != null && buffer.size == expected) {
                    messages += decodeSessionRecord(buffer)
                    buffer = ByteArray(0)
                    expectedRecordLength = null
                }
            }
            return messages
        } catch (throwable: Throwable) {
            failed = true
            buffer = ByteArray(0)
            expectedRecordLength = null
            throw throwable
        }
    }

    fun finish() {
        if (failed) {
            throw SessionProtocolException(SessionProtocolFailure.DECODER_FAILED, "Rivet device session decoder is closed after a protocol failure")
        }
        if (buffer.isNotEmpty()) {
            failed = true
            buffer = ByteArray(0)
            expectedRecordLength = null
            throw SessionProtocolException(SessionProtocolFailure.TRUNCATED, "truncated Rivet device session record")
        }
    }

    private fun validateHeader() {
        if (!buffer.copyOfRange(0, 4).contentEquals(SESSION_MAGIC)) {
            throw SessionProtocolException(SessionProtocolFailure.INVALID_MAGIC, "invalid Rivet device session magic")
        }
        if (buffer[4].toInt() != SESSION_VERSION) {
            throw SessionProtocolException(SessionProtocolFailure.UNSUPPORTED_VERSION, "unsupported Rivet device session version ${buffer[4]}")
        }
        SessionMessageType.entries.firstOrNull { it.wireValue == buffer[5].toInt() }
            ?: throw SessionProtocolException(SessionProtocolFailure.UNKNOWN_MESSAGE_TYPE, "unknown Rivet device session message type")
        val payloadLength = (buffer[6].toInt() and 0xff) or ((buffer[7].toInt() and 0xff) shl 8)
        if (payloadLength > SESSION_MAXIMUM_PAYLOAD_SIZE) {
            throw SessionProtocolException(SessionProtocolFailure.RECORD_TOO_LARGE, "Rivet device session record exceeds its size limit")
        }
        expectedRecordLength = 8 + payloadLength
    }
}

private fun appendLengthPrefixed(value: ByteArray, transcript: ByteArrayOutputStream) {
    transcript.write(((value.size ushr 24) and 0xff))
    transcript.write(((value.size ushr 16) and 0xff))
    transcript.write(((value.size ushr 8) and 0xff))
    transcript.write(value.size and 0xff)
    transcript.write(value)
}

/**
 * The reconnect authentication proof: HMAC-SHA256 over the documented
 * byte-exact transcript. Both peers derive the same bytes from shared
 * values; transcript lengths are big-endian.
 */
fun sessionAuthenticationProof(
    credential: ByteArray,
    applicationID: String,
    serverFingerprint: ByteArray,
    deviceID: SessionUuid,
    clientNonce: ByteArray,
    serverNonce: ByteArray,
): ByteArray {
    if (credential.size != SESSION_CREDENTIAL_SIZE || !validDeviceApiName(applicationID) ||
        serverFingerprint.size != SESSION_FINGERPRINT_SIZE ||
        clientNonce.size != SESSION_NONCE_SIZE || serverNonce.size != SESSION_NONCE_SIZE
    ) {
        throw SessionProtocolException(SessionProtocolFailure.INVALID_FIELD, "invalid Rivet device session field")
    }
    val transcript = ByteArrayOutputStream().apply {
        write("rivet-device-auth-v1".encodeToByteArray())
        appendLengthPrefixed(applicationID.encodeToByteArray(), this)
        appendLengthPrefixed(serverFingerprint, this)
        appendLengthPrefixed(uuidBytes(deviceID), this)
        appendLengthPrefixed(clientNonce, this)
        appendLengthPrefixed(serverNonce, this)
    }
    val mac = Mac.getInstance("HmacSHA256")
    mac.init(SecretKeySpec(credential, "HmacSHA256"))
    return mac.doFinal(transcript.toByteArray())
}

/** The six-digit short authentication string both screens show while pairing. */
fun sessionPairingCode(
    applicationID: String,
    serverFingerprint: ByteArray,
    clientNonce: ByteArray,
    serverNonce: ByteArray,
): String {
    if (!validDeviceApiName(applicationID) || serverFingerprint.size != SESSION_FINGERPRINT_SIZE ||
        clientNonce.size != SESSION_NONCE_SIZE || serverNonce.size != SESSION_NONCE_SIZE
    ) {
        throw SessionProtocolException(SessionProtocolFailure.INVALID_FIELD, "invalid Rivet device session field")
    }
    val transcript = ByteArrayOutputStream().apply {
        write("rivet-device-pairing-v1".encodeToByteArray())
        appendLengthPrefixed(applicationID.encodeToByteArray(), this)
        appendLengthPrefixed(serverFingerprint, this)
        appendLengthPrefixed(clientNonce, this)
        appendLengthPrefixed(serverNonce, this)
    }
    val digest = java.security.MessageDigest.getInstance("SHA-256").digest(transcript.toByteArray())
    var prefix = 0u
    for (index in 0 until 4) {
        prefix = (prefix shl 8) or digest[index].toUInt()
    }
    return "%06d".format((prefix % 1_000_000u).toInt())
}

/** Constant-time equality for proof and pin comparisons. */
fun constantTimeEqual(lhs: ByteArray, rhs: ByteArray): Boolean {
    val count = maxOf(lhs.size, rhs.size)
    var difference = lhs.size xor rhs.size
    for (index in 0 until count) {
        val left = if (index < lhs.size) lhs[index].toInt() and 0xff else 0
        val right = if (index < rhs.size) rhs[index].toInt() and 0xff else 0
        difference = difference or (left xor right)
    }
    return difference == 0
}
