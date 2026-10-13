#pragma once

#include <filesystem>
#include <functional>
#include <optional>
#include <string>

namespace rivet::update {

// Last-mile Windows installer handoff for an MSI that has already passed
// Rivet's signed-manifest size/SHA-256 verification. Network and trust remain
// in rivet/distribution; this class owns the OS-specific quit -> msiexec ->
// relaunch boundary so products do not grow subtly different batch scripts.
class MsiHandoff final {
 public:
  struct Failure final {
    std::wstring message;
  };

  // Consumes the failure marker from the most recent attempt. Call once at
  // startup and localize the returned detail in the product UI.
  static std::optional<Failure> ConsumeFailure(
      std::wstring const& application_id);

  // Removes completed/crashed attempt directories older than max_age_hours.
  // The active process-specific directory is never reused.
  static void CleanupStaleAttempts(std::wstring const& application_id,
                                   unsigned max_age_hours = 24);

  // Creates and launches a detached handoff. The script waits (bounded) for
  // this PID to exit, runs `msiexec /passive /norestart`, records failure for
  // the next launch, and always relaunches the application after msiexec.
  // `release_lease` runs only after the helper process exists, immediately
  // before this method returns; use it to release single-instance ownership,
  // then terminate the current UI process. Throws std::system_error or
  // std::invalid_argument and leaves the current process running on failure.
  static void LaunchVerifiedInstaller(
      std::wstring const& application_id,
      std::filesystem::path const& verified_msi,
      std::filesystem::path const& relaunch_executable,
      std::function<void()> release_lease = {},
      unsigned exit_timeout_seconds = 30);
};

}  // namespace rivet::update
