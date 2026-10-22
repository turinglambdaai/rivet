package dev.rivet.session

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertNull

class AndroidNsdAttributesTest {
    private val id = "00112233445566778899aabbccddeeff"
    private fun attrs(pair: String = "1", version: String = "1", name: String = id) =
        mapOf("id" to name.encodeToByteArray(), "pair" to pair.encodeToByteArray(),
              "v" to version.encodeToByteArray())

    @Test fun acceptsCanonicalFieldsRegardlessOfMapOrder() {
        assertContentEquals(
            encodeDiscoveryTXT(DeviceAdvertisement(id, true)),
            deviceDiscoveryTXTFromAttributes(linkedMapOf(
                "v" to "1".encodeToByteArray(),
                "pair" to "1".encodeToByteArray(),
                "id" to id.encodeToByteArray(),
            )),
        )
    }

    @Test fun rejectsMissingUnknownInvalidAndMalformedFields() {
        val invalid = listOf(
            emptyMap(),
            attrs() - "pair",
            attrs() + ("product" to "secret".encodeToByteArray()),
            attrs(pair = "true"), attrs(version = "2"),
            attrs(name = "xyz"),
            attrs() + ("id" to ByteArray(129)),
            attrs() + ("id" to byteArrayOf(0xc3.toByte(), 0x28)),
            attrs() + ("pair" to byteArrayOf()),
        )
        invalid.forEach { assertNull(deviceDiscoveryTXTFromAttributes(it)) }
    }
}
