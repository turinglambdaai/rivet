package dev.rivet.session

import javax.crypto.KeyGenerator
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse

class DevicePairingEnvelopeTest {
    private val deviceID = SessionUuid(ByteArray(SESSION_UUID_SIZE) { it.toByte() })
    private val credential = ByteArray(SESSION_CREDENTIAL_SIZE) { 0x11 }
    private val pin = ByteArray(SESSION_FINGERPRINT_SIZE) { 0x22 }
    private val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()

    @Test
    fun authenticatedEncryptedRoundTripKeepsSecretsOffTheWire() {
        val material = DevicePairingMaterial(credential, pin)
        val ciphertext = DevicePairingEnvelope.seal("com.example.app", deviceID, material, key)
        assertFalse(ciphertext.toList().windowed(credential.size).any { it == credential.toList() })
        val restored = DevicePairingEnvelope.open("com.example.app", deviceID, ciphertext, key)
        assertContentEquals(credential, restored.credential)
        assertContentEquals(pin, restored.serverFingerprint)
        restored.credential.fill(0)
        restored.serverFingerprint.fill(0)
        assertContentEquals(credential, restored.credential)
        assertContentEquals(pin, restored.serverFingerprint)
    }

    @Test
    fun ciphertextTamperingAndIdentitySwapAreRejected() {
        val ciphertext = DevicePairingEnvelope.seal(
            "com.example.app", deviceID, DevicePairingMaterial(credential, pin), key,
        )
        val tampered = ciphertext.copyOf().also { it[it.lastIndex] = (it.last().toInt() xor 1).toByte() }
        assertFailsWith<IllegalStateException> {
            DevicePairingEnvelope.open("com.example.app", deviceID, tampered, key)
        }
        assertFailsWith<IllegalStateException> {
            DevicePairingEnvelope.open("com.other.app", deviceID, ciphertext, key)
        }
        assertFailsWith<IllegalStateException> {
            DevicePairingEnvelope.open(
                "com.example.app", SessionUuid(ByteArray(SESSION_UUID_SIZE) { 0x44 }), ciphertext, key,
            )
        }
    }

    @Test
    fun malformedLengthVersionAndDifferentKeyFailClosed() {
        val ciphertext = DevicePairingEnvelope.seal(
            "com.example.app", deviceID, DevicePairingMaterial(credential, pin), key,
        )
        val wrongVersion = ciphertext.copyOf().also { it[0] = 2 }
        assertFailsWith<IllegalArgumentException> {
            DevicePairingEnvelope.open("com.example.app", deviceID, wrongVersion, key)
        }
        assertFailsWith<IllegalArgumentException> {
            DevicePairingEnvelope.open("com.example.app", deviceID, ciphertext.dropLast(1).toByteArray(), key)
        }
        val different = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        assertFailsWith<IllegalStateException> {
            DevicePairingEnvelope.open("com.example.app", deviceID, ciphertext, different)
        }
    }

    @Test
    fun invalidSecretSizesAreRejected() {
        assertFailsWith<IllegalArgumentException> {
            DevicePairingMaterial(ByteArray(1), pin)
        }
        assertFailsWith<IllegalArgumentException> {
            DevicePairingMaterial(credential, ByteArray(1))
        }
    }
}
