package dev.rivet.runtime

import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineName
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext

internal class RequestIDAllocator(seed: ULong = 1u) {
    private var nextID: ULong = if (seed == 0uL) 1u else seed

    fun allocate(occupiedCount: Int, isOccupied: (ULong) -> Boolean): ULong {
        require(occupiedCount >= 0)
        repeat(occupiedCount + 1) {
            val candidate = nextID
            nextID = if (nextID == ULong.MAX_VALUE) 1u else nextID + 1u
            if (!isOccupied(candidate)) return candidate
        }
        error("Rivet request id allocator invariant violated")
    }
}

private class RequestCancellationState {
    private val lock = ReentrantLock()
    private var requestID: ULong? = null
    private var cancelled = false
    private var requestSent = false
    private var cancelSent = false

    fun register(id: ULong): Boolean = lock.withLock {
        check(requestID == null)
        requestID = id
        cancelled
    }

    fun markRequestSent(): ULong? = lock.withLock {
        check(requestID != null)
        requestSent = true
        if (cancelled && !cancelSent) {
            cancelSent = true
            requestID
        } else {
            null
        }
    }

    fun cancel(): ULong? = lock.withLock {
        cancelled = true
        if (requestSent && !cancelSent) {
            cancelSent = true
            requestID
        } else {
            null
        }
    }
}

private enum class ClientPhase {
    CREATED,
    STARTING,
    RUNNING,
    STOPPED,
}

enum class RivetClientFailure {
    ALREADY_STARTED,
    NOT_RUNNING,
    STOPPED,
    UNEXPECTED_EOF,
    INVALID_HELLO,
    DUPLICATE_HELLO,
    UNEXPECTED_MESSAGE,
    BACKEND,
    TOO_MANY_PENDING_REQUESTS,
}

class RivetClientException(
    val failure: RivetClientFailure,
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause)

/**
 * Coroutine client for a single RVT1 transport.
 *
 * The client owns [input] and [output]. Calling [stop] sends Shutdown when the
 * handshake completed, fails outstanding calls, and closes both streams.
 * Event handlers run serially on the protocol reader coroutine and should
 * dispatch long-running or UI work elsewhere.
 */
