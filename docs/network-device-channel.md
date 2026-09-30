# Network device channel design

Status: design proposal for [issue #85](https://github.com/turinglambdaai/rivet/issues/85). No network listener, pairing flow, or generated mobile application is shipped yet.

## Problem

Rivet currently has two useful pieces that do not yet meet in the middle:

- desktop hosts run the Racket backend and expose its typed API to the first-party native UI over an in-process RVT1 connection;
- Swift and Kotlin have RVT1 codecs, clients, Events, State, cancellation, and generated types, while `RivetDevice` provides a bounded request/response abstraction for WatchConnectivity.

A desktop-companion application needs the opposite of the current watch arrangement. The desktop remains the only engine, while a phone on the same local network reads selected State and Events and invokes selected RPCs. The phone must not receive the entire desktop API merely because it can reach the process.

The first use case is a podcast companion that reads the current transcript and summary and controls play, seek, and playback speed. The design must remain useful for progress viewers, launchers, and other Rivet applications without introducing shared UI code.

## Decision

Add a **device gateway** beside the native desktop host. The gateway terminates an authenticated local-network session, parses RVT1 frames, enforces an application-declared device API and per-device scopes, and then invokes the existing embedded backend through the host's normal client API.

```text
 iOS SwiftUI / Android Compose
 generated device-only client
             |
       TLS 1.2+ + RVT1
             |
  native desktop device gateway
  auth + limits + policy + ID mapping
             |
 existing in-process backend client
             |
       Racket application
```

This is not a second Racket backend and it is not a public TCP socket attached to the embedded backend's ports. The gateway is an explicit trust boundary. It may reuse RVT1 framing and generated value types, but it never forwards unvalidated network bytes or grants network clients the desktop UI's authority.

The existing `RivetDevice` WatchConnectivity request/response API remains supported. A network session is a separate transport product because it has discovery, authentication, long-lived Events, cancellation, and State semantics that WatchConnectivity deliberately does not expose.

## Invariants

The implementation must preserve these boundaries:

1. Racket stays the application-logic owner. The device gateway contains transport and authorization policy, not product behavior.
2. Each UI remains first-party native: SwiftUI/UIKit on iOS, Jetpack Compose on Android, WinUI 3 on Windows, SwiftUI/AppKit on macOS, and GTK4 on Linux.
3. RVT1 v1 framing and generated schema types stay unchanged. Network-session negotiation is outside RVT1 and completes before the gateway emits the normal RVT1 Hello frame.
4. Network exposure is off by default. No listener or mDNS advertisement exists until the application opts in and the user enables companion access.
5. Discovery is never authentication. Every request is authorized after a paired session is authenticated.
6. The network surface is an explicit subset of the application schema. Server-side enforcement is authoritative even if a client bypasses generated code.
7. A remote Shutdown closes that device session only. It cannot stop the embedded backend or desktop application.

## Device API

`rivet.rktd` will declare named scopes over existing RPC, Event, and State declarations. The exact datum syntax is implementation work, but the model is:

```racket
(device-api
  (scope reader
    (rpcs get-episode current-transcript)
    (events playback-changed transcript-changed)
    (read-states playback current-episode))
  (scope controller
    (rpcs play pause seek set-playback-speed)
    (read-states playback current-episode)))
```

A scope may grant:

- RPC invocation by declared name;
- Event receipt by declared name;
- State read by declared name;
- State write by declared name.

State read and write are separate grants. Device clients never receive implicit access to every `$state/get`, `$state/set`, or `$state` Event. The gateway inspects the State name inside those reserved calls and Events before applying policy.

Configuration loading and code generation must fail when a device export names a missing declaration or grants State write to a non-State declaration. At pairing time the desktop assigns one or more scopes to a device; the default UI selects the least-privileged scope.

The existing schema snapshot gains the device surface and scope names. Removing an exported declaration or narrowing its type or access is a compatibility break; adding an export is compatible. Code generation emits a device-only Swift and Kotlin client containing the union of exported declarations. A generated method being present is a usability aid, not an authorization decision.

## Discovery and reachability

The desktop advertises `_rivet-device._tcp` with DNS-SD/mDNS only while companion access is enabled. The TXT record contains only bounded routing hints:

- device-session protocol version;
- an ephemeral advertisement identifier that rotates when the listener restarts;
- whether an explicit pairing window is open.

It does not contain credentials, API names, user content, filenames, or account identifiers. Service names are user-editable because even a product display name can be sensitive on a shared network.

The first release is local-network only. Rivet does not configure router port forwarding, UPnP, relay servers, or cloud rendezvous. A listener binds only to selected local interfaces and reacts to interface changes. VPN and enterprise-network policy are application/administrator decisions and must not be silently bypassed; source-address classification is not authentication.

## Pairing and trust

The gateway requires TLS 1.2 or newer with forward secrecy and an AEAD cipher. It prefers TLS 1.3 where the platform provides it; Windows 10 must be able to use its native TLS 1.2 ECDHE/AES-GCM suites rather than adding a bundled TLS stack solely for this feature. On first enablement the gateway creates a per-application-install server identity and stores its private material through the platform secure-storage adapter. A normal reconnect pins that identity and authenticates a per-device credential before RVT1 starts.

Pairing is an explicit foreground action:

1. The user opens the desktop's Devices UI and starts a five-minute pairing window.
2. The phone discovers the service. The preferred path scans a desktop QR code containing the service instance and server public-key fingerprint, so TLS is pinned before the first request.
3. A manual fallback connects with an untrusted provisional identity and shows the same short authentication string on both devices. The string is derived from the server-certificate fingerprint plus fresh client and server nonces exchanged on that connection. Both screens require confirmation; a man-in-the-middle presents a different server key and therefore produces different strings.
4. After confirmation, the desktop issues a random 256-bit per-device credential over the authenticated channel and records the device name, granted scopes, creation time, and last-used time. The phone stores the credential and server pin in Keychain/Keystore.
5. The pairing window closes after success, expiry, five failed attempts, or an explicit cancel.

The desktop can list and revoke devices. Revocation takes effect for new requests on existing sessions and closes them. Rotating the server identity revokes every pin and credential and therefore requires re-pairing. Logs contain device IDs and stable error codes, never credentials, transcript contents, or raw request payloads.

The pairing user experience is owned by each native application. Rivet supplies the state machine, cryptographic transcript, persistence hooks, and diagnostics; it does not supply a cross-platform pairing screen.

## Session protocol

TLS negotiates the application protocol `rivet-device/1`. Before RVT1, a bounded device-session preface authenticates the paired credential, identifies the requested application and protocol version, and returns the effective scopes and limits. The preface is capped at 8 KiB and has a ten-second deadline.

After authentication the gateway emits the ordinary RVT1 v1 Hello frame. Existing Swift and Kotlin `RivetClient` implementations can then own the ordered byte stream. The network wrapper is responsible for TLS, the preface, reconnect policy, and converting the resulting stream into the input/output handles those clients already accept.

The gateway parses and rewrites every admitted frame:

- Request names and arguments are validated against the effective scopes;
- remote request IDs map to host-client requests and are never forwarded as host IDs;
- Cancel affects only the mapped request owned by that session;
- Responses and Errors return with the original remote ID;
- Events are filtered per session before fan-out;
- Shutdown closes only the remote session;
- Hello, Response, Error, and Event frames from a client are protocol violations.

Unknown or forbidden declarations return stable request-local Errors without revealing whether a non-exported declaration exists. Authentication and framing failures close the connection.

## Limits and backpressure

RVT1's general 64 MiB frame limit is too large for an untrusted companion connection. The gateway applies a lower 512 KiB payload limit before allocation or decoding in both directions. Device-generated clients expose the same limit.

Initial implementation limits are deliberately conservative:

- 64 pending requests per session;
- 8 concurrent authenticated sessions per application;
- one bounded outgoing queue per session;
- a 30-second handshake/authentication deadline including TLS;
- configurable idle disconnect, disabled while requests are pending.

State Events are coalesced by State name when a slow client has not consumed the previous value. Ordinary Events preserve order and are never silently coalesced; a client that exhausts its queue is disconnected with a stable slow-consumer reason. These rules prevent a phone leaving Wi-Fi from growing the desktop process without bound.

Reconnect creates a new RVT1 session. Pending calls fail and are not replayed automatically because RPCs may have side effects. After reconnect, generated clients explicitly re-read allowed State; Events are live notifications, not a durable journal.

## Threat model

The design protects against:

- an unpaired process on the LAN discovering and calling the desktop service;
- a paired reader invoking controller-only RPCs or writing State;
- request-ID collisions between the desktop UI and multiple devices;
- oversized frames, excessive concurrency, and slow consumers;
- passive network capture and active pairing interception when the fingerprint/short string is verified;
- a revoked device continuing to issue new requests.

It does not protect a device after that device's OS account or secure storage is compromised, a user who confirms mismatched pairing strings, malicious behavior inside an application-exported RPC, or traffic after application code deliberately exposes it through another service.

## Platform ownership

The public behavior and test vectors are shared; networking remains platform-native:

| Platform | Host/client responsibility |
|---|---|
| macOS/iOS | Network.framework TLS/listener/connection, Bonjour discovery, Keychain storage |
| Windows | native TLS and listener, Windows DNS-SD APIs, Credential Manager storage |
| Android | TLS socket/connection, NSD discovery, Android Keystore storage |
| Linux | system TLS and DNS-SD integration, Secret Service storage; availability reported honestly by diagnostics |

The first vertical slice targets macOS and Windows desktop hosts with an iOS companion because it proves both desktop adapters against the same mobile client. Android follows using the same wire vectors and generated schema. Linux support is not advertised until its listener, discovery, storage, and clean-runner integration all pass.

## Delivery plan

1. **Contract** — land this design, device-surface schema rules, stable error codes, and cross-language session/gateway golden vectors.
2. **In-memory gateway** — implement authorization, ID mapping, cancellation, Event filtering, State filtering, limits, and deterministic tests without opening a port.
3. **Apple vertical slice** — add the macOS host and iOS client transport, pairing, pinning, secure persistence, reconnect, and a minimal native sample.
4. **Windows host** — implement the same listener/discovery/security contract and run the iOS sample against it.
5. **Android client** — bind discovery/TLS streams to the existing coroutine client and compile the same generated device API.
6. **Linux host** — add the native adapter and only then update the platform maturity table.

Every transport stage must verify: disabled means no listener; unauthenticated and revoked clients cannot call; forbidden RPC/State/Event names do not leak; the 512 KiB limit is enforced before allocation; cancellations cannot cross session or request-ID ownership; slow readers remain bounded; reconnect never replays a side-effecting RPC; and desktop in-process behavior remains unchanged.

## Rejected alternatives

### Expose the embedded backend socket

Rejected because the in-process connection assumes a trusted native UI, exposes the full application schema, lets Shutdown affect backend lifecycle, and has a 64 MiB frame allowance. Authentication wrapped around that socket would not add route- or State-level authority.

### Put a second Racket backend on the phone

Rejected for companion applications because it duplicates downloads, credentials, data, and lifecycle ownership. Independent mobile applications may embed Racket later, but that is a different product shape.

### Invent a JSON-over-TCP application protocol

Rejected because it would duplicate RVT1 value semantics, cancellation, Events, State, Swift/Kotlin clients, compatibility rules, and generated types. The small device-session preface handles trust negotiation; application traffic stays RVT1.

### Treat mDNS discovery or a pairing code as authorization

Rejected because discovery is observable and short codes are guessable or relayable. Authorization requires a confirmed server identity, a per-device credential, and server-side scopes on every request.
