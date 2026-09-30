package dev.rivet.runtime

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.CodingErrorAction

const val RIVET_PROTOCOL_VERSION: Int = 1
const val RIVET_MAX_FRAME_PAYLOAD_SIZE: Int = 64 * 1024 * 1024
const val RIVET_MAX_VALUE_DEPTH: Int = 64
const val RIVET_MAX_VALUE_NODES: Int = 1 shl 18

enum class RivetMessageType(val wireValue: Int) {
    HELLO(1),
    REQUEST(2),
    RESPONSE(3),
    ERROR(4),
    EVENT(5),
    CANCEL(6),
    SHUTDOWN(7);

    companion object {
        fun fromWire(value: Int): RivetMessageType? = entries.firstOrNull { it.wireValue == value }
    }
}

sealed interface RivetValue {
    data object Null : RivetValue
    data class Bool(val value: Boolean) : RivetValue
    data class Int64(val value: Long) : RivetValue
    data class StringValue(val value: String) : RivetValue
    class Bytes(value: ByteArray) : RivetValue {
        private val storage = value.copyOf()

        fun toByteArray(): ByteArray = storage.copyOf()
        internal fun wireBytes(): ByteArray = storage

        override fun equals(other: Any?): Boolean =
            other is Bytes && storage.contentEquals(other.storage)

        override fun hashCode(): Int = storage.contentHashCode()
        override fun toString(): String = "Bytes(${storage.size} bytes)"
    }
    class ListValue(values: List<RivetValue>) : RivetValue {
        val values: List<RivetValue> = values.toList()

        override fun equals(other: Any?): Boolean = other is ListValue && values == other.values
        override fun hashCode(): Int = values.hashCode()
        override fun toString(): String = "ListValue($values)"
    }
}

class RivetFrame(
    val type: RivetMessageType,
    val id: ULong,
    payload: ByteArray = byteArrayOf(),
) {
    private val payloadStorage = payload.copyOf()
    val payload: ByteArray get() = payloadStorage.copyOf()
    internal fun wirePayload(): ByteArray = payloadStorage

    override fun equals(other: Any?): Boolean =
        other is RivetFrame &&
            type == other.type &&
            id == other.id &&
            payloadStorage.contentEquals(other.payloadStorage)

    override fun hashCode(): Int =
        31 * (31 * type.hashCode() + id.hashCode()) + payloadStorage.contentHashCode()

    override fun toString(): String =
        "RivetFrame(type=$type, id=$id, payload=${payloadStorage.size} bytes)"
}

enum class RivetProtocolFailure {
    TRUNCATED,
    INVALID_MAGIC,
    UNSUPPORTED_VERSION,
    UNKNOWN_MESSAGE_TYPE,
    UNKNOWN_VALUE_TAG,
    INVALID_UTF8,
    TRAILING_BYTES,
    LENGTH_OVERFLOW,
    NESTING_TOO_DEEP,
}

class RivetProtocolException(
    val failure: RivetProtocolFailure,
    message: String,
) : Exception(message)

private const val TAG_NULL = 0x00
private const val TAG_FALSE = 0x01
private const val TAG_TRUE = 0x02
private const val TAG_INT64 = 0x03
private const val TAG_STRING = 0x04
private const val TAG_BYTES = 0x05
private const val TAG_LIST = 0x06
private val MAGIC = byteArrayOf(0x52, 0x56, 0x54, 0x31)

private fun failure(reason: RivetProtocolFailure, message: String): Nothing =
    throw RivetProtocolException(reason, message)

private class Reader(private val data: ByteArray) {
    private var offset = 0
    val remaining: Int get() = data.size - offset
    val isAtEnd: Boolean get() = offset == data.size

    fun byte(): Int {
        if (remaining < 1) failure(RivetProtocolFailure.TRUNCATED, "truncated Rivet payload")
        return data[offset++].toInt() and 0xff
    }

    fun bytes(count: Int): ByteArray {
        if (count < 0 || count > remaining) {
            failure(RivetProtocolFailure.TRUNCATED, "truncated Rivet payload")
        }
        return data.copyOfRange(offset, offset + count).also { offset += count }
    }

