package dev.rivet.session

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class DeviceSessionTest {
    private val applicationID = "com.example.app"
    private val deviceID = SessionUuid(ByteArray(16) { it.toByte() })
    private val fingerprint = ByteArray(SESSION_FINGERPRINT_SIZE) { 0x55 }
    private val clientNonce = ByteArray(SESSION_NONCE_SIZE) { 0x11 }
    private val serverNonce = ByteArray(SESSION_NONCE_SIZE) { 0x22 }
    private val credential = ByteArray(SESSION_CREDENTIAL_SIZE) { 0x33 }

    @Test
    fun recordsRoundTripThroughEncodeAndDecode() {
        val messages: List<SessionMessage> = listOf(
            SessionMessage.Authenticate(applicationID, deviceID, clientNonce),
            SessionMessage.AuthChallenge(serverNonce),
            SessionMessage.AuthProof(credential),
            SessionMessage.PairStart(applicationID, SessionUuid(ByteArray(16) { 1 }), "Test Phone", clientNonce),
            SessionMessage.PairChallenge(SessionUuid(ByteArray(16) { 2 }), serverNonce),
            SessionMessage.PairDecision(SessionUuid(ByteArray(16) { 2 }), true),
            SessionMessage.Accept(SessionUuid(ByteArray(16) { 3 }), listOf("controller", "reader"), 524288L, 64L),
            SessionMessage.Paired(
                deviceID,
                credential,
                SessionUuid(ByteArray(16) { 3 }),
                listOf("controller", "reader"),
                524288L,
                64L,
            ),
            SessionMessage.Reject(SessionRejectCode.AUTHENTICATION_FAILED),
        )
        for (message in messages) {
            val encoded = encodeSessionRecord(message)
            assertTrue(encoded.size <= SESSION_MAXIMUM_RECORD_SIZE)
            assertEquals(message, decodeSessionRecord(encoded))
        }
    }

    @Test
    fun goldenFixtureRecordsDecodeAndReencodeIdentically() {
        val lines = javaClass.getResourceAsStream("/device-session-golden.txt")
            ?.bufferedReader()?.readLines()
            ?: error("device-session-golden.txt missing from test resources")
        var records = 0
        var proofs = 0
        var codes = 0
        for (line in lines) {
            if (line.isEmpty() || line.startsWith("#")) continue
            val parts = line.split("|")
            assertEquals(3, parts.size)
            val bytes = parts[2].chunked(2).map { it.toInt(16).toByte() }.toByteArray()
            when (parts[0]) {
                "record" -> {
                    records += 1
                    assertEquals(bytes.toList(), encodeSessionRecord(decodeSessionRecord(bytes)).toList())
                }
                "proof" -> {
                    proofs += 1
                    val computed = sessionAuthenticationProof(
                        ByteArray(SESSION_CREDENTIAL_SIZE) { 0x33 },
                        "com.example.app",
                        ByteArray(SESSION_FINGERPRINT_SIZE) { 0x55 },
                        SessionUuid(hex("00112233445566778899aabbccddeeff")),
                        ByteArray(SESSION_NONCE_SIZE) { 0x11 },
                        ByteArray(SESSION_NONCE_SIZE) { 0x22 },
                    )
                    assertEquals(bytes.toList(), computed.toList())
                }
                "code" -> {
                    codes += 1
                    val computed = sessionPairingCode(
                        "com.example.app",
                        ByteArray(SESSION_FINGERPRINT_SIZE) { 0x55 },
                        ByteArray(SESSION_NONCE_SIZE) { 0x11 },
                        ByteArray(SESSION_NONCE_SIZE) { 0x22 },
                    )
                    assertEquals(parts[2], computed)
                }
            }
        }
        assertTrue(records > 0 && proofs > 0 && codes > 0)
    }

    private fun hex(value: String): ByteArray = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    @Test
    fun decoderConsumesFragmentedAndCoalescedRecords() {
        val record = encodeSessionRecord(SessionMessage.AuthChallenge(serverNonce))
        val byteWise = SessionRecordDecoder()
        val messages = mutableListOf<SessionMessage>()
        for (byte in record) {
            messages += byteWise.append(byteArrayOf(byte))
        }
        byteWise.finish()
        assertEquals(1, messages.size)

        val coalesced = SessionRecordDecoder()
        val two = coalesced.append(record + record)
        coalesced.finish()
        assertEquals(2, two.size)

        val poisoned = SessionRecordDecoder()
        assertFailsWith<SessionProtocolException> { poisoned.append(byteArrayOf(0, 1, 2, 3, 4, 5, 6, 7)) }
        assertFailsWith<SessionProtocolException> { poisoned.append(record) }
    }

    @Test
    fun malformedRecordsFailClosed() {
        assertFailsWith<SessionProtocolException> { decodeSessionRecord(ByteArray(0)) }
        assertFailsWith<SessionProtocolException> {
            decodeSessionRecord(byteArrayOf(0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07))
        }
        assertFailsWith<SessionProtocolException> {
            val header = encodeSessionRecord(SessionMessage.AuthChallenge(serverNonce))
            header[4] = 9
            decodeSessionRecord(header)
        }
    }

    @Test
    fun canonicalScopesAndDisplayNamesValidate() {
        assertTrue(validScopeNames(listOf("reader", "writer")))
        assertFalse(validScopeNames(listOf("reader", "reader")))
        assertFalse(validScopeNames(List(65) { "scope$it" }))
        assertTrue(validDeviceDisplayName("Test Phone"))
        assertFalse(validDeviceDisplayName(" padded"))
        assertFalse(validDeviceDisplayName("line\nbreak"))
    }
}
