#pragma once

#include <windows.h>

#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <vector>

namespace rivet::system {

class SingleInstanceLease final {
 public:
  explicit SingleInstanceLease(std::wstring const& application_id);
  ~SingleInstanceLease();
  SingleInstanceLease(SingleInstanceLease const&) = delete;
  SingleInstanceLease& operator=(SingleInstanceLease const&) = delete;

  [[nodiscard]] bool is_primary() const noexcept { return primary_; }

 private:
  HANDLE mutex_{nullptr};
  bool primary_{false};
};

class CredentialStore final {
 public:
  static void Set(std::wstring const& service, std::wstring const& account,
                  std::vector<std::uint8_t> const& secret);
  static std::optional<std::vector<std::uint8_t>> Get(
      std::wstring const& service, std::wstring const& account);
  static void Remove(std::wstring const& service,
                     std::wstring const& account);
};

class Autostart final {
 public:
  static bool Enabled(std::wstring const& application_id);
  static void SetEnabled(std::wstring const& application_id,
                         std::wstring const& executable, bool enabled);
};

// Uses the first-party Shell_NotifyIcon surface. The owning HWND receives
// callback_message for tray activation and must stay on the WinUI UI thread.
class TrayIcon final {
 public:
  TrayIcon(HWND window, UINT identifier, UINT callback_message,
           std::wstring const& tooltip, HICON icon);
  ~TrayIcon();
  TrayIcon(TrayIcon const&) = delete;
  TrayIcon& operator=(TrayIcon const&) = delete;

  void Notify(std::wstring const& title, std::wstring const& body) const;

 private:
  HWND window_{};
  UINT identifier_{};
};

using CrashCallback = void (*)(EXCEPTION_POINTERS const*) noexcept;
void InstallCrashHook(CrashCallback callback,
                      std::wstring const& restart_arguments = L"");

// Windows delivers URL scheme and file-association activations through the
// process command line for unpackaged/MSI apps. Registration belongs to the
// installer; this helper normalizes the received payload for application code.
std::vector<std::wstring> ActivationArguments();

}  // namespace rivet::system
