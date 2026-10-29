# Apple release readiness — channel-specific checks

**English** · [简体中文](apple-release-readiness.zh-CN.md)

Rivet cannot guarantee Apple approval or review speed. This is a framework
preflight and product handoff—not an App Store or notarization certificate.
Re-read [Apple's current rules](https://developer.apple.com/app-store/review/guidelines/) before submission.

## Choose the channel before packaging

| Channel | Framework maturity | Required next gate |
| --- | --- | --- |
| macOS website (Developer ID) | Developer ID signing, notarization, stapling and Gatekeeper verification implemented | Publisher-credential-backed canary, clean installation, update and recovery on physical hardware |
| Mac App Store | First-party SwiftUI/AppKit desktop host; **no qualified Mac App Store archive/submission path** | Xcode/Store signing, App Sandbox, Store updates, StoreKit where required and real Store installation |
| iOS/iPadOS App Store | Companion and portable runtime foundations; **no generated signed standalone app** | JIT-free Release/device embedding, prebundled app code, signing, sandbox, lifecycle and Store submission |
| watchOS | WatchConnectivity relay and a SwiftUI foundation | Product watch app, device pairing, packaging, signing and review |

The portfolio's current Mac default is Developer ID direct distribution,
not a silent switch to Mac App Store. See
[distribution policy](https://github.com/turlamai/turlamai.github.io/blob/master/docs/DISTRIBUTION.md)
and Rivet [production signing](production-signing.md).

## Run the artifact preflight

From the Rivet repository checkout after building the actual macOS .app:

```bash
python3 .github/scripts/apple-review-preflight.py --channel developer-id --app dist/MyApp.app --json
# Mac App Store is an experimental classification, NOT a signed Store archive:
python3 .github/scripts/apple-review-preflight.py --channel mac-app-store --app dist/MyApp.app --json
python3 .github/scripts/test-apple-review-preflight.py
```

The read-only script needs no publisher credentials. It checks Info.plist,
the app executable, bundle identifier, basic privacy-manifest structure, and
(on macOS) effective code signature, signed entitlements, sandbox/debug flags,
and risky hardened-runtime exceptions. It does **not** approve SDK usage,
privacy reasons, revenue model, runtime behavior, Store upload or user experience.

The JSON schema is `rivet.apple-review-preflight.v1`, with `blockers`,
`warnings`, `unverified`, `manual_review` and `status`. Exit 0 means only
that automated checks passed; exit 1 means observed blockers; exit 2 means
missing essential platform evidence. Neither exit 0 nor a valid manifest
guarantees Apple review approval. For an actual Developer ID release also
run `raco rivet verify --production` to verify stapling and Gatekeeper.

## Shared Rivet responsibility

- Precompile and bundle executable application modules and signed dependencies.
  Do not download source, bytecode or plug-ins to add functionality after
  review; review [Guideline 2.5.2](https://developer.apple.com/app-store/review/guidelines/#software-requirements).
- Prove embedded Racket works in **iOS Release builds on physical hardware**
  without prohibited JIT or executable-memory behavior. A macOS SwiftPM
  compilation or iOS companion transport test is not that evidence.
- Keep separate signing and update paths for Developer ID, Mac App Store and
  iOS. A standalone updater or Permit license-key screen must not silently
  ship into a Mac App Store build.
- Make entitlements, container file locations, permission failures, privacy
  resources, bundled dependencies, native accessibility and lifecycle visible
  to the product's acceptance suite. Default to minimum OS privileges.

## Application owner responsibility

The product must inventory APIs/SDKs and required-reason privacy disclosures,
provide truthful app privacy labels and policy links, test native permissions,
data deletion, update recovery, login, localization, IAP and purchase restores
where relevant. Supply App Store Connect with working demo credentials or
demonstration mode, reachable services, screenshots, tested device versions
and review notes. Hardware-specific apps may need on-device video evidence.
Apple's [submission guide](https://developer.apple.com/help/app-review/before-submitting-for-review/complete-review/)
explains what to provide.

Digital feature unlocks must follow [Apple's payment rules](https://developer.apple.com/app-store/review/guidelines/#business)
and applicable exceptions; Rivet does not own StoreKit or commercial policy.
Missing on-device and Store-distribution evidence means **not ready**.
See the active [desktop/mobile plan](desktop-closeout-mobile-plan.md).
