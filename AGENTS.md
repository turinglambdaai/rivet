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

Rivet does not own product entitlements, trials, activations, seats,
subscriptions, payments, checkout, or accounts. Permit owns signed-rights
semantics; Commerce owns optional online commercial orchestration. Both are
composed by the product: `product -> rivet`, `product -> permit`, and optional
`product -> commerce client`. Rivet depends on neither Permit nor Commerce.
Update-signing keys, platform publisher credentials, Permit
credential-signing keys, and Commerce secrets are separate trust domains. The
normative local rights boundary is
[`permit/docs/framework-integration.md`](https://github.com/turinglambdaai/permit/blob/main/docs/framework-integration.md);
do not restate it here.

Before roadmap, desktop-closeout, or mobile-delivery work, read
`docs/desktop-closeout-mobile-plan.md`. It records the current decision,
sequencing, exit criteria, evidence, and handoff state.

Treat repository state as the agent-to-agent handoff. Do not rely on prior chat
history: read the plan's **Next implementation handoff**, implement only that
bounded slice, update its evidence, run the required tests, and commit the
coherent change so the next agent can reproduce the same context.

## Family contracts

The five-repository dependency graph, repository ownership, change routing,
release order, and trust boundaries are maintained in Keel's
[`docs/family-architecture.md`](https://github.com/turinglambdaai/keel/blob/main/docs/family-architecture.md).
Rivet's active milestones remain owned by
`docs/desktop-closeout-mobile-plan.md`; do not copy its queue into a family
document.

Rivet and Glaze share the transport-neutral contract package `keel`. Family
packages are consumed only as published catalog packages, never vendored or
copied, and every family dependency declares a `#:version` floor equal to
the lowest version this suite actually covers; raise the floor in the same
CHANGELOG entry that raises the tested version. The weekly *Family
compatibility* workflow (`family-compat.yml`) updates family packages to
latest and runs the full Racket suite; when it goes red, adapt here or fix
upstream, and keep `main` green before starting any other work.

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