    fun uint32(): Long {
        val raw = bytes(Int.SIZE_BYTES)
        return ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN).int.toLong() and 0xffff_ffffL
    }

    fun uint64(): ULong {
        val raw = bytes(Long.SIZE_BYTES)
        return ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN).long.toULong()
    }
}

private class BoundedWriter(
    private val maximumSize: Int = RIVET_MAX_FRAME_PAYLOAD_SIZE,
) {
    private val output = ByteArrayOutputStream()

    private fun reserve(count: Int) {
        if (count < 0 || output.size() > maximumSize - count) {
            failure(RivetProtocolFailure.LENGTH_OVERFLOW, "Rivet value exceeds protocol length limit")
        }
    }

    fun byte(value: Int) {
        reserve(1)
        output.write(value)
    }

    fun bytes(value: ByteArray) {
        reserve(value.size)
        output.write(value)
    }

    fun uint32(value: Int) {
        reserve(Int.SIZE_BYTES)
        output.write(ByteBuffer.allocate(Int.SIZE_BYTES).order(ByteOrder.LITTLE_ENDIAN).putInt(value).array())
    }

    fun uint64(value: ULong) {
        reserve(Long.SIZE_BYTES)
        output.write(ByteBuffer.allocate(Long.SIZE_BYTES).order(ByteOrder.LITTLE_ENDIAN).putLong(value.toLong()).array())
    }

    fun result(): ByteArray = output.toByteArray()
}

fun encodeRivetValue(value: RivetValue): ByteArray {
    val writer = BoundedWriter()
    val budget = intArrayOf(RIVET_MAX_VALUE_NODES)
    encodeValue(value, writer, 0, budget)
    return writer.result()
}

private fun encodeValue(value: RivetValue, writer: BoundedWriter, depth: Int, budget: IntArray) {
    if (budget[0] <= 0) {
        failure(RivetProtocolFailure.LENGTH_OVERFLOW, "Rivet value exceeds protocol node limit")
    }
    budget[0]--

    when (value) {
        RivetValue.Null -> writer.byte(TAG_NULL)
        is RivetValue.Bool -> writer.byte(if (value.value) TAG_TRUE else TAG_FALSE)
        is RivetValue.Int64 -> {
            writer.byte(TAG_INT64)
            writer.uint64(value.value.toULong())
        }
        is RivetValue.StringValue -> {
            val encoded = value.value.toByteArray(Charsets.UTF_8)
            writer.byte(TAG_STRING)
            writer.uint32(encoded.size)
            writer.bytes(encoded)
        }
        is RivetValue.Bytes -> {
            val bytes = value.wireBytes()
            writer.byte(TAG_BYTES)
            writer.uint32(bytes.size)
            writer.bytes(bytes)
        }
        is RivetValue.ListValue -> {
            if (depth >= RIVET_MAX_VALUE_DEPTH) {
                failure(RivetProtocolFailure.NESTING_TOO_DEEP, "Rivet value nesting exceeds protocol limit")
            }
            if (value.values.size > budget[0]) {
                failure(RivetProtocolFailure.LENGTH_OVERFLOW, "Rivet value exceeds protocol node limit")
            }
            writer.byte(TAG_LIST)
            writer.uint32(value.values.size)
            value.values.forEach { encodeValue(it, writer, depth + 1, budget) }
        }
    }
}

fun decodeRivetValue(data: ByteArray): RivetValue {
    if (data.size > RIVET_MAX_FRAME_PAYLOAD_SIZE) {
        failure(RivetProtocolFailure.LENGTH_OVERFLOW, "Rivet value exceeds protocol length limit")
    }
    val reader = Reader(data)
    val budget = intArrayOf(RIVET_MAX_VALUE_NODES)
    val value = decodeValue(reader, 0, budget)
    if (!reader.isAtEnd) failure(RivetProtocolFailure.TRAILING_BYTES, "trailing bytes after Rivet value")
    return value
}

