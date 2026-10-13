# System services

Commercial desktop features live in `rivet/system` and native platform adapters, not in RVT1. This boundary keeps the embedded transport small and makes UI-thread and lifecycle ownership explicit.

## Shared API

`rivet/system` exports single-instance acquisition and activation routing, system notifications, tray/menu-bar configuration, login/autostart control, secure binary secret storage, atomic JSON settings, structured logging, and provider-neutral crash-reporting hooks.

Generated native hosts call the first-party Swift/C++ system libraries directly, on the native UI or lifecycle thread that owns the operation. They do not install Racket procedures into the embedded runtime and system services do not extend RVT1. Racket-side providers and headless tests can parameterize `current-system-adapter`; without such a provider, the Racket convenience procedures fail clearly instead of silently using insecure storage or a fake notification.

### Global shortcuts across platforms

Every adapter reports activations through the same callback shape — shortcut id, platform timestamp in milliseconds, and an activation token (portal platforms only; empty elsewhere) — so hosts share one dispatch path. Direct-registration platforms (macOS, Windows) use a shared trigger grammar: case-insensitive `'+'`-separated modifiers (`ctrl|control`, `alt|option`, `shift`, `cmd|command|meta|super|win`) and exactly one key (`a`–`z`, `0`–`9`, `f1`–`f24`, `space`, `tab`, `enter|return`, `escape|esc`, `backspace`, `delete|del`, `insert`, `home`, `end`, `pageup`, `pagedown`, arrows, and common punctuation names). Both adapters refuse duplicate ids and duplicate live triggers. Linux intentionally differs: Wayland has no global grabs, so binding goes through the compositor's portal prompt and the compositor owns the final trigger.

### Clipboard across platforms

The native adapter contract is deliberately plain text: read the newest text, replace the clipboard with text, and observe ownership/content changes. Embedded NUL characters are rejected because the Win32 and GTK representations are NUL-terminated. A change callback receives no value when the clipboard has no text representation. Native objects belong to the UI thread that created them; observation stops when the object is destroyed.

Linux reads asynchronously because Wayland transfers clipboard content from the current owner on demand. Its callback therefore also carries an error string, separating “not text” from a failed transfer. Windows and macOS reads are synchronous platform calls. Changes faster than the observer can consume may be coalesced; this is a state notification, not a lossless history stream.

### Native file dialogs across platforms

Every desktop adapter exposes first-party open, save, and folder-selection dialogs with filename-extension filters and optional open-file multi-selection. Cancellation is a normal empty result; actual platform or transfer failures remain distinguishable. Dialogs belong to the UI thread and may be parented to the native application window.

The adapters return local filesystem paths only. Windows uses the Common Item Dialog (`IFileOpenDialog` / `IFileSaveDialog`), macOS uses asynchronous `NSOpenPanel` / `NSSavePanel`, and Linux uses `GtkFileChooserNative`, which delegates to the desktop portal when available. Linux reports a clear error if a provider returns a non-local resource instead of pretending its URI is a filesystem path.

## Windows

`platform/windows/system` uses first-party Win32 surfaces:

- named mutexes for process uniqueness;
- command-line activation for URL schemes and file associations registered by MSI;
- `Shell_NotifyIconW` for tray presence and notification balloons, plus a
  `TrayController` that owns the window subclass, native popup menu, command
  routing, and `TaskbarCreated` recovery;
- `GlobalShortcuts` on `RegisterHotKey`: a message-only window per instance
  with `WM_HOTKEY` dispatch to the shared activation-callback shape.
  `ParseTrigger` implements the cross-platform trigger grammar; register and
  unregister on the thread that pumps the window's messages (the WinUI
  thread in generated hosts);
- `Clipboard` on `CF_UNICODETEXT`, with a message-only owner window and
  `AddClipboardFormatListener` / `WM_CLIPBOARDUPDATE` observation;
- `FileDialogs` on the Common Item Dialog, including open-file multi-select,
  folder selection, save suggestions, and extension filters;
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
- `RivetGlobalShortcuts` on Carbon `RegisterEventHotKey`: direct registration
  with the shared trigger grammar and callback shape, activations on the
  main thread's event loop. `parse(_:)` maps ANSI virtual-key codes through
  their Carbon constants — the codes follow the physical QWERTY layout, not
  the alphabet — and is public for tests and trigger rendering;
- `RivetClipboard` on `NSPasteboard`, with `changeCount` polling on the main
  run loop (AppKit publishes no pasteboard-change notification);
- `RivetFileDialogs` on asynchronous AppKit open/save panels, optionally
  presented as a sheet for a supplied `NSWindow`;
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
- `Clipboard` — GTK4/GDK text read, write, and `changed` observation on the
  host's GTK main context; capability discovery reports it only after an
  interactive display is initialized;
- `FileDialogs` — GTK4 native open/save/folder choosers with portal delegation,
  filters, multi-select, and asynchronous completion on the main context;
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
