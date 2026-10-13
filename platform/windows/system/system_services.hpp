#pragma once

#include <windows.h>
#include <microsoft.ui.xaml.window.h>
#include <winrt/Microsoft.UI.Xaml.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace rivet::system {

// Official WinUI 3 desktop interop bridge. This avoids title-based
// FindWindowW lookups and centralizes the raw App SDK ABI header required by
// RegisterHotKey, SetWindowSubclass, clipboard listeners, tray icons, and
// other HWND-owned platform features. Call only after InitializeComponent.
template <typename Window>
[[nodiscard]] HWND NativeWindowHandle(Window const& window) {
  auto native = window.template try_as<::IWindowNative>();
  if (!native) winrt::check_hresult(E_NOINTERFACE);
  HWND handle{};
  winrt::check_hresult(native->get_WindowHandle(&handle));
  if (handle == nullptr) winrt::check_hresult(E_HANDLE);
  return handle;
}

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
// callback_message for tray activation and must stay on the WinUI UI thread;
// the application intercepts callback_message (SetWindowSubclass) and also
// forwards the TaskbarCreated broadcast to Readd() so the icon survives an
// Explorer restart.
class TrayIcon final {
 public:
  TrayIcon(HWND window, UINT identifier, UINT callback_message,
           std::wstring const& tooltip, HICON icon);
  ~TrayIcon();
  TrayIcon(TrayIcon const&) = delete;
  TrayIcon& operator=(TrayIcon const&) = delete;

  // The constructor copies `icon`; the caller retains ownership of its input
  // handle and may release it immediately after construction.
  // State labels change with the application (running/paused, today's
  // totals); NIM_MODIFY with NIF_TIP, no re-add needed.
  void SetTooltip(std::wstring const& tooltip);
  // TaskbarCreated handler: NIM_DELETE + NIM_ADD with the stored payload.
  // Cheap enough to call unconditionally from the broadcast path.
  void Readd();
  void Notify(std::wstring const& title, std::wstring const& body) const;

 private:
  void Add();

  HWND window_{};
  UINT identifier_{};
  UINT callback_message_{};
  std::wstring tooltip_;
  HICON icon_{};
};

// One native popup-menu entry. Command identifiers must be unique, non-zero,
// and fit in the low word of WM_COMMAND. Labels and callbacks stay owned by
// the application so localization and business actions do not cross RVT1.
struct TrayMenuItem final {
  enum class Type { item, separator };

  TrayMenuItem() = default;
  TrayMenuItem(UINT identifier, std::wstring label,
               std::function<void()> activated, bool enabled = true,
               bool checked = false);
  explicit TrayMenuItem(Type type) : type(type) {}

  Type type = Type::item;
  UINT identifier{};
  std::wstring label;
  bool enabled = true;
  bool checked = false;
  std::function<void()> activated;
};

// High-level, UI-thread-owned tray host. It installs and removes the HWND
// subclass, re-adds the icon after Explorer broadcasts TaskbarCreated, opens
// a dismissible native popup menu, and routes WM_COMMAND to app callbacks.
// Destroy this object before destroying the HWND. Callback exceptions are
// contained at the Win32 boundary and reported to the debugger.
class TrayController final {
 public:
  TrayController(HWND window, UINT identifier, UINT callback_message,
                 std::wstring const& tooltip, HICON icon,
                 std::vector<TrayMenuItem> menu = {},
                 std::function<void()> activated = {});
  ~TrayController();
  TrayController(TrayController const&) = delete;
  TrayController& operator=(TrayController const&) = delete;

  void SetMenu(std::vector<TrayMenuItem> menu);
  void SetActivationHandler(std::function<void()> activated);
  void SetTooltip(std::wstring const& tooltip);
  void Notify(std::wstring const& title, std::wstring const& body) const;

