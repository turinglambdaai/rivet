# Rivet maintainer agent contract

Human-first. Agent-native. Local by design.

## Product boundary

Rivet keeps shared application logic in Racket and uses each platform's
first-party UI stack: WinUI 3/C++/WinRT on Windows, SwiftUI/AppKit on Apple
platforms, and GTK4 on Linux. Android uses native Kotlin/Jetpack Compose.

Do not introduce a cross-platform UI DSL, replace RVT1 with an ad-hoc
transport, or mix distribution/system services into the embedding lifecycle.
Mobile support must be described by its actual maturity: a portable runtime or
typed companion foundation is not yet a generated, packaged application flow.

### Commercial entitlement boundary

Rivet owns application runtime, native UI, general secure storage,
distribution, and update integrity. It does not own product entitlements,
trials, activations, seats, subscriptions, payments, or accounts. Commercial
products may depend on Rivet and
[Permit](https://github.com/turinglambdaai/permit) independently, but Rivet
must not depend on Permit or grow a built-in licensing subsystem.

A product may store Permit credentials, local-trial state, or an
`installation_id` through Rivet's general secure-storage API. That does not
move their semantics into Rivet. Rivet update-signing keys, platform publisher
credentials, and Permit credential-signing keys are separate trust domains and
must use separate keys and rotation procedures. The shared integration
contract lives at
[`Permit/docs/framework-integration.md`](https://github.com/turinglambdaai/permit/blob/main/docs/framework-integration.md).

Before roadmap, desktop-closeout, or mobile-delivery work, read
`docs/desktop-closeout-mobile-plan.md`. It records the current decision,
sequencing, exit criteria, evidence, and handoff state.

Treat repository state as the agent-to-agent handoff. Do not rely on prior chat
history: read the plan's **Next implementation handoff**, implement only that
bounded slice, update its evidence, run the required tests, and commit the
coherent change so the next agent can reproduce the same context.

## Start with evidence

For an application project, run:

```bash
raco rivet inspect --json
raco rivet doctor --json
```

For this repository, inspect the nearest implementation and its tests before
editing. The shared wire contract is documented in `docs/protocol.md` and
exercised by `rivet/tests/protocol-golden.txt` across Racket, C++, Swift, and Kotlin.

## Source map

- `rivet/`: public backend, protocol, resources, system, and distribution APIs
- `rivet-cli/`: scaffold, diagnostics, code generation, build, package, verify
- `runtime/`: portable C++ RVT1 runtime used by Windows and Linux
- `platform/windows/`: WinUI 3 host and native adapters
- `platform/macos/`: Swift runtime, SwiftUI host, embedding, device channels
- `platform/linux/`: GTK4 host, embedded runtime, and system adapter
- `platform/android/`: Kotlin protocol and coroutine runtime foundation
- `rivet/tests/`: Racket behavior and CLI regression tests
- `.github/workflows/`: clean-platform and embedded-runtime gates, plus the
  desktop-architecture matrix (Windows ARM64, macOS Intel, Linux ARM64)

## Required validation

Run the narrowest relevant tests locally, then rely on all platform jobs before
merging native or packaging changes. At minimum for Racket/CLI changes:

```bash
raco test rivet/tests/
```

For portable native changes:

```bash
cmake -S runtime -B build/native -DRIVET_BUILD_TESTS=ON
cmake --build build/native --config Release
ctest --test-dir build/native -C Release --output-on-failure
```

For Kotlin changes:

```bash
platform/android/gradlew -p platform/android test
```

Generated application paths are `.rivet/`, `build/`, and `dist/`; do not hand
edit them. `raco rivet clean` is the scoped cleanup operation.
