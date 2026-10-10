# Production graduation roadmap

Rivet's desktop foundation is tested across Racket, C++, Swift, Kotlin, and the
three desktop operating systems. Production graduation is intentionally a
stronger claim than “the project builds”: it requires evidence for installation,
native interaction, recovery, and long-term maintainability.

The [0.7 production-graduation milestone](https://github.com/turinglambdaai/rivet/milestone/1)
tracks four independently reviewable outcomes:

1. [Linux production graduation](https://github.com/turinglambdaai/rivet/issues/182)
   proves real install, upgrade, launch, uninstall, and recovery behavior on a
   declared distribution and desktop matrix. Native Wayland is the release
   target; X11 and XWayland remain best-effort toolkit compatibility paths.
2. [First-party update installation adapters](https://github.com/turinglambdaai/rivet/issues/183)
   close the signed-update loop through installation, restart, health
   confirmation, and rollback without changing RVT1 or the embedded-runtime
   boundary.
3. [Native UI end-to-end gates](https://github.com/turinglambdaai/rivet/issues/184)
   add platform-specific interaction, accessibility, screenshots, and failure
   artifacts. They do not introduce a shared renderer or declarative UI DSL.
4. [Characterization-protected maintainability work](https://github.com/turinglambdaai/rivet/issues/185)
   extracts only genuinely shared backend behavior and splits oversized service
   modules after their externally visible behavior is locked down by tests.

## Graduation rules

- A checklist item is complete only when its evidence runs on the platform it
  claims to cover. Structural inspection is valuable, but it is not a substitute
  for a real package-manager or desktop-session transaction.
- CI failures must retain bounded diagnostics and enough version information to
  reproduce the environment.
- Platform-native UI and services stay in their platform adapters. Racket owns
  application logic, schema, and portable orchestration; it does not become a
  cross-platform widget abstraction.
- Refactors must preserve protocol golden tests, fuzzing, embedded round trips,
  package verification, and public contracts. Large rewrites do not qualify as
  maintainability progress merely because they reduce line count.
- Mobile application delivery and the authenticated network companion channel
  follow desktop production graduation. Their foundations continue to be tested,
  but they do not dilute the 0.7 exit criteria.

## Evidence versus credentials

Rivet can automate production signing and verification, but publisher-owned
certificates, Apple notarization credentials, and repository signing keys must
remain outside the source tree. Applications should run credential-backed canary
releases in protected CI environments; ordinary pull-request CI continues to
exercise deterministic development and negative credential-validation paths.
