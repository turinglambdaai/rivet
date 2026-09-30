# Typed device communication

Rivet separates two boundaries that solve different problems:

- **RVT1** connects a native UI process to its in-process Racket backend.
- **RivetDevice** connects separate devices or processes through a transport such as WatchConnectivity.

Keeping these layers separate lets an iPhone or iPad embed Racket CS while an Apple Watch remains a lightweight companion. It also leaves room for a future independently embedded watch runtime without making that the default or coupling WatchConnectivity details to RVT1.

A phone can also be a client of a desktop-hosted backend. That direction needs a long-lived authenticated session, Events, State, discovery, pairing, and an explicit API allowlist rather than the request/reply semantics below. It is specified in the [network device channel design](network-device-channel.md); the design is not yet a shipped transport.

## Typed requests

Define a request and its response with normal `Codable` Swift types:

```swift
import RivetDevice

struct CurrentScore: RivetDeviceRequest {
    static let route = "score.current"
    typealias Response = Score

    let gameID: String
}

struct Score: Codable, Sendable {
    let home: Int
    let away: Int
}
```

The phone registers the handler:

```swift
let router = RivetDeviceRouter()
try await router.register(CurrentScore.self) { request in
    try await scores.current(gameID: request.gameID)
}
```

The watch receives the declared response type without stringly typed casts:

```swift
import RivetWatchConnectivity

let transport = RivetWatchConnectivityTransport()
try transport.activate()
let client = RivetDeviceClient(transport: transport)
let score = try await client.send(CurrentScore(gameID: "final"))
```

`RivetDeviceRouter` rejects duplicate/invalid routes, bounds request and response sizes, validates protocol version and correlation IDs, and converts registered remote errors into stable code/message pairs. `RivetWatchConnectivityTransport` adapts this contract to `WCSession.sendMessageData`; the typed channel itself is transport-neutral and testable with an in-memory transport.

This design follows the core idea in [DSLs for Safe iOS/watchOS Communication](https://defn.io/2025/02/16/type-safe-watchos-communication/): encode the request/response relationship in types and centralize dispatch instead of spreading dictionaries, route strings, and casts throughout both apps. Rivet's next layer will generate these declarations and handler registration from the shared project schema.

## Platform boundary

The Swift package declares macOS 14, iOS/iPadOS 16, and watchOS 9 as its current baselines. `RivetRuntime` and `RivetDevice` are portable Apple targets. `RivetEmbedding` is the Racket CS embedding layer; bringing it to iPhone/iPad requires the portable-bytecode static runtime and boot artifacts. `RivetSystem` remains the macOS system-services adapter.
