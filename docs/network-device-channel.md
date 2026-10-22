# Network device channel design

Status: active design for [issue #85](https://github.com/turinglambdaai/rivet/issues/85).
The transport-independent `RivetDeviceGateway` policy/session core, pairing/
authentication lifecycle, and byte-exact session preface are implemented and
tested in memory. The Apple pairing-credential Keychain adapter, bounded
Network.framework TLS stream adapter, per-install identity provider, and
disabled-by-defaulThe explicit iOS Bonjour browser accepts only the privacy-bounded
canonical advertisement and does not connect or authorize a peer. The
`RivetDeviceAppleCompanion` library now composes explicit candidate selection,
pinned reconnect or provisional RVD1 pairing, the Keychain pairing store,
credential-persistence gating, and a product-supplied RVT1 application handler.
A reusable `RivetDeviceAppleCompanionUI` SwiftUI view/model is also available
for nearby discovery, explicit pairing or stored-device reconnect, pairing-code
confirmation, saved-pairing removal, and session status. Products supply the
host pairing-window ID from their QR/manual flow and the post-RVD1 application
handler. These are reusable components, not a generated or signed mobile app:
products still own local-network permission declarations, the application-
specific RVT1 client/gateway binding, packaging, and real-device acceptance.

### iPhone, iPad and Apple Watch companion boundaries

The Apple companion foundation supports **iOS 16+** (including
**iPadOS**, using the same iOS SDK) and portable **watchOS 9+** code.
An iPhone or iPad can run explicit Bonjour discovery and the pinned TLS
+ RVD1 session client. A TXT identifier or pairing hint does not grant
authority; stored SPKI pinning, dual-peer pairing approval, credential
persistence and accepted RVD1 remain mandatory before RVT1 traffic.

Apple Watch has a separate `RivetWatchConnectivity` foreground
**watch-to-iPhone relay**. It carries only bounded, non-empty (maximum 64 KiB per immediate
message) `RivetDevice` request/response envelopes through an activated, reachable
WCSession. The iPhone must register and scope the permitted routes on
its own `RivetDeviceRouter` and own the authorized desktop connection:
the watch transport itself neither exposes backend RPCs nor pairs
directly with a desktop. Invalid or oversized WatchConnectivity
requests/replies fail closed.

The framework CI runs Swift watch relay policy tests and compiles the
Rivet runtime and watch relay against iOS and watchOS device and
simulator SDKs, plus the Apple device security/session/TLS layers for
iOS devices and simulator. This is **SDK compilation coverage**, not
an iPad app layout check, a paired-Watch reachability run, mobile app
signing or packaging, foreground/background permission acceptance, or
real iOS/iPadOS TLS/Bonjour pairing evidence. Products must supply
local network permission declarations, pairing UIs, watch/iPhone UI,
route allowlists, lifecycle tests, and real-device evidence.

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

The implemented in-memory core deliberately stops before the network boundary.
`RivetDeviceGateway` owns the bounded set of authenticated sessions, while each
`RivetDeviceGatewaySession` owns effective scope grants, its remote request-ID
namespace, host request-ID mappings, cancellation, payload limits, and outbound
Event/State filtering. A `RivetDeviceGatewayHost` adapter is the only path from
that core to a host client. The Apple TLS, pairing, persistence, preface, host
listener, and advertisement layers now exist beside this core; their product
coordination and platform UI remain later layers and are not simulated by the
in-memory API.

## Invariants

The implementation must preserve these boundaries:

1. Racket stays the application-logic owner. The device gateway contains transport and authorization policy, not product behavior.
2. Each UI remains first-party native: SwiftUI/UIKit on iOS, Jetpack Compose on Android, WinUI 3 on Windows, SwiftUI/AppKit on macOS, and GTK4 on Linux.
3. RVT1 v1 framing and its closed value-tag set stay unchanged. The first
   gateway uses the existing generated schema subset; `Float64`, Map, and
   structured Error wait for explicit protocol negotiation and four-language
   conformance evidence. Network-session negotiation is outside RVT1 and
   completes before the gateway emits the normal RVT1 Hello frame.
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
3. A manual fallback connects with an untrusted provisional identity and shows the same short authentication string on both devices. The string is derived from the server public-key fingerprint plus fresh client and server nonces exchanged on that connection. Both screens require confirmation; a man-in-the-middle presents a different server key and therefore produces different strings.
4. Only after both the desktop user and the phone user confirm the matching string, the desktop issues a random 256-bit per-device credential over the authenticated channel and records the device name, granted scopes, creation time, and last-used time. The phone stores the credential and server pin in Keychain/Keystore.
5. The pairing window closes after success, expiry, five failed attempts, or an explicit cancel.

The desktop can list and revoke devices. Revocation takes effect for new requests on existing sessions and closes them. Rotating the server identity revokes every pin and credential and therefore requires re-pairing. Logs contain device IDs and stable error codes, never credentials, transcript contents, or raw request payloads.

The pairing user experience is owned by each native application. Rivet supplies the state machine, cryptographic transcript, persistence hooks, and diagnostics; it does not supply a cross-platform pairing screen.

The portable Swift core now implements this non-UI boundary.
`RivetDevicePairingCoordinator` owns the five-minute window, one active attempt,
the five-failure cutoff, a required 256-bit client nonce, fresh 256-bit server
nonce/credential, explicit cancel, and success/expiry close states.
`RivetDevicePairingTranscript` length-prefixes a
domain-separated application ID, SHA-256 server fingerprint, client nonce, and
server nonce before deriving a stable six-digit confirmation code.
Separate desktop and device confirmation methods make credential issuance
impossible until both peers have accepted the same attempt.
`RivetDevicePairingStore` keeps storage platform-neutral while requiring the
credential to live in secure storage; ordinary device metadata deliberately
omits it. `RivetDeviceSessionAuthenticator` uses one public authentication
failure for all mismatches, updates last-used metadata, and couples credential
revocation to `RivetDeviceGateway` session closure. `RivetDeviceAppleSecurity`
implements that pairing store with service-scoped, device-local Keychain
generic-password items. `RivetDeviceSession` implements the bounded wire
records, HMAC reconnect, pairing ordering, credential-persistence gate, and
server/client state machines. `RivetDeviceAppleTransport` enforces TLS 1.2+,
forward-secret AEAD cipher suites, the `rivet-device/1` ALPN, exact SPKI
SHA-256 pins or explicit provisional pairing, a 30-second connection deadline,
fail-closed preface decoding, and a one-way transition to RVT1 bytes. Apple
identity provisioning creates a P-256 private key and matching self-signed
certificate in the application Keychain namespace; explicit rotation changes
the SPKI pin. Its macOS listener admits at most the configured number of
connections before allocating transport/session state and closes them all on
disable, listener failure, or termination. While ready, that listener publishes
`_rivet-device._tcp` with a deterministic, 128-byte-bounded TXT record containing
only the session version, a per-listener ephemeral ID, and the pairing-window
bit; it removes the service before shutdown. Windows Credential Manager
storage, QR/manual UI, product enablement, and non-Apple adapters remain
unimplemented. `RivetDeviceAppleBonjourBrowser` explicitly starts and stops
Network.framework browsing, accepts only records validated by the shared
canonical decoder, reports endpoint/service-name/ephemeral-ID/pairing-hint
changes, bounds its candidate set and event queue, and removes vanished
candidates. A result is never treated as proof of identity or permission.
`RivetDeviceAppleSessionHost` now drives one
accepted connection through TLS and `RVD1`, surfaces pairing prompts for an
explicit desktop decision, enforces the post-TLS deadline, and lends RVT1 bytes
to an application handler only after the session server accepts the peer. That
handler must bind the accepted scopes to `RivetDeviceGateway`; the host does not
create an alternate authorization path. `RivetDeviceAppleSessionClient` is the
iOS counterpart: it takes one explicitly selected endpoint, pins reconnect
attempts to the fingerprint stored by the product, pairs only through explicit
provisional TLS plus the transcript, surfaces the pairing code without
auto-confirming it, persists each new credential through an injected
secure-storage boundary before accepting RVT1, enforces the post-TLS deadline,
and closes without a pairing fallback when authentication is rejected.
Choosing between reconnect and pairing when no credential exists, background
lifecycle, and permission strings stay product-owned; the client never treats
discovery identifiers or pairing hints as credential material. The portable
C++ runtime now carries the same contract for the Windows and Linux gateways:
`rivet/device_session.hpp` implements the RVD1 records, the authentication
proof and pairing-code transcripts, and the server state machine — including
the indistinguishable unknown-device challenge, the constant-time proof
comparison, canonical scopes, the pairing window/attempt boundaries as
injected interfaces, and the post-TLS deadline — all pinned by
`rivet/tests/device-session-golden.txt` plus deterministic state-machine
tests. `rivet/device_session_host.hpp` is the portable host driver shared
by both desktop gateways: it runs the preface on one thread over any
`rivet::Transport`, serializes decision-thread pairing writes with the run
loop, waits for the desktop decision with the pairing-window clock, ends
the run through the state machine's Close actions, and lends the accepted
stream to an application handler before any RVT1 byte reaches the preface
decoder. The Windows gateway is that thin adapter today: a CNG-persisted
P-256 self-signed identity with friendly-name lookup and deletion-based
rotation, an SChannel TLS server that fails closed on renegotiation and
requires the `rivet-device/1` ALPN, a bounded listener whose admission cap
rejects sockets before any transport state exists, and a DNS-SD
publication of the shared canonical advertisement while the listener is
ready (Windows offers no explicit deregistration, so the record decays
with its TTL after shutdown). The Android companion runs the client side
through the Kotlin `dev.rivet.session` package: the same records,
transcripts, state machine, and canonical advertisement codec, pinned by
the shared fixture, with NSD supplied by the application behind a driver
interface. The JVM-compatible `DeviceTLSClient` verifies the SHA-256 of
the server's DER SubjectPublicKeyInfo, restricts negotiated TLS to 1.2+
forward-secret AEAD suites with `rivet-device/1` ALPN, and returns streams
only after a pinned reconnect or an explicitly provisional pairing handshake.
Provisional TLS is not device authorization: the RVD1 dual-confirmation and
credential-persistence gate still precede application traffic. Android NSD
resolution and real-device interoperability remain product/platform work.
Generated Kotlin clients add a `RivetDeviceAPI` containing only
the product's `device-rpcs` allowlist; the gateway remains authoritative if
application code bypasses that convenience surface.

## Session protocol

TLS negotiates the application protocol `rivet-device/1`. Before RVT1, a
bounded device-session preface authenticates the paired credential, identifies
the requested application and protocol version, and returns the effective
scopes and limits. `RivetDeviceSession` implements the byte-level v1 contract
below as transport-independent Swift code for macOS and iOS.

### Preface record

Each preface message is one record. Multi-byte header integers are little-
endian, matching RVT1:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 4 | ASCII magic `RVD1` |
| 4 | 1 | device-session version, currently `1` |
| 5 | 1 | message type |
| 6 | 2 | payload byte length, unsigned 16-bit |
| 8 | N | payload bytes |

The complete record, including its eight-byte header, is limited to 8 KiB.
The receiver validates magic, version, type, and `N <= 8184` before allocating
or invoking a value decoder. An unsupported device-session version closes the
connection without a response; the server never guesses a compatible version
or falls back to unprotected RVT1. The payload is exactly one RVT1 v1 value and
must be the message-specific List below with no trailing bytes. Reusing the closed
RVT1 value codec avoids a second string/bytes/container format; this does not
permit ordinary RVT1 frames before authentication.

UUID fields are 16-byte `Bytes` values in RFC 4122 canonical byte order. Nonces,
credentials, proofs, and the server fingerprint are 32-byte `Bytes` values.
The fingerprint is SHA-256 over the DER-encoded SubjectPublicKeyInfo (SPKI) of
the TLS leaf certificate; hashing the whole certificate is not conforming.
Application IDs, device display names, and scope names are at most 128 UTF-8
bytes. At most 64 unique scope names may be returned, sorted by their UTF-8
bytes. Integers in payload shapes are non-negative RVT1 `Int64` values.

| Value | Name | Direction | Payload shape |
|---:|---|---|---|
| 1 | Authenticate | client → server | `[application-id, device-id, client-nonce]` |
| 2 | AuthChallenge | server → client | `[server-nonce]` |
| 3 | AuthProof | client → server | `[proof]` |
| 4 | PairStart | client → server | `[application-id, window-id, device-name, client-nonce]` |
| 5 | PairChallenge | server → client | `[attempt-id, server-nonce]` |
| 6 | PairDecision | client → server | `[attempt-id, confirmed?]` |
| 7 | Accept | server → client | `[session-id, scope-names, max-payload, max-pending]` |
| 8 | Paired | server → client | `[device-id, credential, session-id, scope-names, max-payload, max-pending]` |
| 9 | Reject | server → client | `[stable-code]` |

`max-payload` is initially 524288 and `max-pending` is initially 64. The
server remains authoritative if a client advertises or assumes different
limits. A valid `Accept` or `Paired` is immediately followed by the ordinary
RVT1 v1 Hello frame on the same ordered TLS stream. The client must persist a
new pairing credential before accepting that Hello. If persistence fails it
closes the connection; the resulting unreachable desktop entry is safe but
must be visible for user revocation and a fresh pairing attempt.

### Reconnect authentication

Reconnect uses this strict sequence, with no pipelining or fallback:

```text
client Authenticate
server AuthChallenge
client AuthProof
server Accept | Reject
server RVT1 Hello       # only after Accept
```

The proof is the full 32-byte result of:

```text
HMAC-SHA256(credential,
  "rivet-device-auth-v1" ||
  LP(application-id UTF-8) ||
  LP(server SPKI SHA-256 fingerprint) ||
  LP(device-id bytes) ||
  LP(client-nonce) ||
  LP(server-nonce))
```

Here `LP(x)` is a four-byte **big-endian** unsigned length followed by `x`.
Cryptographic transcript lengths are intentionally network order even though
record headers follow RVT1's little-endian convention. Both nonces must be
fresh for the connection. The credential is never transmitted during a
reconnect, and a captured proof is unusable with another nonce pair or server
identity.

For an unknown/revoked device, wrong application ID, changed server identity,
or malformed stored credential, the server still emits a fresh challenge and
performs a dummy HMAC before returning the single public code
`authentication_failed`. The record sequence and public error do not reveal
which field failed. Implementations compare the proof in constant time.

### Pairing sequence

Pairing uses this strict sequence:

```text
client PairStart
server PairChallenge
client PairDecision(false)  -> server Reject, close
client PairDecision(true)   -> wait for desktop confirmation
desktop rejects/expires     -> server Reject, close
both peers confirm          -> server Paired
server RVT1 Hello           # only after Paired
```

The device and desktop independently derive the displayed six-digit code from
the existing pairing transcript. Its exact bytes are:

```text
SHA256(
  "rivet-device-pairing-v1" ||
  LP(application-id UTF-8) ||
  LP(server SPKI SHA-256 fingerprint) ||
  LP(client-nonce) ||
  LP(server-nonce))
```

Interpret the first four digest bytes as a big-endian unsigned integer, reduce
modulo 1,000,000, and render six decimal digits with leading zeroes. The code
is confirmation evidence, never a credential. `Paired` is emitted exactly once
and only after both `confirmOnDevice` and `confirmOnDesktop` accept the same
attempt. Granted scopes come only from the desktop confirmation; the device
cannot request or widen them.

`PairDecision(false)`, a desktop rejection, or a transcript mismatch consumes
one of the window's five failures. An invalid/expired unguessable window ID gets
`pairing_unavailable` without revealing another window. A disconnect abandons
the attempt; RPCs are never replayed and an attempt ID is never resumed on a
new TLS connection.

### Reject and timeout behavior

Validly framed semantic failures may use only these v1 codes:

- `authentication_failed`
- `pairing_unavailable`
- `pairing_rejected`
- `pairing_expired`
- `server_busy`
- `internal_error`

Reject payloads contain no human message, device name, application declaration,
credential bytes, proof, nonce, fingerprint, or storage error. After Reject the
server closes the TLS connection. Bad magic, impossible lengths, malformed
RVT1 values, wrong field counts/types/sizes, unexpected directions, duplicate
messages, and ordinary RVT1 bytes before acceptance close immediately without
a response or protocol fallback.

Normal reconnect must finish TLS plus preface within 30 seconds and the post-
TLS records within 10 seconds. Pairing must exchange PairStart/PairChallenge
within 10 seconds, then may wait only until the already-open five-minute pairing
window expires; individual device decisions still have a 10-second read
deadline once requested. Each connection permits exactly one authentication or
pairing flow.

### M2b acceptance evidence

The preface is a pure incremental codec and explicit state machine, kept
separate from Network.framework and listeners. The repository contains:

- a language-neutral golden fixture for every record type, the authentication
  proof, and the pairing code;
- boundary tests for fragmented and coalesced reads, the 8 KiB record limit,
  field counts/types/sizes, unexpected message order, duplicate messages, and
  trailing payload bytes;
- deterministic timeout tests using an injected clock rather than wall-clock
  sleeps;
- negative authentication tests showing that unknown, revoked, wrong-
  application, and changed-identity cases have the same public record sequence
  and `authentication_failed` result; and
- an inventory update that moves the session-preface finding from pending only
  after the codec and state-machine tests pass.

These checks run in `RivetDeviceSessionTests`, and
`rivet/tests/device-session-golden.txt` is the compatibility boundary for later
Kotlin and Windows implementations. A platform adapter may split or combine
stream writes, but it must not reinterpret, reorder, or extend these records.

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
2. **In-memory gateway (implemented)** — authorization, ID mapping,
   cancellation, Event filtering, State filtering, session/request/message
   limits, disconnect cleanup, and deterministic tests without opening a port.
3. **Apple vertical slice** — add the macOS host and iOS client transport, pairing, pinning, secure persistence, reconnect, and a minimal native sample.
4. **Windows host** — implement the same listener/discovery/security contract and run the iOS sample against it.
5. **Android client** — bind discovery/TLS streams to the existing coroutine
   client. The default-deny generated device API is implemented; the native
   NSD/TLS adapter and real-device evidence remain.
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
