# Linux host (GTK4)

The third first-party host: a GTK4 window over one embedded Racket CS
backend, speaking RVT1 through the shared `runtime/` codec. The embedding
contract mirrors `platform/windows/runtime` — the same public Racket CS C API
and the same threading rules — with a connected `socketpair` standing in for
the Win32 named pipe pair. The Racket input and output ports receive distinct
descriptors for that socket so their ownership and shutdown behavior are
unambiguous.

Status: **developer preview**. CI compiles the runtime bridge against Racket's
public embedding headers and exercises startup, concurrent RPCs, State access,
cancellation, overload, shutdown, project scaffolding, CLI build, packaging,
verification, and release against a real embedded Racket CS instance.

## Layout

```text
platform/linux/
├── runtime/
│   ├── backend.hpp        # rivet::linux_runtime::Backend — same contract as rivet::windows
│   └── backend.cpp        # racketcs boot + RVT1-over-socketpair transport
├── system/
│   ├── system_services.hpp  # rivet::system — single-instance, notifications,
│   └── system_services.cpp  #   autostart, Secret Service, crash hook, capabilities
└── host/
    ├── GeneratedBackend.hpp  # scaffold schema; raco rivet build replaces it
    ├── CMakeLists.txt
    └── src/main.cpp       # GTK4 counter demo over the generated client
```

## Building by hand

Requirements: an embeddable Racket CS build, CMake ≥ 3.24, pkg-config, GTK 4,
zlib, LZ4, curses, and a graphical session (or headless Weston) to run. The standard
prebuilt Linux Racket installer does not ship `libracketcs` or the three boot
files; build and install
Racket CS from a source distribution as described by Racket's embedding guide.
The CI workflow uses the official minimal "source + built libraries" archive so
the build remains reasonably small.

```bash
export RIVET_ROOT="$PWD"
export RIVET_RACKET_INCLUDE=/path/to/racket/include
export RIVET_RACKET_LIBRARY=/path/to/racket/lib/libracketcs.a
cmake -S platform/linux/host -B /tmp/rivet-linux-build
cmake --build /tmp/rivet-linux-build
```

The executable must sit beside a staged runtime to start: put `runtime/*.boot`
and `res/core.zo` (produced by `raco ctool --mods`, the same artifacts every
platform host consumes) next to `RivetHost`. `raco rivet build`, `dev`, and
`package` create this layout automatically.

## Display policy

Wayland is the primary Linux target. CI starts a headless Weston compositor,
unsets `DISPLAY`, selects `GDK_BACKEND=wayland`, and requires the packaged host
to survive the launch smoke. Rivet does not force that environment variable in
shipped applications: GTK may still select a distribution-provided X11 backend
for compatibility. X11 and XWayland are best-effort paths, not release gates,
and Rivet does not add X11-only application APIs. See
[Linux display policy](../../../docs/linux-display.md).

## Honest gaps

- Production releases use `raco rivet release`: a deterministic self-contained
  `.tar.gz` with a detached Ed25519 signature, plus deb/rpm/AppImage formats and
  a signed portable-zip update feed. Real install/upgrade evidence across the
  supported distribution matrix remains follow-up work.
- The system adapter covers single-instance, notifications, StatusNotifierItem
  tray integration, XDG autostart, Secret Service secure storage, crash hooks,
  graceful shutdown, and runtime capability reporting.
- GTK is a toolkit, not a display protocol: global hotkeys and always-on-top
  overlays remain compositor-dependent. Applications that need those features
  must use capability checks and a Wayland protocol or portal appropriate to
  their supported compositors.