 private:
  static LRESULT CALLBACK WindowSubclass(HWND window, UINT message,
                                         WPARAM w_param, LPARAM l_param,
                                         UINT_PTR subclass_id,
                                         DWORD_PTR reference_data) noexcept;
  LRESULT HandleMessage(UINT message, WPARAM w_param, LPARAM l_param) noexcept;
  void ShowMenu();
  bool DispatchCommand(UINT identifier);
  static void ReportCallbackFailure() noexcept;

  HWND window_{};
  UINT identifier_{};
  UINT callback_message_{};
  UINT taskbar_created_message_{};
  UINT_PTR subclass_id_{};
  std::unique_ptr<TrayIcon> icon_;
  std::vector<TrayMenuItem> menu_;
  std::function<void()> activated_;
};

using CrashCallback = void (*)(EXCEPTION_POINTERS const*) noexcept;
void InstallCrashHook(CrashCallback callback,
                      std::wstring const& restart_arguments = L"");

// Mirrors the Linux adapter's InstallShutdownHook: the callback runs on a
// console-control thread for CTRL_C_EVENT, CTRL_CLOSE_EVENT, CTRL_LOGOFF_
// EVENT, and CTRL_SHUTDOWN_EVENT (session logoff and OS shutdown reach GUI
// processes without a console through the last two). Keep it synchronous
// and allocation-light — the OS terminates the process shortly after the
// handler returns TRUE — and touch only thread-safe state such as the
// backend's stop(). Throws std::system_error when the handler cannot be
// registered.
void InstallShutdownHook(std::function<void()> callback);

// Windows delivers URL scheme and file-association activations through the
// process command line for unpackaged/MSI apps. Registration belongs to the
// installer; this helper normalizes the received payload for application code.
std::vector<std::wstring> ActivationArguments();

// Cross-platform global-shortcut parity with the Linux XDG-portal adapter
// and the macOS Carbon adapter: one activation callback carrying the
// shortcut id, a platform timestamp in milliseconds, and an empty
// activation token (portal-only field, kept for signature parity).
struct GlobalShortcutActivation final {
  std::string shortcut_id;
  std::uint64_t timestamp{};
};

// RegisterHotKey-based global shortcuts on a message-only window. Linux
// binds through a compositor prompt because Wayland has no global grabs;
// Windows permits direct registration, so this class exposes explicit
// Register/Unregister calls. Create, register, unregister, and destroy on
// one thread; that thread must pump messages for activations to arrive.
// The activation handler runs on that same thread.
class GlobalShortcuts final {
 public:
  using ActivationHandler =
      std::function<void(std::string const& shortcut_id,
                         std::uint64_t timestamp,
                         std::string const& activation_token)>;

  static bool available();

  GlobalShortcuts();
  ~GlobalShortcuts();
  GlobalShortcuts(GlobalShortcuts const&) = delete;
  GlobalShortcuts& operator=(GlobalShortcuts const&) = delete;

  // `trigger` grammar (case-insensitive, '+'-separated, exactly one key):
  // modifiers ctrl|control, alt|option, shift, win|meta|super|cmd|command;
  // keys a-z, 0-9, f1-f24, space, tab, enter|return, escape|esc, backspace,
  // delete|del, insert, home, end, pageup, pagedown, up, down, left, right,
  // comma, period, slash, backslash, semicolon, quote, minus, equal,
  // bracketleft, bracketright. Returns false for an unknown token, a
  // missing key, or more than one key.
  [[nodiscard]] static bool ParseTrigger(std::string const& trigger,
                                         std::uint32_t& modifiers,
                                         std::uint32_t& virtual_key);

  [[nodiscard]] bool Register(std::string const& shortcut_id,
                              std::string const& trigger);
  bool Unregister(std::string const& shortcut_id);

  void SetActivationHandler(ActivationHandler handler);

 private:
  static LRESULT CALLBACK WndProc(HWND window, UINT message, WPARAM wparam,
                                  LPARAM lparam) noexcept;

  HWND window_{};
  std::uint32_t next_hotkey_id_{1};
  std::vector<std::pair<std::uint32_t, std::string>> registered_;
  ActivationHandler handler_;
};

}  // namespace rivet::system