class RivetClient(
    private val input: InputStream,
    private val output: OutputStream,
    private val maxPendingRequests: Int = 1024,
    dispatcher: CoroutineDispatcher = Dispatchers.IO,
) : AutoCloseable {
    init {
        require(maxPendingRequests > 0) { "Rivet native pending request limit must be positive" }
    }

    fun interface EventHandler {
        fun onEvent(name: String, value: RivetValue)
    }

    private class PendingRequest(
        val continuation: CancellableContinuation<RivetValue>,
    )

    private val stateLock = ReentrantLock()
    private val writeLock = ReentrantLock()
    private val transportDispatcher = dispatcher
    private val clientJob = SupervisorJob()
    private val scope = CoroutineScope(transportDispatcher + clientJob + CoroutineName("rivet-protocol"))
    private val requestIDs = RequestIDAllocator()
    private val pending = mutableMapOf<ULong, PendingRequest>()
    private var phase = ClientPhase.CREATED
    private var eventHandler: EventHandler? = null

    suspend fun start(onEvent: EventHandler? = null) {
        stateLock.withLock {
            if (phase != ClientPhase.CREATED) {
                clientFailure(RivetClientFailure.ALREADY_STARTED, "Rivet client instances cannot be restarted")
            }
            phase = ClientPhase.STARTING
        }

        try {
            val hello = withContext(transportDispatcher) { readFrame() }
            validateHello(hello)
            stateLock.withLock {
                if (phase != ClientPhase.STARTING) {
                    clientFailure(RivetClientFailure.STOPPED, "Rivet client stopped")
                }
                phase = ClientPhase.RUNNING
                eventHandler = onEvent
            }
        } catch (error: Throwable) {
            stateLock.withLock {
                if (phase == ClientPhase.STARTING) phase = ClientPhase.STOPPED
            }
            throw error
        }

        scope.launch { readLoop() }
    }

    suspend fun call(name: String, arguments: List<RivetValue> = emptyList()): RivetValue =
        suspendCancellableCoroutine { continuation ->
            val request = PendingRequest(continuation)
            val id = try {
                registerPending(request)
            } catch (error: Throwable) {
                continuation.resumeWith(Result.failure(error))
                return@suspendCancellableCoroutine
            }

            val cancellation = RequestCancellationState()
            cancellation.register(id)
            continuation.invokeOnCancellation {
                cancellation.cancel()?.let { cancelledID ->
                    scope.launch { cancelPending(cancelledID, request) }
                }
            }

            if (!continuation.isActive) {
                removePending(id, request)
                return@suspendCancellableCoroutine
            }

            val values = buildList {
                add(RivetValue.StringValue(name))
                addAll(arguments)
            }
            val frame = try {
                RivetFrame(RivetMessageType.REQUEST, id, encodeRivetValue(RivetValue.ListValue(values)))
            } catch (error: Throwable) {
                removePending(id, request)?.resumeWith(Result.failure(error))
                return@suspendCancellableCoroutine
            }

            scope.launch {
                try {
                    if (!writeRequest(frame, request)) return@launch
                    cancellation.markRequestSent()?.let { cancelPending(it, request) }
                } catch (error: Throwable) {
                    removePending(id, request)?.resumeWith(Result.failure(error))
                    finishWithError(error)
                }
            }
        }

    fun stop() {
        val continuations: List<CancellableContinuation<RivetValue>>
        writeLock.withLock {
            stateLock.withLock {
                val wasRunning = phase == ClientPhase.RUNNING
                phase = ClientPhase.STOPPED
                if (wasRunning) {
                    runCatching { writeEncoded(encodeRivetFrame(RivetFrame(RivetMessageType.SHUTDOWN, 0u))) }
                }
                continuations = pending.values.map { it.continuation }
                pending.clear()
            }
        }

        val stopped = RivetClientException(RivetClientFailure.STOPPED, "Rivet client stopped")
        continuations.forEach { it.resumeWith(Result.failure(stopped)) }
        closeTransport()
        scope.cancel()
    }

    override fun close() = stop()

    private fun registerPending(request: PendingRequest): ULong = stateLock.withLock {
        if (phase != ClientPhase.RUNNING) {
            clientFailure(RivetClientFailure.NOT_RUNNING, "Rivet client is not running")
        }
        if (pending.size >= maxPendingRequests) {
            clientFailure(
                RivetClientFailure.TOO_MANY_PENDING_REQUESTS,
                "too many native pending requests (limit $maxPendingRequests)",
            )
        }
        val id = requestIDs.allocate(pending.size) { pending.containsKey(it) }
        check(pending.put(id, request) == null)
        id
    }

    private fun writeRequest(frame: RivetFrame, request: PendingRequest): Boolean =
        writeLock.withLock {
            stateLock.withLock {
                if (phase != ClientPhase.RUNNING || pending[frame.id] !== request) return false
                writeEncoded(encodeRivetFrame(frame))
                true
            }
        }

    private fun cancelPending(id: ULong, request: PendingRequest) {
        var transportError: Throwable? = null
        writeLock.withLock {
            stateLock.withLock {
                if (phase != ClientPhase.RUNNING || pending[id] !== request) return
                try {
                    writeEncoded(encodeRivetFrame(RivetFrame(RivetMessageType.CANCEL, id)))
                } catch (error: Throwable) {
                    pending.remove(id)
                    transportError = error
                }
            }
        }
        transportError?.let(::finishWithError)
    }

    private fun writeEncoded(data: ByteArray) {
        output.write(data)
        output.flush()
    }

    private fun readFrame(): RivetFrame {
        val header = readExactly(18)
        val length = ByteBuffer.wrap(header, 14, Int.SIZE_BYTES)
            .order(ByteOrder.LITTLE_ENDIAN)
            .int
            .toLong() and 0xffff_ffffL
        if (length > RIVET_MAX_FRAME_PAYLOAD_SIZE) {
            throw RivetProtocolException(
                RivetProtocolFailure.LENGTH_OVERFLOW,
                "Rivet frame exceeds protocol length limit",
            )
        }
        return decodeRivetFrame(header + readExactly(length.toInt()))
    }

    private fun readExactly(count: Int): ByteArray {
        val result = ByteArray(count)
        var offset = 0
        while (offset < count) {
            val read = input.read(result, offset, count - offset)
            if (read < 0) {
                throw RivetClientException(
                    RivetClientFailure.UNEXPECTED_EOF,
                    "Rivet transport closed unexpectedly",
                    EOFException(),
                )
            }
            if (read == 0) continue
            offset += read
        }
        return result
    }

    private fun validateHello(frame: RivetFrame) {
        val value = runCatching { decodeRivetValue(frame.payload) }.getOrNull()
        val fields = (value as? RivetValue.ListValue)?.values
        val valid = frame.type == RivetMessageType.HELLO &&
            frame.id == 0uL &&
            fields?.size == 2 &&
            fields[0] == RivetValue.StringValue("rivet") &&
            fields[1] == RivetValue.Int64(RIVET_PROTOCOL_VERSION.toLong())
        if (!valid) {
            clientFailure(RivetClientFailure.INVALID_HELLO, "invalid Rivet Hello handshake")
        }
    }

    private fun readLoop() {
        try {
            while (isRunning()) {
                val frame = readFrame()
                when (frame.type) {
                    RivetMessageType.RESPONSE -> {
                        val value = decodeRivetValue(frame.payload)
                        takePending(frame.id)?.resumeWith(Result.success(value))
                    }
                    RivetMessageType.ERROR -> {
                        val value = decodeRivetValue(frame.payload)
                        val message = (value as? RivetValue.StringValue)?.value ?: "Rivet backend error"
                        takePending(frame.id)?.resumeWith(
                            Result.failure(RivetClientException(RivetClientFailure.BACKEND, message)),
                        )
                    }
                    RivetMessageType.EVENT -> deliverEvent(frame)
                    RivetMessageType.HELLO -> clientFailure(
                        RivetClientFailure.DUPLICATE_HELLO,
                        "duplicate Rivet Hello frame",
                    )
                    else -> clientFailure(
                        RivetClientFailure.UNEXPECTED_MESSAGE,
                        "unexpected Rivet message: ${frame.type}",
                    )
                }
            }
        } catch (error: Throwable) {
            if (isRunning()) finishWithError(error)
        }
    }

    private fun deliverEvent(frame: RivetFrame) {
        val fields = runCatching { decodeRivetValue(frame.payload) }
            .getOrNull()
            ?.let { it as? RivetValue.ListValue }
            ?.values
            ?: return
        if (fields.size != 2) return
        val name = (fields[0] as? RivetValue.StringValue)?.value ?: return
        val handler = stateLock.withLock { eventHandler }
        handler?.onEvent(name, fields[1])
    }

    private fun takePending(id: ULong): CancellableContinuation<RivetValue>? =
        stateLock.withLock { pending.remove(id)?.continuation }

    private fun removePending(
        id: ULong,
        request: PendingRequest,
    ): CancellableContinuation<RivetValue>? = stateLock.withLock {
        if (pending[id] !== request) return null
        pending.remove(id)?.continuation
    }

    private fun isRunning(): Boolean = stateLock.withLock { phase == ClientPhase.RUNNING }

    private fun finishWithError(error: Throwable) {
        val continuations = stateLock.withLock {
            if (phase == ClientPhase.STOPPED) return
            phase = ClientPhase.STOPPED
            pending.values.map { it.continuation }.also { pending.clear() }
        }
        continuations.forEach { it.resumeWith(Result.failure(error)) }
        closeTransport()
        scope.cancel()
    }

    private fun closeTransport() {
        runCatching { input.close() }
        runCatching { output.close() }
    }
}

private fun clientFailure(failure: RivetClientFailure, message: String): Nothing =
    throw RivetClientException(failure, message)