private fun decodeValue(reader: Reader, depth: Int, budget: IntArray): RivetValue {
    if (budget[0] <= 0) {
        failure(RivetProtocolFailure.LENGTH_OVERFLOW, "Rivet value exceeds protocol node limit")
    }
    budget[0]--

    return when (val tag = reader.byte()) {
        TAG_NULL -> RivetValue.Null
        TAG_FALSE -> RivetValue.Bool(false)
        TAG_TRUE -> RivetValue.Bool(true)
        TAG_INT64 -> RivetValue.Int64(reader.uint64().toLong())
        TAG_STRING -> {
            val bytes = readLengthPrefixed(reader)
            val decoder = Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
            val value = try {
                decoder.decode(ByteBuffer.wrap(bytes)).toString()
            } catch (_: Exception) {
                failure(RivetProtocolFailure.INVALID_UTF8, "invalid UTF-8 in Rivet string")
            }
            RivetValue.StringValue(value)
        }
        TAG_BYTES -> RivetValue.Bytes(readLengthPrefixed(reader))
        TAG_LIST -> {
            if (depth >= RIVET_MAX_VALUE_DEPTH) {
                failure(RivetProtocolFailure.NESTING_TOO_DEEP, "Rivet value nesting exceeds protocol limit")
            }
            val count = checkedLength(reader.uint32())
            if (count > budget[0]) {
                failure(RivetProtocolFailure.LENGTH_OVERFLOW, "Rivet value exceeds protocol node limit")
            }
            if (count > reader.remaining) {
                failure(RivetProtocolFailure.TRUNCATED, "truncated Rivet list")
            }
            RivetValue.ListValue(List(count) { decodeValue(reader, depth + 1, budget) })
        }
        else -> failure(RivetProtocolFailure.UNKNOWN_VALUE_TAG, "unknown Rivet value tag $tag")
    }
}

private fun checkedLength(length: Long): Int {
    if (length > RIVET_MAX_FRAME_PAYLOAD_SIZE || length > Int.MAX_VALUE) {
        failure(RivetProtocolFailure.LENGTH_OVERFLOW, "Rivet value exceeds protocol length limit")
    }
    return length.toInt()
}

private fun readLengthPrefixed(reader: Reader): ByteArray = reader.bytes(checkedLength(reader.uint32()))

fun encodeRivetFrame(frame: RivetFrame): ByteArray {
    val payload = frame.wirePayload()
    if (payload.size > RIVET_MAX_FRAME_PAYLOAD_SIZE) {
        failure(RivetProtocolFailure.LENGTH_OVERFLOW, "Rivet frame exceeds protocol length limit")
    }
    val writer = BoundedWriter(RIVET_MAX_FRAME_PAYLOAD_SIZE + 18)
    writer.bytes(MAGIC)
    writer.byte(RIVET_PROTOCOL_VERSION)
    writer.byte(frame.type.wireValue)
    writer.uint64(frame.id)
    writer.uint32(payload.size)
    writer.bytes(payload)
    return writer.result()
}

fun decodeRivetFrame(data: ByteArray): RivetFrame {
    val reader = Reader(data)
    if (!reader.bytes(MAGIC.size).contentEquals(MAGIC)) {
        failure(RivetProtocolFailure.INVALID_MAGIC, "invalid Rivet frame magic")
    }
    val version = reader.byte()
    if (version != RIVET_PROTOCOL_VERSION) {
        failure(RivetProtocolFailure.UNSUPPORTED_VERSION, "unsupported Rivet protocol version $version")
    }
    val rawType = reader.byte()
    val type = RivetMessageType.fromWire(rawType)
        ?: failure(RivetProtocolFailure.UNKNOWN_MESSAGE_TYPE, "unknown Rivet message type $rawType")
    val id = reader.uint64()
    val payload = reader.bytes(checkedLength(reader.uint32()))
    if (!reader.isAtEnd) failure(RivetProtocolFailure.TRAILING_BYTES, "trailing bytes after Rivet frame")
    return RivetFrame(type, id, payload)
}
