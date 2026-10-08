#pragma once

// First-party Linux system adapter, mirroring platform/windows/system and
// the macOS RivetSystem package. Applications reach these classes from host
// code; headless tests drive the same surfaces. Every capability reports
// itself through Capabilities() so a missing desktop service (a session bus,
// a Secret Service provider, or a libsecret build) fails clearly instead of
// silently degrading.

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace rivet::system {

// Runtime capability names, matching the Racket system-adapter contract:
// single-instance, notification, tray, autostart, secure-storage, crash-hook.
// The tray capability reflects a reachable session bus with a
// StatusNotifierItem watcher (a compositor service: GNOME hosts it through
// the AppIndicator extension, KDE natively), so tray presence stays an
// explicit application decision rather than a silent adapter default.
std::vector<std::string> Capabilities();

// Command-line activation payload (URL schemes and file associations
// registered by installers). Mirrors the Windows helper of the same name.
std::vector<std::string> ActivationArguments();

class SingleInstanceLease final {
 public:
  using ActivationHandler = std::function<void(std::vector<std::string>)>;

  explicit SingleInstanceLease(std::string const& application_id);
  ~SingleInstanceLease();
  SingleInstanceLease(SingleInstanceLease const&) = delete;
  SingleInstanceLease& operator=(SingleInstanceLease const&) = delete;

  [[nodiscard]] bool is_primary() const noexcept { return primary_; }

  // Secondary side: deliver arguments to the primary instance. Returns false
  // when the primary could not be reached, so the caller can decide to keep
  // running anyway.
  bool forward_arguments(std::vector<std::string> const& arguments) const;

  // Primary side: watch for forwarded activations and dispatch each payload
  // on the lease's watcher thread. Activations are handled one at a time.
  void set_activation_handler(ActivationHandler handler);

 private:
  std::string application_id_;
  int socket_fd_{-1};
  int wakeup_fd_{-1};
  bool primary_{false};
  std::thread watcher_;
  std::atomic<bool> watching_{false};
};

// Secret Service provider (GNOME Keyring, KWallet bridge) through libsecret.
// Compiled only when libsecret was found at build time; check Capabilities().
class SecretStore final {
 public:
  static void Set(std::string const& service, std::string const& account,
                  std::vector<std::uint8_t> const& secret);
  static std::optional<std::vector<std::uint8_t>> Get(
      std::string const& service, std::string const& account);
  static void Remove(std::string const& service, std::string const& account);
};

// XDG autostart entries under $XDG_CONFIG_HOME/autostart.
class Autostart final {
 public:
  static bool Enabled(std::string const& application_id);
  static void SetEnabled(std::string const& application_id,
                         std::string const& executable, bool enabled);
};

// org.freedesktop.Notifications through the session bus (GDBus).
class Notifications final {
 public:
  static bool available();

  // A non-empty tag replaces the tagged notification (the id stays stable);
  // an empty tag posts a new notification. Returns the notification id.
  static std::uint32_t Notify(std::string const& application_name,
                              std::string const& tag,
                              std::string const& title,
                              std::string const& body);
  static void Close(std::uint32_t id);
  static void CloseTag(std::string const& tag);
};

// One StatusNotifierItem menu entry: a labelled, optionally disabled item
// with a click callback, or a separator. Callbacks run on the
// thread-default main context TrayIcon was constructed on — for GTK hosts,
// the main-loop thread.
struct TrayMenuItem final {
  enum class Type { item, separator };

  TrayMenuItem() = default;
  TrayMenuItem(std::string label, std::function<void()> activated,
               bool enabled = true);
  explicit TrayMenuItem(Type type) : type(type) {}

  Type type = Type::item;
  std::string label;
  bool enabled = true;
  std::function<void()> activated;
};

// org.kde.StatusNotifierItem with a com.canonical.dbusmenu menu, through the
// session bus (GDBus). This is the Linux counterpart of the Windows
// Shell_NotifyIcon adapter: an explicit opt-in — check available() (or the
// "tray" capability) and construct only when a StatusNotifierItem watcher is
// running, since desktop hosting is compositor-dependent. Methods must be
// called from the thread-default main context the icon was constructed on;
// GTK hosts satisfy this with their main loop.
class TrayIcon final {
 public:
  // True when the session bus has a StatusNotifierItem watcher to register
  // with. False without a session bus — same contract as Notifications.
  static bool available();

  TrayIcon(std::string const& application_id, std::string const& title,
           std::string const& icon_name);
  ~TrayIcon();
  TrayIcon(TrayIcon const&) = delete;
  TrayIcon& operator=(TrayIcon const&) = delete;

  // Themed icon name (installed icon theme entry, e.g. "syncpilot").
  void set_icon(std::string const& icon_name);
  void set_tooltip(std::string const& title, std::string const& body);
  // Replaces the whole menu and bumps the layout revision. Item callbacks
  // are invoked on the main context when the watcher reports a click.
  void set_menu(std::vector<TrayMenuItem> items);
  // Left-click / Activate handling where the watcher supports it (KDE; the
  // GNOME AppIndicator extension opens the menu instead).
  void set_activation_handler(std::function<void()> handler);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

// POSIX fatal-signal hook. The handler is async-signal-safe: it appends a
// preformatted note (signal number and restart arguments captured at install
// time) to a file under the XDG state directory, invokes the callback, and
// re-raises with the default disposition.
using CrashCallback = void (*)(int signal_number) noexcept;
void InstallCrashHook(CrashCallback callback,
                      std::string const& restart_arguments = std::string());

// SIGTERM/SIGINT shutdown plumbing (embedded runtimes install their own
// signal handlers and otherwise absorb termination requests, so hosts that
// persist state on exit never see SIGTERM). The first signal drains into a
// self-pipe; a watcher thread runs `callback` on a normal stack — state
// flushing is allowed there — and the process then exits with status 0. A
// second signal exits immediately so operators can still hard-kill a stuck
// shutdown. Install once, early, from the main thread.
void InstallShutdownHook(std::function<void()> callback);

}  // namespace rivet::system
