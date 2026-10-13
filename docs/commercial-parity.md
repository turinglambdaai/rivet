# Commercial parity baseline

Rivet is held to commercial desktop-framework standards: what Tauri 2 and
Electron ship is the floor, never the ceiling. This page is the honest
scorecard, maintained with the same anti-rot discipline as the rest of the
documentation — update it whenever a capability is added, and treat any
"below floor" row as an open work item with priority over new surface area.

Statuses: **above** (differentiating), **at** (floor met), **below**
(open gap), **roadmap** (deliberately scheduled, not accidental).

## Scorecard

| Capability | Tauri 2 / Electron floor | Rivet status |
| --- | --- | --- |
| App foundation | WebView-based UI layer | **above** — native SwiftUI/WinUI/GTK hosts, no WebView: ~30 MB artifacts, native startup and accessibility from the platform toolkits |
| IPC discipline | `invoke` string commands / `ipcRenderer` channels | **above** — RVT1 typed RPC/event/state contracts with generated Swift, C++, and Kotlin clients and a closed schema |
| In-app updates | updater plugin / electron-updater, signed feeds | **at** — Ed25519-signed manifests, verify-before-parse, managed watchdogs, install journal + recovery, AppImage atomic replacement, and a shared macOS host client (`RivetUpdate`); no delta downloads (Tauri 2 has none either) |
| Installers | dmg, NSIS/MSI, deb/rpm/AppImage | **at** — DMG, MSI, deb, rpm, AppImage, portable archives, SBOM and third-party notices per release |
| Single instance / deep links | plugins or manual | **at** — lease per platform, activation routing, `--toggle`-style second-instance handoff |
| Autostart, tray, notifications, secure storage, crash hooks | plugins / Node APIs | **at** — first-party adapters on every desktop platform, capability-reported, fail-closed without a provider |
| Global shortcuts | global-shortcut plugin, direct registration | **at** — Linux through the XDG portal (the compositor owns the trigger), macOS Carbon `RegisterEventHotKey` and Windows `RegisterHotKey` with a shared trigger grammar and activation-callback shape |
| Accessibility | not exercised by their CI | **above** — accessibility-tree end-to-end suites on all three desktop platforms in CI, plus protocol fuzzing |
| Docs discipline | versioned docs site | **partial** — full API-reference coverage with two-way drift guards in CI (exports ↔ manual, guide pins ↔ release version); a versioned docs site and zh-CN pairs for newer pages remain **roadmap** |
| Project templates | create-tauri-app gallery | **partial** — `raco rivet new` starter plus the reference Taskboard; a template gallery is **roadmap** |
| Clipboard read/write/watch | clipboard-manager plugin | **at** — first-party plain-text read/write/change observation through NSPasteboard, Win32 CF_UNICODETEXT, and GTK4/GDK (async under Wayland) |
| Native file dialogs | dialog plugin | **below** — no adapter yet; open work item |
| Mobile hosts | iOS and Android (Tauri 2) | **roadmap** — gated on the family's Rivet Phase 8 mobile-host decision, recorded per product |
| Delta updates | Electron blockmap (Electron only) | **roadmap** — full-artifact updates first; revisit when artifact sizes make deltas worth their complexity |

## Rules of engagement

- A product hand-rolling the same capability twice is a library gap by
  definition; upstream it (precedents: tray, Wayland shortcuts, the macOS
  update client).
- New capabilities enter this table in the same change that adds them, with
  an honest status — the docs suite links this page so it cannot silently
  disappear.
- Below-floor rows outrank new surface area in planning.
