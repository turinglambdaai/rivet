package dev.rivet.runtime

import java.io.InputStream
import java.io.OutputStream
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

private class ClientHarness(maxPendingRequests: Int = 1024) : AutoCloseable {
    private val backendToClient = PipedOutputStream()
    private val clientInput = PipedInputStream(backendToClient, 1024 * 1024)
    private val clientToBackend = PipedOutputStream()
    val backendInput = PipedInputStream(clientToBackend, 1024 * 1024)
    val backendOutput: OutputStream = backendToClient
    val client = RivetClient(clientInput, clientToBackend, maxPendingRequests)

    suspend fun start(onEvent: RivetClient.EventHandler? = null) {
        backendOutput.writeFrame(
            RivetFrame(
                RivetMessageType.HELLO,
                0u,
                encodeRivetValue(
                    RivetValue.ListValue(
                        listOf(
                            RivetValue.StringValue("rivet"),
                            RivetValue.Int64(RIVET_PROTOCOL_VERSION.toLong()),
                        ),
                    ),
                ),
            ),
        )
        client.start(onEvent)
    }

    override fun close() {
        client.stop()
        runCatching { backendInput.close() }
        runCatching { backendOutput.close() }
    }
}

class ClientTest {
    @Test
    fun requestResponseErrorEventAndStateFlow() = runBlocking {
        val event = CompletableDeferred<Pair<String, RivetValue>>()
        ClientHarness().use { harness ->
            harness.start { name, value -> event.complete(name to value) }

            val call = async { harness.client.call("add", listOf(RivetValue.Int64(2))) }
            val request = withContext(Dispatchers.IO) { harness.backendInput.readFrame() }
            assertEquals(RivetMessageType.REQUEST, request.type)
            assertEquals("add", request.requestName())
            harness.backendOutput.writeFrame(
                RivetFrame(
                    RivetMessageType.RESPONSE,
                    request.id,
                    encodeRivetValue(RivetValue.Int64(3)),
                ),
            )
            assertEquals(RivetValue.Int64(3), withTimeout(2_000) { call.await() })

            harness.backendOutput.writeFrame(
                RivetFrame(
                    RivetMessageType.EVENT,
                    1u,
                    encodeRivetValue(
                        RivetValue.ListValue(
                            listOf(RivetValue.StringValue("progress"), RivetValue.Int64(50)),
                        ),
                    ),
                ),
            )
            assertEquals("progress" to RivetValue.Int64(50), withTimeout(2_000) { event.await() })

            val state = async { harness.client.getState("count") }
            val stateRequest = withContext(Dispatchers.IO) { harness.backendInput.readFrame() }
            assertEquals("\$state/get", stateRequest.requestName())
            assertEquals(
                listOf(RivetValue.StringValue("\$state/get"), RivetValue.StringValue("count")),
                (decodeRivetValue(stateRequest.payload) as RivetValue.ListValue).values,
            )
            harness.backendOutput.writeFrame(
                RivetFrame(
                    RivetMessageType.RESPONSE,
                    stateRequest.id,
                    encodeRivetValue(RivetValue.Int64(4)),
                ),
            )
            assertEquals(RivetValue.Int64(4), withTimeout(2_000) { state.await() })

            supervisorScope {
                val failed = async { harness.client.call("fail") }
                val failedRequest = withContext(Dispatchers.IO) { harness.backendInput.readFrame() }
                harness.backendOutput.writeFrame(
                    RivetFrame(
                        RivetMessageType.ERROR,
                        failedRequest.id,
                        encodeRivetValue(RivetValue.StringValue("backend said no")),
                    ),
                )
                val error = assertFailsWith<RivetClientException> { failed.await() }
                assertEquals(RivetClientFailure.BACKEND, error.failure)
                assertEquals("backend said no", error.message)
            }

            assertEquals(
                RivetStateChange("count", RivetValue.Int64(4)),
                stateChange(
                    "\$state",
                    RivetValue.ListValue(
                        listOf(RivetValue.StringValue("count"), RivetValue.Int64(4)),
                    ),
                ),
            )
        }
    }

    @Test
    fun coroutineCancellationSendsCancelAfterRequest(): Unit = runBlocking {
        ClientHarness(maxPendingRequests = 1).use { harness ->
            val terminalDrained = CompletableDeferred<Unit>()
            harness.start { name, _ -> if (name == "terminal-drained") terminalDrained.complete(Unit) }
            val call = async { harness.client.call("slow") }
            val request = withContext(Dispatchers.IO) { harness.backendInput.readFrame() }

            call.cancel()
            val cancel = withTimeout(2_000) {
                withContext(Dispatchers.IO) { harness.backendInput.readFrame() }
            }
            assertEquals(RivetMessageType.CANCEL, cancel.type)
            assertEquals(request.id, cancel.id)
            assertTrue(cancel.payload.isEmpty())
            assertFailsWith<CancellationException> { call.await() }

            val stillOwned = assertFailsWith<RivetClientException> { harness.client.call("too-early") }
            assertEquals(RivetClientFailure.TOO_MANY_PENDING_REQUESTS, stillOwned.failure)

            harness.backendOutput.writeFrame(
                RivetFrame(
                    RivetMessageType.ERROR,
                    request.id,
                    encodeRivetValue(RivetValue.StringValue("request cancelled")),
                ),
            )
            harness.backendOutput.writeFrame(
                RivetFrame(
                    RivetMessageType.EVENT,
                    2u,
                    encodeRivetValue(
                        RivetValue.ListValue(
                            listOf(RivetValue.StringValue("terminal-drained"), RivetValue.Null),
                        ),
                    ),
                ),
            )
            withTimeout(2_000) { terminalDrained.await() }

            val next = async { harness.client.call("after-cancel-terminal") }
            val nextRequest = withContext(Dispatchers.IO) { harness.backendInput.readFrame() }
            harness.backendOutput.writeFrame(
                RivetFrame(
                    RivetMessageType.RESPONSE,
                    nextRequest.id,
                    encodeRivetValue(RivetValue.Int64(9)),
                ),
            )
            assertEquals(RivetValue.Int64(9), withTimeout(2_000) { next.await() })
        }
    }

