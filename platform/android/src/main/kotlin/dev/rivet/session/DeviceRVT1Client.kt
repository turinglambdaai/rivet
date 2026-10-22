package dev.rivet.session

import dev.rivet.runtime.RivetClient
import java.io.InputStream
import java.io.OutputStream
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers

/**
 * Build the RVT1 client only after RVD1 has returned an authenticated
 * [SessionAcceptance]. The caller must start the client, register only
 * product-allowed APIs, and close both the client and companion session.
 *
 * Never turn an mDNS advertisement, a TLS connection alone, or a pairing
 * prompt into an RVT1 client. The remote gateway remains authoritative
 * for RPC and State scope enforcement.
 */
fun createDeviceRVT1Client(
    acceptance: SessionAcceptance,
    input: InputStream,
    output: OutputStream,
    dispatcher: CoroutineDispatcher = Dispatchers.IO,
): RivetClient {
    require(acceptance.maximumPayload in 1..SESSION_DEFAULT_MAXIMUM_PAYLOAD) {
        "invalid authenticated device payload budget"
    }
    require(acceptance.maximumPending in 1..SESSION_DEFAULT_MAXIMUM_PENDING.toLong()) {
        "invalid authenticated device pending-request budget"
    }
    return RivetClient(
        input = input,
        output = output,
        maxPendingRequests = acceptance.maximumPending.toInt(),
        dispatcher = dispatcher,
        maxFramePayloadSize = acceptance.maximumPayload.toInt(),
    )
}
