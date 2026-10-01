# Package verification

Rivet treats package verification as part of packaging rather than as an optional CI step.

`raco rivet package` builds a Release/self-contained native application, assembles the distributable layout, signs the macOS development bundle when appropriate, and then verifies the result before reporting success.

Use `raco rivet verify` to re-run the same checks against the package already present in `dist/`.

`raco rivet package --production` adds publisher signing/trust steps, and `raco rivet verify --production` re-runs the corresponding production trust checks.

## Launch smoke

After the platform-specific structural, dependency, and trust checks pass,
Rivet starts the packaged executable from the system temporary directory. The
artifact must remain alive for five seconds. Rivet then terminates the process
and reports success. An early exit fails verification with its exit status and
bounded stdout/stderr diagnostics; each stream is drained concurrently and
captured up to 64 KiB so a noisy failure cannot deadlock verification or grow
memory without bound.

Starting outside the package directory is deliberate. It exercises the same
relocatable resource and foreign-library assumptions as Finder, Explorer, or a
desktop launcher instead of accidentally making relative paths work through
the verifier's current directory.

The launch smoke runs by default when Rivet detects an interactive Windows
session, the current macOS console user, or a Linux `DISPLAY`/Wayland session.
Headless environments print an explicit skip notice. Use
`--skip-launch-smoke` with `package` or `verify` when the packaging machine
cannot open GUI applications; this flag skips only process startup, never the
normal layout, dependency, metadata, signature, or installer checks. It can be
combined with `--production` in either order.

The smoke gate proves that the artifact survives initial process and embedded
runtime startup. It is not a substitute for application-specific UI
interaction or accessibility tests.

## Windows

The Windows verifier checks that the portable directory contains the WinUI executable, the compiled Racket backend, all three Racket CS boot files, and the embedded Racket CS DLL.

It then uses the MSVC `dumpbin /DEPENDENTS` tool on each root EXE/DLL. Every imported DLL must resolve either to another file shipped in the portable directory or to the current Windows system directories/API-set contract. An unresolved import causes verification to fail.

This catches a common release failure mode where a package builds correctly on the developer machine but accidentally relies on a locally installed Racket runtime, Visual Studio runtime component, or Windows App Runtime component that was not copied into the distributable directory.

`windows-min-version` is configured in `rivet.rktd`. The Rivet build environment passes it to the generated WinUI project as `WindowsTargetPlatformMinVersion`, rather than storing a second application-specific minimum version in the project template.

`raco rivet doctor` reports the discovered `dumpbin.exe`. The Visual Studio C++ tools are therefore part of the Windows packaging toolchain, not only the compile toolchain.

In production verification mode, Rivet additionally requires Windows SDK `signtool.exe` and runs `signtool verify /pa /v` against `RivetHost.exe` after the normal dependency-closure audit.

## macOS

The macOS verifier checks the `.app` layout, the application executable, `Info.plist`, compiled Racket backend, boot files, and embedded `Racket.framework`.

It then verifies:

- the nested Racket framework signature;
- the complete app signature with `codesign --deep --strict`;
- the main executable links to Racket through `@rpath/Racket.framework/...` rather than an absolute developer-machine path;
- the executable contains `@executable_path/../Frameworks` in its load commands;
- the bundled Racket framework has an `@rpath/Racket.framework/Versions/.../Racket` install name;
- `Info.plist` passes `plutil -lint`;
- `LSMinimumSystemVersion` exactly matches `macos-min-version` from `rivet.rktd`.

The development package may use ad-hoc signing, but its runtime layout must already be relocatable and internally consistent.

In production verification mode, Rivet additionally runs `xcrun stapler validate` to require a stapled notarization ticket and asks Gatekeeper to assess the application with `spctl --assess --type execute`.

## Linux

The Linux verifier checks the application directory, executable bit, compiled Racket backend, all three boot files, and configured application resources. It then runs `ldd` on the GTK4 host and rejects every unresolved shared-library dependency. Racket CS itself is linked statically; GTK4 and the normal Linux system libraries remain native distribution dependencies.

In production verification mode, the verifier additionally requires the released installer (`<name>-<version>-linux-<arch>.tar.gz` plus its `.sig`). Because the archive is deterministic, it rebuilds the tarball from the packaged directory, requires a byte-identical match with the released installer, and validates the detached Ed25519 signature against `RIVET_LINUX_SIGN_PUBLIC_KEY`. Linux keeps one honest signature story instead of pretending a generic signature covers Debian, Fedora, Arch, Flatpak, and other delivery channels; distro-native packages remain follow-up work.

## CI

The Windows, macOS, and Linux package-smoke jobs run `raco rivet package` and then run `raco rivet verify` again. They exercise real generated applications and packaged resources; Windows and macOS additionally override deployment targets so those platform metadata paths are covered rather than only their defaults. Interactive Windows and macOS runners also execute the launch gate. Headless Linux runners retain the static/package checks and print the launch-skip notice unless the job supplies a graphical session.

Normal pull-request CI does not contain publisher certificates or Apple notarization credentials, so it intentionally exercises development packaging. Production credential parsing is covered by platform-independent Racket tests; certificate-backed production signing belongs in a trusted publisher release environment.
