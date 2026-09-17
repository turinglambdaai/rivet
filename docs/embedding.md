# Racket CS Embedding

Rivet embeds Racket CS in the native application process. This document records the assumptions the platform hosts must follow.

## Source of truth

The embedding ABI is Racket's own `chezscheme.h`, `racketcs.h`, and `racketcsboot.h`. Rivet does not maintain a parallel copy of those definitions.

A native source file that calls the Racket CS API includes:

```cpp
#include "chezscheme.h"
#include "racketcs.h"
```

On Windows the native executable links to the versioned Racket CS DLL/import library from the matching Racket installation/runtime bundle. On macOS Rivet can use the Racket framework or an exactly matching static/dynamic Racket CS build.

## Exact version rule

The following artifacts are one compatibility unit:

- Racket CS library;
- `petite.boot`;
- `scheme.boot`;
- `racket.boot`;
- the Racket version used to compile/package application modules.

Rivet does not silently select a nearby release. If the requested exact runtime is not available, tooling must either build/provision that exact runtime or stop with a clear diagnostic.

This intentionally differs from development scripts that try `racket-X.Y-1` or the nearest branch as a convenience.

## Boot

The native host zero-initializes `racket_boot_arguments_t` and sets at least:

```cpp
racket_boot_arguments_t boot{};
boot.boot1_path = petite.c_str();
boot.boot2_path = scheme.c_str();
boot.boot3_path = racket.c_str();
boot.exec_file = executable.c_str();

racket_boot(&boot);
```

For packaged applications Rivet can additionally provide:

- `collects_dir`;
- `config_dir`;
- `dll_dir` on Windows for collected runtime DLLs.

Paths to boot images should contain a directory separator, as required by the embedding contract.

## Loading application modules

Rivet's application build step uses `raco ctool --mods` to create a compiled module bundle. The native worker loads it with:

```cpp
racket_embedded_load_file(core_zo.c_str(), 1);
```

The bundle includes the application module and its transitive Racket module declarations.

For a source file named `backend.rkt`, the normal compiled module name used by the scaffold is `backend`.

## Requiring the entry procedure

The native worker constructs a quoted module path and asks Racket for the configured entry procedure:

```cpp
ptr mod = Scons(Sstring_to_symbol("quote"),
                Scons(Sstring_to_symbol("backend"), Snil));

ptr results = racket_dynamic_require(mod, Sstring_to_symbol("start"));
ptr start = Scar(results);
```

`racket_dynamic_require` returns a list of result values through the embedding API. For one value, take the `car` before applying it.

## Calling Racket

Native code should use `racket_apply` as the normal entry point for calling a Racket procedure:

```cpp
ptr args = Scons(Sfixnum(in_fd),
                 Scons(Sfixnum(out_fd), Snil));
(void)racket_apply(start, args);
```

Rivet passes plain integer file descriptors rather than Racket port objects. `rivet/backend` converts those descriptors into binary Racket ports through `serve-fds`.

The application entry procedure must contain exceptions instead of allowing an exception/escape to cross the `racket_apply` boundary. Rivet's scaffold/runtime will grow a dedicated top-level error boundary before the embedding layer is considered stable.

## Racket values and native threads

Raw Racket values are not Rivet's cross-thread data model. The embedding API permits garbage collection/object movement around Racket calls, and retaining arbitrary raw values creates subtle lifetime requirements.

Rivet therefore uses this rule:

> Convert at the boundary; move protocol bytes/native values between threads, not Racket pointers.

The Racket worker may construct temporary symbols/pairs required to enter the application. The WinUI/SwiftUI layer never sees them.

## Runtime files

Packaging should use `raco ctool --runtime` alongside `--mods` to collect runtime dependencies. On Windows, collected optional DLLs used by Racket should be made discoverable using `racket_boot_arguments_t.dll_dir` or an equivalent controlled DLL search path.

The target machine should not need a globally installed Racket distribution.

## Shutdown

The expected normal sequence is:

1. native client writes a Rivet Shutdown frame;
2. `serve-fds` returns and closes its protocol ports/descriptors;
3. `racket_apply` returns to the worker;
4. the worker deinitializes the Chez/Racket runtime;
5. native reader observes EOF and exits;
6. application host joins both threads.

Unexpected startup/runtime failures must eventually close the transport so the native side never waits forever for the Hello frame. That failure-path hardening is part of the Windows runtime milestone.
