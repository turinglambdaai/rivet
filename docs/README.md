# Documentation map / 文档导航

This page is the canonical map of Rivet documentation. Start with one path and
follow links only when the work crosses that boundary; the root README remains
a product overview rather than a second documentation index.

## Build an application / 开发应用

- [Getting started](getting-started.md) · [中文](getting-started.zh-CN.md)
- [Project configuration](configuration.md)
- [Diagnostics and cleanup](diagnostics.md)
- [Continuous integration](ci.md) · [中文](ci.zh-CN.md)
- [Agent-native development](agent-native.md)
- [Product acceptance evidence](product-acceptance.md)

## Understand contracts / 理解契约

- [Architecture](architecture.md) — process, runtime, UI, Android, and service boundaries
- [RVT1 protocol](protocol.md) and [runtime limits](runtime-limits.md)
- [Racket CS embedding](embedding.md)
- [API stability](api-stability.md) · [中文](api-stability.zh-CN.md)
- [Large payloads, pagination, and progress](large-payloads.md)

## Native platform integration / 原生平台集成

- [System services](system-services.md)
- [Windows host integration](windows-native-window.md)
- [Linux display policy](linux-display.md)
- [Real-time chart series](chart-series.md)
- [Typed device communication](device-communication.md)
- [Network device channel design](network-device-channel.md) — policy/pairing cores implemented; network transport not shipped

## Ship and maintain / 发布与维护

- [Package verification](package-verification.md)
- [Production signing](production-signing.md)
- [Release and updates](release-and-updates.md)
- [Releasing the Rivet framework](releasing.md)
- [Native UI end-to-end testing](native-ui-testing.md)
- [Protocol fuzzing](fuzzing.md) and [performance benchmarks](benchmarks.md)
- [Desktop closeout and mobile start plan](desktop-closeout-mobile-plan.md)

## Maintenance rule / 维护规则

Each topic has one canonical owner. Add a new page only when it defines a
durable boundary that cannot fit an existing owner; status snapshots and
completed milestones belong in the active plan or changelog, not permanent
standalone pages. When deleting or merging a page, update all repository links
and run `raco test rivet/tests/documentation.rkt`.

Active plans are temporary. When their exit gates close, move lasting decisions
and operating instructions into the canonical guides above, record the release
result in `CHANGELOG.md`, and delete the plan instead of preserving a second
history of the same feature. Durable protocol and security rationale stays in
its owning guide until the implementation supersedes it.
