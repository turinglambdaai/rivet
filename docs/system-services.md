# System services

Commercial desktop features live in `rivet/system` and native platform adapters, not in RVT1. This boundary keeps the embedded transport small and makes UI-thread and lifecycle ownership explicit.

## Shared API

`rivet/system` exports single-instance acquisition and activation routing, system notifications, tray/menu-bar configuration, login/autostart control, secure binary secret storage, atomic JSON settings, structured logging, and provider-neutral crash-reporting hooks.

Native hosts install a `system-adapter` at startup. Headless tests can install an in-memory adapter. Calling an unavailable capability fails clearly instead of silently using insecure storage or a fake notification.

## Windows

`platform/windows/system` uses first-party Win32 surfaces:

- named mutexes for process uniqueness;
- command-line activation for URL schemes and file associations registered by MSI;
- `Shell_NotifyIconW` for tray presence and notification balloons;
- the current user's `Run` registry value for opt-in autostart;
- Windows Credential Manager (`CredWriteW`/`CredReadW`) for secrets;
- `SetUnhandledExceptionFilter` and `RegisterApplicationRestart` as low-level crash/restart hooks.

The host owns the window handle and receives tray callbacks on its WinUI thread. Applications can replace the built-in crash callback with Crashpad, Sentry, a private endpoint, or no uploader; Rivet does not bind to any provider.

## macOS

`RivetSystem` uses AppKit and Apple system frameworks:

- an OS file lock automatically released on process death;
- SwiftUI `onOpenURL` plus packaged `CFBundleURLTypes`/`CFBundleDocumentTypes` metadata;
- `UNUserNotificationCenter`;
- `NSStatusItem` for menu-bar UI;
- `SMAppService.mainApp` for login-item registration;
- Security.framework Keychain generic-password items;
- an activation router that stays on the main actor.

macOS asks the user for notification and login-item consent as required by the OS. Code must not treat denial as a crash.

`UserNotifications` is available only to a packaged `.app` with an application identifier. `RivetNotifications.isAvailable` reports whether the running process has that identity. Development executables such as `.rivet/stage/RivetHost` therefore return `false` from `requestAuthorization()` and `show(...)` throws the catchable `RivetSystemError.notificationsUnavailable`, instead of entering `UNUserNotificationCenter` and triggering an Objective-C exception.

## Linux

`platform/linux/system` uses first-party Linux desktop surfaces, selected for the same independence rules as the other platforms:

- an abstract-namespace Unix socket for the single-instance lease; secondaries forward their activation arguments to the primary over that socket;
- `ActivationArguments()` from `/proc/self/cmdline` for URL-scheme and file-association payloads registered by installers;
- `org.freedesktop.Notifications` over the session bus (GDBus), with stable notification ids for tagged replacements;
- XDG autostart entries under `$XDG_CONFIG_HOME/autostart`;
- the Secret Service provider (GNOME Keyring, KWallet bridge) through libsecret for binary secrets; the capability is compiled in when libsecret is present and reported at runtime only when a provider is reachable;
- `sigaction` fatal-signal hooks that append a preformatted note (signal number plus restart arguments) to a file under the XDG state directory.

`rivet::system::Capabilities()` reports what the running session actually provides; a missing session bus, Secret Service provider, or libsecret build fails clearly at call time instead of silently degrading. The tray contract is deliberately absent: StatusNotifierItem hosting is compositor-dependent (GNOME hosts it only through an extension), so tray presence must be an explicit application decision rather than an adapter default.

The Linux integration binary self-checks the adapter (`RivetIntegration --system`): lease acquisition and activation forwarding, autostart entries, and the crash hook always run; notification and secure-storage checks skip themselves when the session lacks those services.

## Settings, logs, and crashes

`make-settings-store` reads a JSON object and writes updates through an atomic replacement under a semaphore. The application chooses the path, normally its platform Application Support/AppData directory (on Linux, a file under the XDG state or config directories). Secrets do not belong in settings; use secure storage.

`rivet-log` emits structured records to `current-rivet-log-sink`. `call-with-crash-reporting` records an escaping Racket exception and invokes `current-rivet-crash-reporter` before re-raising it. Native fatal hooks are deliberately minimal: crash handlers must avoid allocations and network access, then let a helper submit the report on the next launch.
