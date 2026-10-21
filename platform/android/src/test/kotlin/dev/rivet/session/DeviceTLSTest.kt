package dev.rivet.session

import java.security.KeyPairGenerator
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class DeviceTLSTest {
    @Test
    fun serverPinsMatchEncodedSubjectPublicKeyInfo() {
        val generator = KeyPairGenerator.getInstance("EC")
        generator.initialize(256)
        val first = generator.generateKeyPair().public.encoded
        val second = generator.generateKeyPair().public.encoded
        val fingerprint = spkiFingerprint(first)
        val different = spkiFingerprint(second)
        assertEquals(SESSION_FINGERPRINT_SIZE, fingerprint.size)
        assertFalse(fingerprint.contentEquals(different))

        val supplied = fingerprint.copyOf()
        val pin = DeviceServerAuthentication.Pinned(supplied)
        supplied.fill(0) // Changing the caller's buffer must not change the pin.
        assertTrue(pin.permits(fingerprint))
        assertFalse(pin.permits(different))
        assertTrue(DeviceServerAuthentication.ProvisionalPairing.permits(different))
        assertFalse(DeviceServerAuthentication.ProvisionalPairing.permits(ByteArray(31)))
        assertFailsWith<IllegalArgumentException> {
            DeviceServerAuthentication.Pinned(ByteArray(31))
        }
        assertFailsWith<IllegalArgumentException> { spkiFingerprint(ByteArray(0)) }
    }

    @Test
    fun policyAllowsOnlyModernTLSAndForwardSecretAeadSuites() {
        assertContentEquals(
            arrayOf("TLSv1.3", "TLSv1.2"),
            deviceTLSAllowedProtocols(arrayOf("SSLv3", "TLSv1.3", "TLSv1.1", "TLSv1.2")),
        )
        assertContentEquals(
            arrayOf("TLS_AES_128_GCM_SHA256", "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384"),
            deviceTLSAllowedCipherSuites(
                arrayOf(
                    "TLS_RSA_WITH_AES_128_CBC_SHA",
                    "TLS_AES_128_GCM_SHA256",
                    "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
                    "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA",
                ),
            ),
        )
        assertTrue(deviceTLSAllowedProtocols(arrayOf("TLSv1.0")).isEmpty())
        assertTrue(deviceTLSAllowedCipherSuites(arrayOf("TLS_RSA_WITH_AES_128_GCM_SHA256")).isEmpty())
    }

    @Test
    fun badConnectionSettingsFailBeforeOpeningAnySocket() {
        val auth = DeviceServerAuthentication.ProvisionalPairing
        assertFailsWith<IllegalArgumentException> {
            DeviceTLSClient.connect("", 4444, auth)
        }
        assertFailsWith<IllegalArgumentException> {
            DeviceTLSClient.connect("127.0.0.1", 0, auth)
        }
        assertFailsWith<IllegalArgumentException> {
            DeviceTLSClient.connect("127.0.0.1", 4444, auth, timeoutMillis = 0)
        }
        assertFailsWith<IllegalArgumentException> {
            DeviceTLSClient.connect("127.0.0.1", 4444, auth, timeoutMillis = 30_001)
        }
    }
}
