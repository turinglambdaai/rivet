package dev.rivet.session

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.Executor
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertSame
import kotlin.test.assertTrue

class SelectedDeviceCompanionCoordinatorTest {
    private val advertisementID = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"
    private val id = SessionUuid(ByteArray(16) { it.toByte() })
    private val nonce = ByteArray(SESSION_NONCE_SIZE) { 0x22 }
    private val pin = ByteArray(SESSION_FINGERPRINT_SIZE) { 0x55 }

    private class Harness {
        lateinit var discovery: (String, ByteArray?, Boolean) -> Unit
        var resolved: ((DeviceResolvedService?) -> Unit)? = null
        var resolutionCount = 0
        val browser = DeviceDiscoveryBrowser(object : DeviceDiscoveryDriver {
            override fun start(onResult: (String, ByteArray?, Boolean) -> Unit) { discovery = onResult }
            override fun stop() {}
        }) { _, _ -> }

        val driver = DeviceServiceResolutionDriver { _, result ->
            resolutionCount++
            resolved = result
        }

        fun select(advertisementID: String, pairing: Boolean): DeviceDiscovery {
            browser.start()
            discovery("Device A", encodeDiscoveryTXT(DeviceAdvertisement(advertisementID, pairing)), false)
            return browser.snapshot.single()
        }

        fun reply(selected: DeviceDiscovery) {
            resolved!!(
                DeviceResolvedService(
                    selected.serviceName, "192.0.2.1", 12345,
                    encodeDiscoveryTXT(DeviceAdvertisement(selected.advertisementID, selected.pairingWindowOpen)),
                ),
            )
        }
    }

    private fun intent(): DeviceCompanionIntent = DeviceCompanionIntent.Reconnect(
        "com.example.app", id, ByteArray(SESSION_CREDENTIAL_SIZE) { 0x33 }, pin,
    )

    @Test
    fun selectedReconnectHandsOffOnlyAfterAuthenticationAndNoDuplicateDial() {
        val h = Harness()
        val selected = h.select(advertisementID, false)
        val sessionID = SessionUuid(ByteArray(16) { 0x44 })
        val incoming = ByteArrayInputStream(
            encodeSessionRecord(SessionMessage.AuthChallenge(nonce)) +
                encodeSessionRecord(SessionMessage.Accept(sessionID, listOf("reader"), 512L * 1024, 64)),
        )
        val outgoing = ByteArrayOutputStream()
        var dials = 0
        var handed = 0
        val decisions = mutableListOf<Result<SessionAcceptance>>()
        val coordinator = SelectedDeviceCompanionCoordinator(
            h.browser, h.driver, Executor { it.run() },
            onAccepted = { acceptance, input, output ->
                handed++
                assertEquals(sessionID, acceptance.sessionID)
                assertSame(incoming, input)
                assertSame(outgoing, output)
            },
            dialer = DeviceCompanionDialer { _, authentication ->
                dials++
                assertTrue(authentication is DeviceServerAuthentication.Pinned)
                object : DeviceCompanionTransport {
                    override val serverFingerprint get() = pin.copyOf()
                    override val input: InputStream get() = incoming
                    override val output: OutputStream get() = outgoing
                    override fun close() { incoming.close(); outgoing.close() }
                }
            },
        )
        coordinator.connectSelected(selected, intent()) { decisions += it }
        h.reply(selected)
        h.reply(selected)
        assertEquals(1, dials)
        assertEquals(1, handed)
        assertEquals(1, decisions.size)
        assertEquals(sessionID, decisions.single().getOrThrow().sessionID)
        assertFailsWith<IllegalStateException> {
            coordinator.connectSelected(selected, intent()) { }
        }
        coordinator.close()
        assertEquals(1, decisions.size)
        h.browser.stop()
    }

    @Test
    fun pairingRequiresAdvertisedOpenWindowAndCannotDialSilently() {
        val h = Harness()
        val selected = h.select(advertisementID, false)
        var dialed = false
        val results = mutableListOf<Result<SessionAcceptance>>()
        val coordinator = SelectedDeviceCompanionCoordinator(
            h.browser, h.driver, Executor { it.run() },
            onAccepted = { _, _, _ -> },
            dialer = DeviceCompanionDialer { _, _ ->
                dialed = true
                error("must not connect")
            },
        )
        coordinator.connectSelected(
            selected,
            DeviceCompanionIntent.Pair("com.example.app", id, "Android"),
        ) { results += it }
        assertEquals(0, h.resolutionCount)
        val failure = results.single().exceptionOrNull() as DeviceSelectionException
        assertEquals(DeviceSelectionFailure.PAIRING_WINDOW_CLOSED, failure.failure)
        assertFalse(dialed)
        coordinator.close()
    }

    @Test
    fun staleResolutionCannotDialAndCallbacksRemainSingleShot() {
        val h = Harness()
        val selected = h.select(advertisementID, true)
        var dialed = false
        val results = mutableListOf<Result<SessionAcceptance>>()
        val coordinator = SelectedDeviceCompanionCoordinator(
            h.browser, h.driver, Executor { it.run() },
            onAccepted = { _, _, _ -> },
            dialer = DeviceCompanionDialer { _, _ ->
                dialed = true
                error("must not connect")
            },
        )
        coordinator.connectSelected(selected, intent()) { results += it }
        h.discovery(selected.serviceName, null, true)
        h.reply(selected)
        h.reply(selected)
        assertEquals(1, results.size)
        assertEquals(
            DeviceSelectionFailure.STALE_SELECTION,
            (results.single().exceptionOrNull() as DeviceSelectionException).failure,
        )
        assertFalse(dialed)
        coordinator.close()
    }

    @Test
    fun queuedDialCannotRunAfterCloseAndCancellationOnlyReportsOnce() {
        val h = Harness()
        val selected = h.select(advertisementID, true)
        val pending = mutableListOf<Runnable>()
        var dialed = false
        val results = mutableListOf<Result<SessionAcceptance>>()
        val coordinator = SelectedDeviceCompanionCoordinator(
            h.browser, h.driver, Executor { pending += it },
            onAccepted = { _, _, _ -> },
            dialer = DeviceCompanionDialer { _, _ ->
                dialed = true
                error("must not connect")
            },
        )
        coordinator.connectSelected(selected, intent()) { results += it }
        h.reply(selected)
        assertEquals(1, pending.size)
        coordinator.close()
        coordinator.close()
        pending.single().run()
        assertEquals(1, results.size)
        assertEquals(
            DeviceSelectionFailure.CANCELLED,
            (results.single().exceptionOrNull() as DeviceSelectionException).failure,
        )
        assertFalse(dialed)
        h.browser.stop()
    }

    @Test
    fun missingSelectionDoesNotResolveOrDial() {
        val h = Harness()
        val selection = DeviceDiscovery("Not listed", advertisementID, true)
        val results = mutableListOf<Result<SessionAcceptance>>()
        val coordinator = SelectedDeviceCompanionCoordinator(
            h.browser, h.driver, Executor { it.run() },
            onAccepted = { _, _, _ -> },
        )
        coordinator.connectSelected(selection, intent()) { results += it }
        assertEquals(0, h.resolutionCount)
        assertEquals(
            DeviceSelectionFailure.STALE_SELECTION,
            (results.single().exceptionOrNull() as DeviceSelectionException).failure,
        )
        coordinator.close()
    }
}
