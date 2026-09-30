# Android architecture

Rivet keeps Android native instead of introducing a cross-platform UI abstraction. Android applications will own a normal Kotlin/Jetpack Compose UI while Rivet supplies the protocol, generated client, embedded Racket boundary, and build/package integration.

## Current foundation

`platform/android` contains a Kotlin implementation of the RVT1 v1 frame and value codec. It enforces the same 64 MiB payload, nesting-depth, node-count, UTF-8, message-type, version, and trailing-byte boundaries as the Racket, C++, and Swift implementations.

The Kotlin tests consume `tests/protocol-golden.txt` directly. A change to the shared wire format therefore cannot silently pass on Android while producing different bytes on the existing platforms. Additional tests cover signed 64-bit values, unsigned request identifiers, binary equality, and nesting limits.

The Gradle wrapper pins Gradle 9.7 and verifies the distribution SHA-256 before execution. CI also validates the wrapper binary and runs the Kotlin tests on Java 17.

## Product boundary

This module is not yet an Android application host. The remaining layers are deliberately explicit:

1. A coroutine-based Kotlin client for Request, Response, Error, Event, State, Cancel, and lifecycle handling.
2. Kotlin code generation from the existing Racket schema, without changing RVT1.
3. A JNI bridge to a portable Racket CS static runtime and its boot artifacts for supported Android ABIs.
4. A first-party Jetpack Compose scaffold plus Gradle/Android Studio project generation.
5. Emulator/device round trips, lifecycle and process-death recovery, package verification, app signing, and release automation.

Wear OS starts as a companion target, mirroring the watchOS decision: native watch UI communicates with a phone-hosted backend through a typed device channel. An independently embedded watch runtime can remain a later option without making every watch application pay its size and lifecycle cost.
