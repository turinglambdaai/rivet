package dev.rivet.session

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import kotlin.test.Test
import kotlin.test.assertFailsWith

class DeviceRVT1ClientTest {
    private val uuid = SessionUuid(ByteArray(16))

    private fun acceptance(payload: Long, pending: Long) = SessionAcceptance(
        sessionID = uuid,
        deviceID = uuid,
        scopeNames = listOf("reader"),
        maximumPayload = payload,
        maximumPending = pending,
    )

    @Test
    fun acceptsTheNegotiatedLimitsWithoutOpeningAConnection() {
        val client = createDeviceRVT1Client(
            acceptance(512L * 1024, 64),
            ByteArrayInputStream(byteArrayOf()),
            ByteArrayOutputStream(),
        )
        client.close()
    }

    @Test
    fun rejectsInvalidOrUnboundedNegotiatedLimits() {
        for (payload in listOf(-1L, 0L, 512L * 1024 + 1)) {
            assertFailsWith<IllegalArgumentException> {
                createDeviceRVT1Client(
                    acceptance(payload, 1), ByteArrayInputStream(byteArrayOf()), ByteArrayOutputStream(),
                )
            }
        }
        for (pending in listOf(-1L, 0L, 65L, Long.MAX_VALUE)) {
            assertFailsWith<IllegalArgumentException> {
                createDeviceRVT1Client(
                    acceptance(1, pending), ByteArrayInputStream(byteArrayOf()), ByteArrayOutputStream(),
                )
            }
        }
    }
}
