package dev.rivet.session

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class DiscoveryTest {
    private val advertisementID = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"

    @Test
    fun roundTripAndCanonicality() {
        val record = encodeDiscoveryTXT(DeviceAdvertisement(advertisementID, true))
        val expected = "id=$advertisementID\u0000pair=1\u0000v=1"
            .split("\u0000")
            .flatMap { listOf(it.length.toByte()) + it.encodeToByteArray().toList() }
            .toByteArray()
        assertEquals(expected.toList(), record.toList())

        val decoded = decodeDiscoveryTXT(record)
        assertEquals(DeviceAdvertisement(advertisementID, true), decoded)
        assertTrue(decoded.pairingWindowOpen)
    }

    @Test
    fun nonCanonicalRecordsAreRejected() {
        // Hand-build a reordered variant that decodes to the same values.
        val entry = { text: String -> byteArrayOf(text.length.toByte()) + text.encodeToByteArray() }
        val reorderedRecord = entry("pair=1") + entry("v=1") + entry("id=$advertisementID")

        assertFailsWith<SessionProtocolException> { decodeDiscoveryTXT(reorderedRecord) }
        assertFailsWith<SessionProtocolException> { decodeDiscoveryTXT(ByteArray(0)) }
        assertFailsWith<SessionProtocolException> {
            decodeDiscoveryTXT(ByteArray(DEVICE_DISCOVERY_MAXIMUM_TXT_RECORD_SIZE + 1))
        }
        assertFailsWith<SessionProtocolException> {
            decodeDiscoveryTXT(entry("id=$advertisementID") + entry("pair=2") + entry("v=1"))
        }
        assertFailsWith<SessionProtocolException> {
            decodeDiscoveryTXT(entry("id=$advertisementID") + entry("pair=1") + entry("v=2"))
        }
        assertFailsWith<SessionProtocolException> {
            DeviceAdvertisement("short", true)
        }
    }

    @Test
    fun browserTracksCanonicalCandidatesAndRemovals() {
        val record = encodeDiscoveryTXT(DeviceAdvertisement(advertisementID, true))
        val removedRecord: ByteArray? = null
        var callback: ((String, ByteArray?, Boolean) -> Unit)? = null
        val driver = object : DeviceDiscoveryDriver {
            override fun start(onResult: (String, ByteArray?, Boolean) -> Unit) {
                callback = onResult
            }

            override fun stop() {}
        }

        val events = mutableListOf<Pair<DeviceDiscoveryEventKind, String>>()
        val browser = DeviceDiscoveryBrowser(driver) { kind, discovery ->
            events += kind to discovery.advertisementID
        }
        browser.start()
        callback!!.invoke("Rivet-a", record, false)
        callback!!.invoke("Rivet-b", record, false)
        assertEquals(2, browser.snapshot.size)

        // A vanished result is removed; a noncanonical record never becomes
        // a candidate.
        callback!!.invoke("Rivet-a", removedRecord, true)
        callback!!.invoke("Rivet-c", byteArrayOf(0x00, 0x01, 0x02), false)
        assertEquals(1, browser.snapshot.size)
        assertEquals(
            listOf(
                DeviceDiscoveryEventKind.ADDED to advertisementID,
                DeviceDiscoveryEventKind.ADDED to advertisementID,
                DeviceDiscoveryEventKind.REMOVED to advertisementID,
            ),
            events,
        )

        browser.stop()
        assertTrue(browser.snapshot.isEmpty())
        // Repeated stops are idempotent.
        browser.stop()
    }

    @Test
    fun staleCallbacksCannotMutateRestartedDiscovery() {
        val callbacks = mutableListOf<(String, ByteArray?, Boolean) -> Unit>()
        val driver = object : DeviceDiscoveryDriver {
            override fun start(onResult: (String, ByteArray?, Boolean) -> Unit) {
                callbacks += onResult
            }

            override fun stop() {}
        }
        val events = mutableListOf<Pair<DeviceDiscoveryEventKind, String>>()
        val browser = DeviceDiscoveryBrowser(driver) { kind, discovery ->
            events += kind to discovery.advertisementID
        }
        val prior = encodeDiscoveryTXT(DeviceAdvertisement(advertisementID, true))
        val currentID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        val current = encodeDiscoveryTXT(DeviceAdvertisement(currentID, false))

        browser.start()
        val oldCallback = callbacks.single()
        oldCallback("prior-host", prior, false)
        browser.stop()
        browser.start()
        val currentCallback = callbacks.last()
        currentCallback("current-host", current, false)
        val eventsBeforeStaleCallbacks = events.toList()

        // Both callbacks were queued by the stopped session. Even when their
        // service names collide with current candidates, they must do nothing.
        oldCallback("current-host", null, true)
        oldCallback("stale-host", prior, false)
        assertEquals(listOf(DeviceDiscovery("current-host", currentID, false)), browser.snapshot)
        assertEquals(eventsBeforeStaleCallbacks, events)

        // The newly registered callback still has authority to update state.
        currentCallback("current-host", null, true)
        assertTrue(browser.snapshot.isEmpty())
        assertEquals(DeviceDiscoveryEventKind.REMOVED to currentID, events.last())
        browser.stop()
    }
}
