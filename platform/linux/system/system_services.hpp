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
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace rivet::system {

// Runtime capability names, matching the Racket system-adapter contract:
// single-instance, notification, autostart, secure-storage, crash-hook.
// Tray is deliberately absent: the StatusNotifierItem contract is
// compositor-dependent (GNOME hosts it only through an extension), so tray
// presence must be an explicit application decision rather than a silent
// adapter default.
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

// POSIX fatal-signal hook. The handler is async-signal-safe: it appends a
// preformatted note (signal number and restart arguments captured at install
// time) to a file under the XDG state directory, invokes the callback, and
// re-raises with the default disposition.
using CrashCallback = void (*)(int signal_number) noexcept;
void InstallCrashHook(CrashCallback callback,
                      std::string const& restart_arguments = std::string());

}  // namespace rivet::system
