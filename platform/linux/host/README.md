# Linux host (GTK4)

The third first-party host: a GTK4 window over one embedded Racket CS
backend, speaking RVT1 through the shared `runtime/` codec. The embedding
contract mirrors `platform/windows/runtime` — same racketcs C API entry
points, same threading rules — with a connected `socketpair` standing in
for the Win32 named pipe pair.

Status: **proposed** (see the platform/linux issue). The host and runtime
bridge compile as a smoke and the backend path is exercised end-to-end by
the Fulcrum application; `raco rivet build` / `doctor` / `package` wiring
for Linux is a follow-up and is deliberately not part of this change.

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
export RIVET_RACKET_LIB_DIR="$(dirname "$(find "$(dirname "$(command -v racket)")/.." -name libracketcs.a | head -1)")"
cmake -S platform/linux/host -B /tmp/rivet-linux-build
cmake --build /tmp/rivet-linux-build
```

The executable must sit beside a staged runtime to actually start: put
`runtime/*.boot` and `res/core.zo` (produced by `raco ctool --mods`, the
same artifacts every platform host consumes) next to `RivetHost`, or under
`<prefix>/lib/<app>/{runtime,res}` with the binary in `<prefix>/bin`.
`raco rivet build` staging for Linux is follow-up work; until then,
applications like Fulcrum demonstrate the full staging flow.

## Honest gaps

- No `raco rivet build`/`doctor`/`package` Linux path yet; the CMake above
  is the supported manual loop.
- The checked-in `GeneratedBackend.hpp` matches the scaffold schema so the
  host compiles before the first `build`; the Linux codegen target
  (emitting `rivet::linux`-bound clients) is follow-up work.
- GTK is a toolkit, not a display protocol: global hotkeys and
  always-on-top overlays are compositor-dependent. Application hosts that
  need them (launchers) implement X11 grabs themselves and say so on
  Wayland — see Fulcrum's Linux host for the reference pattern.
