# System services

Commercial desktop features live in `rivet/system` and native platform adapters, not in RVT1. This boundary keeps the embedded transport small and makes UI-thread and lifecycle ownership explicit.

## Shared API

`rivet/system` exports single-instance acquisition and activation routing, system notifications, tray/menu-bar configuration, login/autostart control, secure binary secret storage, atomic JSON settings, structured logging, and provider-neutral crash-reporting hooks.

Generated native hosts call the first-party Swift/C++ system libraries directly, on the native UI or lifecycle thread that owns the operation. They do not install Racket procedures into the embedded runtime and system services do not extend RVT1. Racket-side providers and headless tests can parameterize `current-system-adapter`; without such a provider, the Racket convenience procedures fail clearly instead of silently using insecure storage or a fake notification.

## Windows

`platform/windows/system` uses first-party Win32 surfaces:

- named mutexes for process uniqueness;
- command-line activation for URL schemes and file associations registered by MSI;
- `Shell_NotifyIconW` for tray presence and notification balloons, plus a
  `TrayController` that owns the window subclass, native popup menu, command
  routing, and `TaskbarCreated` recovery;
- the current user's `Run` registry value for opt-in autostart;
- Windows Credential Manager (`CredWriteW`/`CredReadW`) for secrets;
- `SetUnhandledExceptionFilter` and `RegisterApplicationRestart` as low-level crash/restart hooks.

The host owns the window handle and receives tray callbacks on its WinUI thread.
Use the low-level `TrayIcon` only when a host deliberately owns all message
routing. Normal tray-resident hosts use `TrayController`: pass localized
`TrayMenuItem` labels and application callbacks, and destroy the controller
before its `HWND`. The controller installs and removes `SetWindowSubclass`,
restores the icon after Explorer restarts, calls `SetForegroundWindow` before
`TrackPopupMenu` so outside clicks dismiss the popup, and routes only its own
menu command identifiers. Callback exceptions never unwind through the Win32
message procedure. The reference Taskboard is the executable recipe.

Applications can replace the built-in crash callback with Crashpad, Sentry, a
private endpoint, or no uploader; Rivet does not bind to any provider.

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
- `GlobalShortcuts` — the asynchronous `org.freedesktop.portal.GlobalShortcuts` session API. `support()` exposes the portal version, `bind(...)` reports bound, cancelled, unavailable, and failed outcomes without blocking GTK's main context, and activation callbacks preserve the compositor timestamp and activation token. The compositor owns the final shortcut and may replace or reject an application's preferred trigger. Rivet does not fall back to `XGrabKey`; applications on a session without this portal can expose their existing single-instance activation command (for example, an executable `--toggle` action) for the user to bind in compositor settings;
- `TrayIcon` — org.kde.StatusNotifierItem plus a com.canonical.dbusmenu menu, through the session bus (GDBus). This is an explicit opt-in, not an adapter default: desktop hosting is compositor-dependent (GNOME hosts it only through the AppIndicator extension, KDE natively), so the application checks `TrayIcon::available()` (or the `tray` capability) and decides. The icon, tooltip, and flat menu (labelled items, separators, enabled state) update in place; the watcher is re-registered whenever it reappears, so GNOME Shell restarts and extension reloads do not strand a running process without its icon. Methods and menu callbacks run on the thread-default main context the icon was constructed on — for GTK hosts, the main-loop thread;
- XDG autostart entries under `$XDG_CONFIG_HOME/autostart`;
- the Secret Service provider (GNOME Keyring, KWallet bridge) through libsecret for binary secrets; the capability is compiled in when libsecret is present and reported at runtime only when a provider is reachable;
- `sigaction` fatal-signal hooks that append a preformatted note (signal number plus restart arguments) to a file under the XDG state directory.

`rivet::system::Capabilities()` reports what the running session actually provides; a missing session bus, Secret Service provider, or libsecret build fails clearly at call time instead of silently degrading.

Install `rivet::system::InstallShutdownHook` only after the embedded backend's
`start()` has completed its Hello handshake. `racket_boot` establishes Racket
CS signal handling during startup; installing the application hook earlier
would let that initialization replace it, turning `SIGTERM` into a backend
break while the GTK main loop remains alive. Generated hosts and the reference
Taskboard enforce this ordering and the deb lifecycle gate sends a real
`SIGTERM` to the installed application.

The Linux integration binary self-checks the adapter (`RivetIntegration --system`): lease acquisition and activation forwarding, autostart entries, and the crash hook always run; notification, tray, and secure-storage checks skip themselves when the session lacks those services. A separate hermetic test starts a private D-Bus session and mock GlobalShortcuts portal, then verifies discovery, session creation, binding results, and activation delivery without depending on a particular CI desktop.

## Settings, logs, and crashes

`make-settings-store` returns an opaque handle that reads a JSON object and writes updates through an atomic replacement under a shared in-process semaphore and operating-system file lock. Operations refresh inside the transaction, so multiple handles and cooperating processes do not overwrite one another from stale caches. Snapshots and stored JSON trees are deeply immutable; callers cannot mutate cached state around synchronization. The persistent empty `.lock` sibling carries no transaction state. Use `settings-ref`, `settings-set!`, `settings-remove!`, and `settings-snapshot`. The application chooses the path, normally its platform Application Support/AppData directory (on Linux, a file under the XDG state or config directories). Secrets do not belong in settings; use secure storage.

`rivet-log` emits structured records to `current-rivet-log-sink`. `call-with-crash-reporting` records an escaping Racket exception and invokes `current-rivet-crash-reporter` before re-raising it. Native fatal hooks are deliberately minimal: crash handlers must avoid allocations and network access, then let a helper submit the report on the next launch.
