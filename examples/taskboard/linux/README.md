# Taskboard GTK4 host

This directory is the Linux presentation layer for the maintained Taskboard
example. It uses GTK4 and the generated C++ client while all task validation,
state transitions, resources, and cancellable workload behavior remain in
`../app/backend.rkt`.

Use the project commands from `examples/taskboard`, not CMake directly:

```bash
raco rivet doctor
raco rivet dev
```

`raco rivet build` supplies the exact Racket CS headers, static runtime, boot
files, and Rivet source paths expected by `CMakeLists.txt`. The resulting GTK4
host dispatches generated-client completions back to the GLib main loop,
exposes stable accessible labels/widget names, and treats an unavailable
desktop notification service as a non-fatal platform capability.

See the parent [English walkthrough](../README.md) or
[中文说明](../README.zh-CN.md) before changing the architecture.
