#pragma once

#include <filesystem>
#include <functional>
#include <optional>
#include <string>
#include <vector>

namespace rivet::update {

enum class LinuxInstallKind { appimage, package_manager, portable };

// Mirrors rivet/distribution's installation policy for GTK hosts that need to
// choose localized UI before asking the backend to download anything.
LinuxInstallKind DetectLinuxInstallKind(
    std::filesystem::path const& executable,
    char const* appimage_environment = nullptr);

// Relaunches the AppImage that rivet/distribution has already authenticated
// and atomically installed. `release_lease` runs immediately before exec so a
// single-instance guard cannot reject the new process. This call returns only
// on failure and then throws std::system_error.
[[noreturn]] void RelaunchInstalledAppImage(
    std::filesystem::path const& appimage,
    std::vector<std::string> arguments = {},
    std::function<void()> release_lease = {});

// Options carried into the generated AppImage handoff. `version` and
// `artifact_sha256` are the signed manifest's fields; they only feed the
// transaction journal so an interrupted handoff stays auditable and
// recoverable by rivet/distribution's recovery tooling. `rollback_allowed`
// mirrors the signed manifest's rollback policy: when false the handoff never
// restores the replaced AppImage and leaves the failure for the next launch
// instead.
struct AppImageHandoffOptions final {
  std::vector<std::string> relaunch_arguments;
  std::string version;
  std::string artifact_sha256;
  bool rollback_allowed = true;
  unsigned settle_seconds = 5;
};

// Process-external AppImage replacement, the Linux counterpart of
// MsiHandoff. A GTK host that exits to apply an update must not run the
// replacement itself: a crash between moving the old AppImage aside and
// moving the new one into place would leave no executable at the launch
// path, and the dead process could never run recovery itself. The handoff
// instead writes a generated first-party shell script into a
// process-specific attempt directory and detaches it, so the running process
// can simply exit after releasing its single-instance lease.
//
// The detached script waits a bounded time for the launching process to
// exit, performs the same atomic replace as
// `execute-platform-installation!` (staging copy, renamed swap, journal
// phases, idempotent rollback), relaunches the replacement, commits only
// after it survives the settle window, and restores the previous AppImage
// otherwise. Attempt directories carry a `failure.txt` marker for the next
// successful launch to consume.
class AppImageHandoff final {
 public:
  struct Failure final {
    std::string message;
  };

  // Reads and removes the newest failure marker across attempt directories,
  // or returns nullopt when no attempt failed. An empty marker reads as
  // "update-install-failed".
  static std::optional<Failure> ConsumeFailure(
      std::string const& application_id);

  // Removes attempt directories older than `max_age_hours`.
  static void CleanupStaleAttempts(std::string const& application_id,
                                   unsigned max_age_hours = 24);

  // Detaches the handoff for an AppImage update whose artifact has already
  // been authenticated and size/SHA-256 verified by the managed updater.
  // `verified_appimage` is the downloaded candidate; `target_appimage` is the
  // currently installed path (typically the APPIMAGE environment value). The
  // script waits `exit_timeout_seconds` for this process to exit, so the
  // caller must exit promptly: release the single-instance lease through
  // `release_lease` (which runs once the helper is confirmed running) and
  // return. Throws std::system_error if the helper cannot be created.
  static void LaunchReplacement(
      std::string const& application_id,
      std::filesystem::path const& verified_appimage,
      std::filesystem::path const& target_appimage,
      std::function<void()> release_lease = {},
      unsigned exit_timeout_seconds = 30,
      AppImageHandoffOptions const& options = {});
};

}  // namespace rivet::update
