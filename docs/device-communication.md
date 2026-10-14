# Typed device communication

Rivet separates two boundaries that solve different problems:

- **RVT1** connects a native UI process to its in-process Racket backend.
- **RivetDevice** connects separate devices or processes through a transport such as WatchConnectivity.

Keeping these layers separate lets an iPhone or iPad embed Racket CS while an Apple Watch remains a lightweight companion. It also leaves room for a future independently embedded watch runtime without making that the default or coupling WatchConnectivity details to RVT1.

A phone can also be a client of a desktop-hosted backend. That direction needs a long-lived authenticated session, Events, State, discovery, pairing, and an explicit API allowlist rather than the request/reply semantics below. It is specified in the [network device channel design](network-device-channel.md). Its in-memory authorization/session core is implemented, but it is not yet a shipped network transport.

## Generated companion API

Declare the backend RPC normally, then opt only the companion-safe subset into
`rivet.rktd`:

```racket
(device-rpcs . (current-score refresh-score))
```

`raco rivet generate` emits the request/response association, route, typed
`RivetDeviceClient` convenience methods, and phone-side handler registration
from that one schema. On the phone, connect `RivetAPI` to the embedded backend
and register the generated handlers:

```swift
import RivetDevice

let router = RivetDeviceRouter()
let api = RivetAPI(client: embeddedBackendClient)
try await router.registerGeneratedBackend(api)
```

The watch calls the same generated schema without route strings or casts:

```swift
import RivetWatchConnectivity

let transport = RivetWatchConnectivityTransport()
try transport.activate()
let client = RivetDeviceClient(transport: transport)
let score = try await client.current_score(game_id: "final")
```

The allowlist is empty by default. Missing RPC names fail generation. Selected
arguments and results must be representable by `Codable`: the primitive,
`List`, `Optional`, Record, and Enum schema types are supported, while `Any` is
rejected. A direct `Void` result is represented by an internal generated unit
response. Records and Enums reachable from selected RPCs gain `Codable`
conformance; unrelated desktop types do not acquire an unnecessary wire
contract. Removing an exported RPC is reported as a schema compatibility
break, while adding one is compatible.

Applications can still implement `RivetDeviceRequest` manually when a device
message intentionally has no backend RPC equivalent.

`RivetDeviceRouter` rejects duplicate/invalid routes, bounds request and response sizes, validates protocol version and correlation IDs, and converts registered remote errors into stable code/message pairs. `RivetWatchConnectivityTransport` adapts this contract to `WCSession.sendMessageData`; the typed channel itself is transport-neutral and testable with an in-memory transport.

## Desktop gateway policy core

`RivetDeviceGateway` is the transport-independent policy boundary for a future
desktop-hosted companion. Pairing supplies one or more `RivetDeviceScope`
values; an empty scope set grants nothing. Scopes independently grant RPCs,
Events, State reads, and State writes. Unknown and ungranted RPC/State names
produce the same `forbidden` result so a device cannot enumerate the private
desktop API.

Each `RivetDeviceGatewaySession` has its own remote request-ID namespace. It
maps admitted calls onto opaque IDs returned by `RivetDeviceGatewayHost`, and a
Cancel can affect only a mapping owned by that session. Disconnecting or
revoking a session cancels all of its pending host calls without closing the
embedded backend or another session. Event and State-change delivery is
filtered before fan-out; State-change visibility follows State-read access.

The defaults are 512 KiB per request/response/event payload, 64 pending calls
per session, and 8 authenticated sessions per gateway. These are defense-in-
depth limits for the future listener, not permission to expose this type
directly to untrusted bytes. TLS, RVT1 decoding, and outgoing queue backpressure
remain required outside the core.

## Pairing and reconnect core

`RivetDevicePairingCoordinator` implements the UI-independent pairing lifecycle:
a five-minute window, required 256-bit client nonce, fresh 256-bit server nonce,
one active attempt, a five-failure cutoff, explicit cancel, and a random 256-bit
per-device credential only after both peers confirm. `RivetDevicePairingTranscript`
defines a deterministic six-digit
confirmation code over the application ID, server SHA-256 fingerprint, and
both nonces so desktop and phone implementations can share golden vectors.

`RivetDevicePairingStore` is the persistence boundary. Its implementations must
put credentials in platform secure storage; listable `RivetDevicePairedDevice`
metadata contains no credential. `RivetDeviceSessionAuthenticator` deliberately
returns the same failure for an unknown device, wrong application, changed
server identity, or bad credential. Revocation removes the credential first and
then asks the gateway to close every session owned by that paired device.

These types do not create trust by themselves. A platform adapter must still
provide authenticated TLS, server-key pinning, Keychain/Credential Manager
storage, bounded preface decoding, and explicit native confirmation UI.

This design follows the core idea in [DSLs for Safe iOS/watchOS Communication](https://defn.io/2025/02/16/type-safe-watchos-communication/): encode the request/response relationship in types and centralize dispatch instead of spreading dictionaries, route strings, and casts throughout both apps. Rivet generates that relationship from the shared Racket schema while keeping the exported device surface explicit.

## Platform boundary

The Swift package declares macOS 14, iOS/iPadOS 16, and watchOS 9 as its current baselines. `RivetRuntime` and `RivetDevice` are portable Apple targets. `RivetEmbedding` is the Racket CS embedding layer; bringing it to iPhone/iPad requires the portable-bytecode static runtime and boot artifacts. `RivetSystem` remains the macOS system-services adapter.
