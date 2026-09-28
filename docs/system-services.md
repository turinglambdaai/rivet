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

## Settings, logs, and crashes

`make-settings-store` reads a JSON object and writes updates through an atomic replacement under a semaphore. The application chooses the path, normally its platform Application Support/AppData directory. Secrets do not belong in settings; use secure storage.

`rivet-log` emits structured records to `current-rivet-log-sink`. `call-with-crash-reporting` records an escaping Racket exception and invokes `current-rivet-crash-reporter` before re-raising it. Native fatal hooks are deliberately minimal: crash handlers must avoid allocations and network access, then let a helper submit the report on the next launch.
