package dev.rivet.runtime

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class ProtocolTest {
    @Test
    fun sharedGoldenVectorsMatchKotlinRuntime() {
        for (line in goldenLines()) {
            val fields = line.split('|')
            val kind = fields[0]
            val wire = fields[2].hexBytes()
            when (kind) {
                "value" -> assertContentEquals(wire, encodeRivetValue(decodeRivetValue(wire)), fields[1])
                "frame" -> assertContentEquals(wire, encodeRivetFrame(decodeRivetFrame(wire)), fields[1])
                "invalid-value" -> assertFailsWith<RivetProtocolException>(fields[1]) {
                    decodeRivetValue(wire)
                }
                "invalid-frame" -> assertFailsWith<RivetProtocolException>(fields[1]) {
                    decodeRivetFrame(wire)
                }
                else -> error("unknown golden vector kind: $kind")
            }
        }
    }

    @Test
    fun signedIntegersAndBinaryPayloadsRoundTrip() {
        val value = RivetValue.ListValue(
            listOf(
                RivetValue.Int64(Long.MIN_VALUE),
                RivetValue.Int64(-2),
                RivetValue.Int64(Long.MAX_VALUE),
                RivetValue.Bytes(byteArrayOf(0, -1, 127)),
            ),
        )
        assertEquals(value, decodeRivetValue(encodeRivetValue(value)))
    }

    @Test
    fun frameKeepsUnsignedRequestIdentifier() {
        val frame = RivetFrame(RivetMessageType.REQUEST, ULong.MAX_VALUE, encodeRivetValue(RivetValue.Null))
        assertEquals(frame, decodeRivetFrame(encodeRivetFrame(frame)))
    }

    @Test
    fun publicBinaryValuesHaveValueSemantics() {
        val source = byteArrayOf(1, 2, 3)
        val bytes = RivetValue.Bytes(source)
        val frame = RivetFrame(RivetMessageType.EVENT, 7u, source)
        source[0] = 99

        assertContentEquals(byteArrayOf(1, 2, 3), bytes.toByteArray())
        assertContentEquals(byteArrayOf(1, 2, 3), frame.payload)

        val exposed = frame.payload
        exposed[1] = 88
        assertContentEquals(byteArrayOf(1, 2, 3), frame.payload)
    }

    @Test
    fun nestingLimitIsEnforcedOnEncodeAndDecode() {
        var value: RivetValue = RivetValue.Null
        repeat(RIVET_MAX_VALUE_DEPTH + 1) { value = RivetValue.ListValue(listOf(value)) }
        val error = assertFailsWith<RivetProtocolException> { encodeRivetValue(value) }
        assertEquals(RivetProtocolFailure.NESTING_TOO_DEEP, error.failure)
    }

    private fun goldenLines(): List<String> =
        checkNotNull(javaClass.classLoader.getResourceAsStream("protocol-golden.txt"))
            .bufferedReader()
            .useLines { lines ->
                lines.filter { it.isNotBlank() && !it.startsWith('#') }.toList()
            }

    private fun String.hexBytes(): ByteArray {
        require(length % 2 == 0)
        return ByteArray(length / 2) { index -> substring(index * 2, index * 2 + 2).toInt(16).toByte() }
    }
}
