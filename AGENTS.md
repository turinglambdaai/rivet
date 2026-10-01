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

## Start with evidence

For an application project, run:

```bash
raco rivet inspect --json
raco rivet doctor --json
```

For this repository, inspect the nearest implementation and its tests before
editing. The shared wire contract is documented in `docs/protocol.md` and
exercised by `tests/protocol-golden.txt` across Racket, C++, Swift, and Kotlin.

## Source map

- `rivet/`: public backend, protocol, resources, system, and distribution APIs
- `rivet-cli/`: scaffold, diagnostics, code generation, build, package, verify
- `runtime/`: portable C++ RVT1 runtime used by Windows and Linux
- `platform/windows/`: WinUI 3 host and native adapters
- `platform/macos/`: Swift runtime, SwiftUI host, embedding, device channels
- `platform/linux/`: GTK4 host, embedded runtime, and system adapter
- `platform/android/`: Kotlin protocol and coroutine runtime foundation
- `tests/`: Racket behavior and CLI regression tests
- `.github/workflows/`: clean-platform and embedded-runtime gates, plus the
  desktop-architecture matrix (Windows ARM64, macOS Intel, Linux ARM64)

## Required validation

Run the narrowest relevant tests locally, then rely on all platform jobs before
merging native or packaging changes. At minimum for Racket/CLI changes:

```bash
raco test tests/
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

For Swift package tests that include `RivetEmbedding`, pass the exact Racket
include and framework search paths selected by the installed Racket CS:

```bash
racket_include="$(racket -e '(require setup/dirs) (display (path->string (find-include-dir)))')"
racket_lib="$(racket -e '(require setup/dirs) (display (path->string (find-lib-dir)))')"
RIVET_RACKET_FRAMEWORK_DIR="$racket_lib" swift test --package-path platform/macos -Xcc "-I${racket_include}"
```

Generated application paths are `.rivet/`, `build/`, and `dist/`; do not hand
edit them. `raco rivet clean` is the scoped cleanup operation.
