# Linux host (GTK4)

The third first-party host: a GTK4 window over one embedded Racket CS
backend, speaking RVT1 through the shared `runtime/` codec. The embedding
contract mirrors `platform/windows/runtime` — the same public Racket CS C API
and the same threading rules — with a connected `socketpair` standing in for
the Win32 named pipe pair. The Racket input and output ports receive distinct
descriptors for that socket so their ownership and shutdown behavior are
unambiguous.

Status: **proposed** (see the platform/linux issue). CI compiles the runtime
bridge against Racket's public embedding headers and exercises startup,
concurrent RPCs, State access, cancellation, overload, and shutdown against a
real embedded Racket CS instance. `raco rivet build` / `doctor` / `package`
wiring for Linux is follow-up work.

## Layout

```text
platform/linux/
├── runtime/
│   ├── backend.hpp        # rivet::linux::Backend — same contract as rivet::windows
│   └── backend.cpp        # racketcs boot + RVT1-over-socketpair transport
└── host/
    ├── GeneratedBackend.hpp  # scaffold schema; raco rivet build replaces it
    ├── CMakeLists.txt
    └── src/main.cpp       # GTK4 counter demo over the generated client
```

## Building by hand

Requirements: Racket CS (the installation being embedded), CMake ≥ 3.24,
pkg-config, GTK 4, and a graphical session (or Xvfb) to run.

```bash
export RIVET_ROOT="$PWD"
export RIVET_RACKET_INCLUDE="$(racket -e '(require setup/dirs) (display (path->string (find-include-dir)))')"
export RIVET_RACKET_LIB_DIR="$(racket -e '(require setup/dirs) (display (path->string (find-lib-dir)))')"
export RIVET_RACKET_LIBRARY="$(find "$RIVET_RACKET_LIB_DIR" \( -name 'libracketcs*.a' -o -name 'libracketcs*.so*' \) -print -quit)"
cmake -S platform/linux/host -B /tmp/rivet-linux-build
cmake --build /tmp/rivet-linux-build
```

The executable must sit beside a staged runtime to start: put `runtime/*.boot`
and `res/core.zo` (produced by `raco ctool --mods`, the same artifacts every
platform host consumes) next to `RivetHost`. A packaged prefix layout will be
defined with the Linux packaging target instead of being guessed by the host.

## Honest gaps

- No `raco rivet build`/`doctor`/`package` Linux path yet; the CMake above
  is the supported manual loop.
- The checked-in `GeneratedBackend.hpp` matches the scaffold schema so the
  host compiles before the first `build`; the Linux codegen target
  (emitting `rivet::linux`-bound clients) is follow-up work.
- GTK is a toolkit, not a display protocol: global hotkeys and always-on-top
  overlays are compositor-dependent. Application hosts that need them must
  define an explicit X11/Wayland policy.
