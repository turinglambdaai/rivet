package dev.rivet.session

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.io.IOException
import java.security.GeneralSecurityException
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

/**
 * Product-scoped Android pairing persistence for the RVD1 save-before-accept
 * gate. One AndroidKeyStore AES-256-GCM key per application ID protects every
 * record; the AES-GCM additional authenticated data binds each sealed
 * credential/pin pair to its product and paired device, so only
 * authenticated ciphertext is kept in private SharedPreferences.
 *
 * A missing Keystore key never causes an existing record to be regenerated
 * or trusted. Products must own backup exclusions, pairing consent UI, and
 * desktop-side revocation. Do not export this preferences file in backups.
 */
class AndroidKeystorePairingStore(
    context: Context,
    private val applicationID: String,
) : SessionCredentialStore {
    init {
        require(applicationID.matches(Regex("[A-Za-z0-9][A-Za-z0-9._-]{2,199}"))) {
            "invalid pairing application ID"
        }
    }

    private val preferences = context.applicationContext.getSharedPreferences(
        "dev.rivet.device.pairing.v1", Context.MODE_PRIVATE,
    )
    private val prefix = applicationID + "."
    private val alias = "dev.rivet.device.pairing." + MessageDigest.getInstance("SHA-256")
        .digest(applicationID.encodeToByteArray())
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }

    /** A duplicate pairing ID must be removed explicitly, not silently rotated. */
    @Synchronized
    override fun savePairingCredential(
        deviceID: SessionUuid,
        credential: ByteArray,
        serverFingerprint: ByteArray,
    ) {
        val name = recordName(deviceID)
        check(!preferences.contains(name)) { "Rivet device is already paired" }
        val material = DevicePairingMaterial(credential, serverFingerprint)
        val sealed = DevicePairingEnvelope.seal(applicationID, deviceID, material, key(create = true)!!)
        val encoded = Base64.encodeToString(sealed, Base64.NO_WRAP)
        check(preferences.edit().putString(name, encoded).commit()) {
            "Rivet pairing credential could not be persisted"
        }
    }

    /** Return a defensive copy of stored secrets, or null for an unknown ID. */
    @Synchronized
    fun loadPairing(deviceID: SessionUuid): DevicePairingMaterial? {
        val encoded = preferences.getString(recordName(deviceID), null) ?: return null
        // Existing ciphertext with a deleted/restored Keystore key is not a
        // new-pairing opportunity: fail closed and require explicit removal.
        val savedKey = key(create = false)
            ?: throw IllegalStateException("Rivet pairing Keystore key is unavailable")
        val sealed = try {
            Base64.decode(encoded, Base64.NO_WRAP)
        } catch (_: IllegalArgumentException) {
            throw IllegalStateException("Rivet pairing credential record is invalid")
        }
        return DevicePairingEnvelope.open(applicationID, deviceID, sealed, savedKey)
    }

    @Synchronized
    fun removePairing(deviceID: SessionUuid): Boolean {
        val name = recordName(deviceID)
        if (!preferences.contains(name)) return false
        check(preferences.edit().remove(name).commit()) {
            "Rivet pairing removal could not be persisted"
        }
        return true
    }

    /** Non-secret local metadata. This does not query the remote gateway. */
    @Synchronized
    fun savedDeviceIDs(): List<SessionUuid> =
        preferences.all.keys
            .filter { it.startsWith(prefix) && it.length == prefix.length + SESSION_UUID_SIZE * 2 }
            .mapNotNull { name ->
                val hex = name.substring(prefix.length)
                if (!hex.all { it in '0'..'9' || it in 'a'..'f' }) null
                else SessionUuid(ByteArray(SESSION_UUID_SIZE) { i ->
                    hex.substring(i * 2, i * 2 + 2).toInt(16).toByte()
                })
            }
            .sortedBy { it.bytes.joinToString("") { b -> "%02x".format(b.toInt() and 0xff) } }

    private fun recordName(id: SessionUuid): String =
        prefix + id.bytes.joinToString("") { "%02x".format(it.toInt() and 0xff) }

    /**
     * Keystore machinery failures (corrupted store, removed provider, hardware
     * key loss) surface as the store's own IllegalStateException taxonomy so
     * callers face one failure type per operation, never a raw KeyStore one.
     */
    private fun key(create: Boolean): SecretKey? = try {
        val store = KeyStore.getInstance("AndroidKeyStore").also { it.load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        if (!create) return null
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setKeySize(256)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build(),
        )
        generator.generateKey()
    } catch (failure: GeneralSecurityException) {
        throw IllegalStateException("Rivet pairing Keystore key is unavailable", failure)
    } catch (failure: IOException) {
        throw IllegalStateException("Rivet pairing Keystore key is unavailable", failure)
    }
}