    @Test
    fun pendingLimitRejectsBeforeWritingAndReleasesAfterResponse() = runBlocking {
        ClientHarness(maxPendingRequests = 1).use { harness ->
            harness.start()
            val first = async { harness.client.call("first") }
            val firstRequest = withContext(Dispatchers.IO) { harness.backendInput.readFrame() }

            val error = assertFailsWith<RivetClientException> { harness.client.call("rejected") }
            assertEquals(RivetClientFailure.TOO_MANY_PENDING_REQUESTS, error.failure)

            harness.backendOutput.writeFrame(
                RivetFrame(
                    RivetMessageType.RESPONSE,
                    firstRequest.id,
                    encodeRivetValue(RivetValue.Int64(1)),
                ),
            )
            assertEquals(RivetValue.Int64(1), withTimeout(2_000) { first.await() })

            val next = async { harness.client.call("next") }
            val nextRequest = withContext(Dispatchers.IO) { harness.backendInput.readFrame() }
            assertEquals("next", nextRequest.requestName())
            harness.backendOutput.writeFrame(
                RivetFrame(
                    RivetMessageType.RESPONSE,
                    nextRequest.id,
                    encodeRivetValue(RivetValue.Int64(2)),
                ),
            )
            assertEquals(RivetValue.Int64(2), withTimeout(2_000) { next.await() })
        }
    }

    @Test
    fun invalidHelloIsTerminalAndRestartIsRejected() = runBlocking {
        val backendOutput = PipedOutputStream()
        val clientInput = PipedInputStream(backendOutput)
        val clientOutput = PipedOutputStream()
        val backendInput = PipedInputStream(clientOutput)
        val client = RivetClient(clientInput, clientOutput)
        try {
            backendOutput.writeFrame(RivetFrame(RivetMessageType.HELLO, 0u, encodeRivetValue(RivetValue.Null)))
            val invalid = assertFailsWith<RivetClientException> { client.start() }
            assertEquals(RivetClientFailure.INVALID_HELLO, invalid.failure)
            val restarted = assertFailsWith<RivetClientException> { client.start() }
            assertEquals(RivetClientFailure.ALREADY_STARTED, restarted.failure)
        } finally {
            client.stop()
            runCatching { backendInput.close() }
            runCatching { backendOutput.close() }
        }
    }

    @Test
    fun requestIdentifiersWrapWithoutZeroAndSkipOccupiedValues() {
        val allocator = RequestIDAllocator(ULong.MAX_VALUE)
        assertEquals(ULong.MAX_VALUE, allocator.allocate(0) { false })
        assertEquals(1uL, allocator.allocate(0) { false })

        val colliding = RequestIDAllocator(ULong.MAX_VALUE)
        val occupied = setOf(ULong.MAX_VALUE, 1uL, 2uL)
        assertEquals(3uL, colliding.allocate(occupied.size) { it in occupied })
    }

    @Test
    fun stopWritesShutdownAndRejectsFurtherCalls(): Unit = runBlocking {
        ClientHarness().use { harness ->
            harness.start()
            harness.client.stop()
            val shutdown = withContext(Dispatchers.IO) { harness.backendInput.readFrame() }
            assertEquals(RivetMessageType.SHUTDOWN, shutdown.type)
            assertEquals(0uL, shutdown.id)

            val error = assertFailsWith<RivetClientException> { harness.client.call("after-stop") }
            assertEquals(RivetClientFailure.NOT_RUNNING, error.failure)
        }
    }
}

private fun OutputStream.writeFrame(frame: RivetFrame) {
    write(encodeRivetFrame(frame))
    flush()
}

private fun InputStream.readFrame(): RivetFrame {
    val header = readExactly(18)
    val length = ByteBuffer.wrap(header, 14, Int.SIZE_BYTES)
        .order(ByteOrder.LITTLE_ENDIAN)
        .int
        .toLong() and 0xffff_ffffL
    return decodeRivetFrame(header + readExactly(length.toInt()))
}

private fun InputStream.readExactly(count: Int): ByteArray {
    val result = ByteArray(count)
    var offset = 0
    while (offset < count) {
        val read = read(result, offset, count - offset)
        check(read > 0) { "unexpected EOF" }
        offset += read
    }
    return result
}

private fun RivetFrame.requestName(): String {
    assertEquals(RivetMessageType.REQUEST, type)
    val fields = (decodeRivetValue(payload) as RivetValue.ListValue).values
    return (fields.first() as RivetValue.StringValue).value
}
