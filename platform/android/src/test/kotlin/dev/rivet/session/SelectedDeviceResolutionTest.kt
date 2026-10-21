package dev.rivet.session

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SelectedDeviceResolutionTest {
    private val advertisementID = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"

    private class Harness {
        val discovered = mutableMapOf<String, (String, ByteArray?, Boolean) -> Unit>()
        var nativeCallback: ((DeviceResolvedService?) -> Unit)? = null
        val browser = DeviceDiscoveryBrowser(object : DeviceDiscoveryDriver {
            override fun start(onResult: (String, ByteArray?, Boolean) -> Unit) {
                discovered["callback"] = onResult
            }
            override fun stop() {}
        }) { _, _ -> }
        var resolutionCalls = 0
        val resolver = SelectedDeviceResolver(
            browser,
            DeviceServiceResolutionDriver { _, callback ->
                resolutionCalls++
                nativeCallback = callback
            },
        )

        fun start(serviceName: String, advertisedID: String, pairing: Boolean): DeviceDiscovery {
            browser.start()
            val advertisement = DeviceAdvertisement(advertisedID, pairing)
            discovered.getValue("callback")(serviceName, encodeDiscoveryTXT(advertisement), false)
            return browser.snapshot.single { it.serviceName == serviceName }
        }

        fun result(
            selected: DeviceDiscovery,
            host: String = "192.0.2.1",
            port: Int = 12345,
            txt: ByteArray? = encodeDiscoveryTXT(
                DeviceAdvertisement(selected.advertisementID, selected.pairingWindowOpen),
            ),
        ) = DeviceResolvedService(selected.serviceName, host, port, txt)
    }

    @Test
    fun explicitlySelectedCanonicalResultProducesEndpoint() {
        val h = Harness()
        val selected = h.start("Rivet-a", advertisementID, false)
        val answers = mutableListOf<DeviceResolvedEndpoint?>()
        h.resolver.resolveSelected(selected) { answers.add(it) }
        assertEquals(1, h.resolutionCalls)
        val callback = h.nativeCallback!!
        callback(h.result(selected))
        callback(h.result(selected, port = 54321))
        assertEquals(
            listOf(DeviceResolvedEndpoint("192.0.2.1", 12345, advertisementID, false)),
            answers,
        )
        h.browser.stop()
    }

    @Test
    fun staleResolutionCannotCompleteAfterCancellationOrReselection() {
        val h = Harness()
        val a = h.start("Rivet-a", advertisementID, true)
        val b = h.start("Rivet-b", "00112233445566778899aabbccddeeff", true)
        val responses = mutableListOf<DeviceResolvedEndpoint?>()
        h.resolver.resolveSelected(a) { responses += it }
        val old = h.nativeCallback!!
        h.resolver.resolveSelected(b) { responses += it }
        val current = h.nativeCallback!!
        old(h.result(a))
        assertTrue(responses.isEmpty())
        current(h.result(b))
        assertEquals(b.advertisementID, responses.single()?.advertisementID)

        h.resolver.resolveSelected(a) { responses += it }
        val cancelled = h.nativeCallback!!
        h.resolver.cancel()
        cancelled(h.result(a))
        assertEquals(1, responses.size)
        h.browser.stop()
    }

    @Test
    fun disappearedOrChangedCandidateIsRejected() {
        val h = Harness()
        val selection = h.start("Rivet-a", advertisementID, true)
        val responses = mutableListOf<DeviceResolvedEndpoint?>()
        h.resolver.resolveSelected(selection) { responses += it }
        h.discovered.getValue("callback")(
            "Rivet-a", encodeDiscoveryTXT(DeviceAdvertisement(advertisementID, false)), false,
        )
        h.nativeCallback!!(h.result(selection))
        assertEquals(1, responses.size)
        assertNull(responses.single())
        h.browser.stop()
    }

    @Test
    fun malformedTxtAndMismatchedServiceCannotResolve() {
        val h = Harness()
        val selection = h.start("Rivet-a", advertisementID, false)
        val failed = mutableListOf<DeviceResolvedEndpoint?>()
        val cases = listOf(
            h.result(selection, host = ""),
            h.result(selection, port = 0),
            h.result(selection, txt = byteArrayOf(1, 2, 3)),
            h.result(selection, txt = null),
            h.result(selection).copy(serviceName = "Rivet-b"),
            h.result(
                selection, txt = encodeDiscoveryTXT(
                    DeviceAdvertisement("00112233445566778899aabbccddeeff", false),
                ),
            ),
        )
        for (case in cases) {
            h.resolver.resolveSelected(selection) { failed += it }
            h.nativeCallback!!(case)
        }
        assertEquals(cases.size, failed.size)
        assertTrue(failed.all { it == null })
        h.browser.stop()
    }

    @Test
    fun selectionMissingFromLiveBrowserDoesNotStartNativeResolution() {
        val h = Harness()
        val selection = DeviceDiscovery("Rivet-gone", advertisementID, true)
        val results = mutableListOf<DeviceResolvedEndpoint?>()
        h.resolver.resolveSelected(selection) { results += it }
        assertEquals(listOf(null), results)
        assertEquals(0, h.resolutionCalls)
    }
}
