# Package verification

Rivet treats package verification as part of packaging rather than as an optional CI step.

`raco rivet package` builds a Release/self-contained native application, assembles the distributable layout, signs the macOS development bundle when appropriate, and then verifies the result before reporting success.

Use `raco rivet verify` to re-run the same checks against the package already present in `dist/`.

## Windows

The Windows verifier checks that the portable directory contains the WinUI executable, the compiled Racket backend, all three Racket CS boot files, and the embedded Racket CS DLL.

It then uses the MSVC `dumpbin /DEPENDENTS` tool on each root EXE/DLL. Every imported DLL must resolve either to another file shipped in the portable directory or to the current Windows system directories/API-set contract. An unresolved import causes verification to fail.

This catches a common release failure mode where a package builds correctly on the developer machine but accidentally relies on a locally installed Racket runtime, Visual Studio runtime component, or Windows App Runtime component that was not copied into the distributable directory.

`raco rivet doctor` reports the discovered `dumpbin.exe`. The Visual Studio C++ tools are therefore part of the Windows packaging toolchain, not only the compile toolchain.

## macOS

The macOS verifier checks the `.app` layout, the application executable, `Info.plist`, compiled Racket backend, boot files, and embedded `Racket.framework`.

It then verifies:

- the nested Racket framework signature;
- the complete app signature with `codesign --deep --strict`;
- the main executable links to Racket through `@rpath/Racket.framework/...` rather than an absolute developer-machine path;
- the executable contains `@executable_path/../Frameworks` in its load commands;
- the bundled Racket framework has an `@rpath/Racket.framework/Versions/.../Racket` install name;
- `Info.plist` passes `plutil -lint` when `plutil` is available.

These checks are deliberately separate from production Developer ID signing and notarization. The current development package may use ad-hoc signing, but its runtime layout must already be relocatable and internally consistent.

## CI

The Windows and macOS package-smoke jobs run `raco rivet package` and then run `raco rivet verify` again. This validates both the automatic package gate and the standalone re-verification command on real platform runners.
