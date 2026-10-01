# Rivet Taskboard

Rivet Taskboard is the maintained, production-shaped example for learning how
to structure a native desktop application around a shared Racket backend.
[中文说明](README.zh-CN.md)

The generated counter remains the fastest toolchain check. This example goes
deeper: it implements a real list/detail workflow independently in WinUI 3,
SwiftUI, and GTK4 while sharing records, enums, RPCs, events, state, resources,
validation, and cancellation through Racket and RVT1.

## Run it from a checkout

From the Rivet repository root, link the checkout once and enter the example:

```bash
raco pkg install --auto --name rivet --link .
cd examples/taskboard
raco rivet inspect --json
raco rivet doctor
raco rivet dev
```

`doctor` reports the native prerequisites for the current operating system.
`dev` compiles the backend, regenerates the typed client, builds the current
platform UI, stages the exact Racket CS runtime, and launches the application.

The first screen is deliberately the same information architecture everywhere:
a task list, task details, status actions, sample-data reload, and a bounded
1,000-row workload with an explicit cancel action. The widgets and platform
behavior are not shared.

## Read the project in this order

1. [`app/backend.rkt`](app/backend.rkt) is the product contract. `BoardTask` and
   `ImportProgress` are named records, `TaskStatus` is an enum, and the RPCs own
   validation and task transitions.
2. [`rivet-schema.json`](rivet-schema.json) is the checked compatibility
   baseline generated from that contract.
3. Read the UI for your platform:
   - Windows: [`windows/MainWindow.xaml`](windows/MainWindow.xaml) and
     [`windows/MainWindow.xaml.cpp`](windows/MainWindow.xaml.cpp)
   - macOS: [`macos-host/Sources/RivetHost/ContentView.swift`](macos-host/Sources/RivetHost/ContentView.swift)
     and [`RivetHostApp.swift`](macos-host/Sources/RivetHost/RivetHostApp.swift)
   - Linux: [`linux/src/main.cpp`](linux/src/main.cpp)
4. [`tests/backend.rkt`](tests/backend.rkt) drives the real RVT1 server. It checks
   CRUD behavior, State and Event delivery, packaged resources, bounded input,
   cancellation, and generous startup/1,000-row regression budgets without
   mocking the transport.

The public record is named `BoardTask` rather than `Task` because generated
types must coexist cleanly with Swift concurrency's `Task`. Public schema names
are cross-language API design, not just Racket implementation details.

The project also demonstrates the least-privilege Apple companion boundary.
`rivet.rktd` exports only `list-tasks`, `get-task`, and `select-task` through
`device-rpcs`; mutations remain phone-owned. The generated Swift file therefore
contains Codable `BoardTask`/`TaskStatus` values, typed watch-side client
methods, and `RivetDeviceRouter.registerGeneratedBackend` for the phone.

## Make the first change

Open [`app/backend.rkt`](app/backend.rkt), find `initial-tasks`, and change the
title or notes of one task. Then run:

```bash
raco test tests/backend.rkt
raco rivet schema check rivet-schema.json --json
raco rivet dev
```

A text-only behavior change keeps the schema compatible. If you intentionally
add an RPC, Record field, Event, or State, regenerate and review the baseline:

```bash
raco rivet schema --output rivet-schema.json
git diff -- rivet-schema.json
```

Never refresh the baseline merely to silence a breaking-change report. Record
field order is wire-significant.

## Follow one interaction end to end

Choose **Generate 1,000**, then **Cancel**:

1. The native UI calls the generated `generate-demo-tasks` method.
2. Racket validates the maximum of 1,000 and emits bounded progress Events.
3. The native client keeps the RVT1 request id and sends Cancel when requested.
4. Rivet stops that request's custodian and returns `request cancelled`.
5. The backend commits the new task State only after generation completes, so a
   cancelled operation cannot expose a partial list.

That path demonstrates why cancellation and state ownership belong in the
framework contract instead of being improvised independently by every UI.

When a task reaches **Done**, each native host uses Rivet's notification system
service. Permission denial, a missing Linux session bus, or another unavailable
notification service is intentionally non-fatal: the domain mutation has
already succeeded and remains visible in the task list.

## Accessibility and performance contracts

The three hosts expose the same stable identifiers, including `task-list`,
`task-title`, `advance-task`, `generate-demo`, and `cancel-generation`.
WinUI uses automation IDs, SwiftUI uses accessibility identifiers, and GTK4
uses stable widget names plus accessible labels. Standard platform focus and
list controls provide Tab and arrow-key navigation without a custom keyboard
abstraction.

[`PERFORMANCE.md`](PERFORMANCE.md) defines the measured startup and 1,000-row
budgets, the timing boundaries, and how to record platform evidence. The RVT1
behavior test enforces the backend portion on every repository test run.

## Verify before sharing

```bash
raco rivet build
raco rivet package
raco rivet verify
```

The packaged sample data comes from [`assets/sample-tasks.rktd`](assets/sample-tasks.rktd)
through `resource-path`; it is copied by the `resources` declaration in
[`rivet.rktd`](rivet.rktd). See the main [getting-started guide](../../docs/getting-started.md)
and [architecture](../../docs/architecture.md) for the framework-level model.
