# Android architecture

Rivet keeps Android native instead of introducing a cross-platform UI abstraction. Android applications will own a normal Kotlin/Jetpack Compose UI while Rivet supplies the protocol, generated client, embedded Racket boundary, and build/package integration.

## Current foundation

`platform/android` contains a Kotlin implementation of the RVT1 v1 frame and value codec. It enforces the same 64 MiB payload, nesting-depth, node-count, UTF-8, message-type, version, and trailing-byte boundaries as the Racket, C++, and Swift implementations.

The module also supplies a coroutine-native `RivetClient`. It validates the Hello handshake, multiplexes bounded concurrent calls by unsigned 64-bit request ID, delivers ordered Events, maps backend Errors, supports `$state` get/set and change parsing, propagates coroutine cancellation as an RVT1 Cancel frame, and owns deterministic Shutdown/stream cleanup. Request, Cancel, response, and Shutdown writes are serialized with pending-request ownership so cancellation cannot overtake its Request or target a later reused ID.

The Kotlin tests consume `tests/protocol-golden.txt` directly. A change to the shared wire format therefore cannot silently pass on Android while producing different bytes on the existing platforms. Additional tests cover signed 64-bit values, unsigned request identifiers and wraparound, binary equality, nesting limits, request/response/error/event behavior, State helpers, pending-call limits, cancellation ordering, lifecycle, and Shutdown.

`raco rivet build` (and `raco rivet generate`) now emits a typed Kotlin client next to the Swift/C++ clients at `.rivet/generated/kotlin/dev/rivet/generated/GeneratedBackend.kt`. It targets the coroutine runtime: RPCs become `suspend` functions, Records become data classes, Enums become `enum class` values that carry their stable wire name, Events become a sealed `RivetEvent` hierarchy, and shared State becomes typed `get`/`set` accessors. CI generates this client from the shared schema-matrix backend and compiles it with the pinned Gradle/Kotlin toolchain, so a schema change that would not compile on Android fails the desktop PR too.

The Gradle wrapper pins Gradle 9.7 and verifies the distribution SHA-256 before execution. CI also validates the wrapper binary and runs the Kotlin tests on Java 17.

## Product boundary

This module is not yet an Android application host. The remaining layers are deliberately explicit:

1. A JNI bridge to a portable Racket CS static runtime and its boot artifacts for supported Android ABIs.
2. A first-party Jetpack Compose scaffold plus Gradle/Android Studio project generation that consumes the generated client.
3. Emulator/device round trips, lifecycle and process-death recovery, package verification, app signing, and release automation.

Wear OS is not in Rivet's current committed platform set. Its portable Kotlin pieces may make a future companion feasible, but delivery work is scoped to Android phones and tablets until that target is explicitly adopted.
