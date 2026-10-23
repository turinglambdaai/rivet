package dev.rivet.session

import java.nio.ByteBuffer
import java.security.GeneralSecurityException
import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Secret-bearing pairing data: never store or log this outside encrypted storage. */
class DevicePairingMaterial(credential: ByteArray, serverFingerprint: ByteArray) {
    private val storedCredential = credential.copyOf()
    private val storedFingerprint = serverFingerprint.copyOf()

    init {
        require(storedCredential.size == SESSION_CREDENTIAL_SIZE) { "invalid device credential length" }
        require(storedFingerprint.size == SESSION_FINGERPRINT_SIZE) { "invalid server fingerprint length" }
    }

    val credential: ByteArray get() = storedCredential.copyOf()
    val serverFingerprint: ByteArray get() = storedFingerprint.copyOf()

    fun reconnectIntent(applicationID: String, deviceID: SessionUuid): DeviceCompanionIntent.Reconnect =
        DeviceCompanionIntent.Reconnect(applicationID, deviceID, credential, serverFingerprint)
}

/**
 * Versioned, fixed-size, authenticated envelope for an Android Keystore AES
 * key. No plaintext credential or SPKI is stored in SharedPreferences.
 * AES-GCM additional authenticated data binds each record to a product and
 * paired device, making ciphertext swapping across records fail closed.
 */
object DevicePairingEnvelope {
    private const val VERSION: Byte = 1
    private const val IV_SIZE = 12
    private const val TAG_BITS = 128
    private const val HEADER_SIZE = 1 + IV_SIZE
    private const val PLAIN_SIZE = SESSION_CREDENTIAL_SIZE + SESSION_FINGERPRINT_SIZE
    private const val SEALED_SIZE = HEADER_SIZE + PLAIN_SIZE + TAG_BITS / 8

    fun seal(
        applicationID: String,
        deviceID: SessionUuid,
        material: DevicePairingMaterial,
        key: SecretKey,
    ): ByteArray {
        val payload = material.credential + material.serverFingerprint
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key)
            val iv = cipher.iv
            check(iv.size == IV_SIZE) { "unexpected Rivet pairing IV size" }
            cipher.updateAAD(aad(applicationID, deviceID))
            val ciphertext = cipher.doFinal(payload)
            return byteArrayOf(VERSION) + iv + ciphertext
        } finally {
            payload.fill(0)
        }
    }

    fun open(
        applicationID: String,
        deviceID: SessionUuid,
        envelope: ByteArray,
        key: SecretKey,
    ): DevicePairingMaterial {
        require(envelope.size == SEALED_SIZE && envelope[0] == VERSION) {
            "unsupported or malformed Rivet pairing credential envelope"
        }
        val iv = envelope.copyOfRange(1, HEADER_SIZE)
        val ciphertext = envelope.copyOfRange(HEADER_SIZE, envelope.size)
        val plaintext = try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BITS, iv))
            cipher.updateAAD(aad(applicationID, deviceID))
            cipher.doFinal(ciphertext)
        } catch (_: GeneralSecurityException) {
            throw IllegalStateException("Rivet pairing credential authentication failed")
        }
        try {
            check(plaintext.size == PLAIN_SIZE) { "invalid decrypted device credential" }
            return DevicePairingMaterial(
                plaintext.copyOfRange(0, SESSION_CREDENTIAL_SIZE),
                plaintext.copyOfRange(SESSION_CREDENTIAL_SIZE, PLAIN_SIZE),
            )
        } finally {
            plaintext.fill(0)
        }
    }

    private fun aad(applicationID: String, deviceID: SessionUuid): ByteArray {
        require(applicationID.isNotBlank() && applicationID.length <= 200) {
            "invalid pairing application ID"
        }
        val app = applicationID.encodeToByteArray()
        return ByteBuffer.allocate(4 + app.size + SESSION_UUID_SIZE)
            .putInt(app.size)
            .put(app)
            .put(deviceID.bytes)
            .array()
    }
}
