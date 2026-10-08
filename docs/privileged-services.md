# Privileged service boundary

Rivet applications sometimes need a small privileged native companion that
cannot safely live in the ordinary UI process: a macOS/iOS NetworkExtension,
an Android VpnService, a Windows service, or a Linux system daemon.

`rivet/system` exposes a deliberately small lifecycle boundary for this case.
It does **not** define a VPN API, network protocol, cross-platform daemon
protocol, or shared privileged-service implementation.

## Contract

Applications install a `privileged-service-adapter` through the first-party
native host and call:

- `privileged-service-status`
- `privileged-service-start!`
- `privileged-service-stop!`
- `privileged-service-reload!`

The application chooses a non-empty service identifier of at most 256
characters. Configuration is an opaque byte string owned by the application and
its native adapter. Rivet accepts at most 16 MiB, takes an immutable snapshot at
the adapter boundary, and never parses, logs, stores, or forwards it over RVT1.

A state value contains three application-neutral fields:

- `state` — a symbolic lifecycle state chosen by the adapter;
- `detail` — optional bounded diagnostic detail;
- `revision` — an adapter-owned monotonic revision useful for rejecting stale
  UI observations.

Rivet checks every adapter result before returning it to application code:
`state` must be a symbol, `detail` must be `#f` or a string of at most 4096
characters, and `revision` must be an exact non-negative integer. The adapter
still owns the meaning of lifecycle symbols and monotonicity across calls.

Headless tests can parameterize `current-privileged-service-adapter` with an
in-memory implementation. With no adapter installed, every lifecycle operation
fails closed.

## Platform ownership

The intended mapping is platform-native:

| Platform | Typical privileged companion |
|---|---|
| macOS / iOS / iPadOS / tvOS | NetworkExtension packet-tunnel provider |
| Android | VpnService |
| Windows | Windows service plus the application's selected packet/TUN layer |
| Linux | systemd/user daemon plus TUN/netlink integration |

Rivet owns none of those implementations. The native host is responsible for
installation, entitlement/permission checks, authentication of any helper IPC,
process/service recovery, and converting native state into the small lifecycle
contract.

## Security invariants

A privileged adapter should preserve these rules:

1. Starting a helper is an explicit application action; Rivet does not silently
   elevate privileges.
2. Helper IPC is authenticated and scoped to the current application install.
3. Opaque configuration bytes may contain credentials and therefore must not be
   written to Rivet logs or crash metadata.
4. Status detail is diagnostic metadata, not an escape hatch for arbitrary
   unbounded payloads.
5. Stop/reload operations must target only the named application service.
6. Native permission denial is surfaced as an error; adapters must not pretend
   that a tunnel/service is running.

This boundary is intentionally suitable for networking products without making
networking policy part of Rivet itself.
