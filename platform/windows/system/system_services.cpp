#include "system_services.hpp"

#include <commctrl.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <wincred.h>

#include <algorithm>
#include <cctype>
#include <cstring>
#include <functional>
#include <limits>
#include <stdexcept>
#include <system_error>
#include <unordered_set>
#include <utility>

#pragma comment(lib, "Advapi32.lib")
#pragma comment(lib, "Comctl32.lib")
#pragma comment(lib, "Ole32.lib")
#pragma comment(lib, "Shell32.lib")
#pragma comment(lib, "User32.lib")

namespace rivet::system {
namespace {

std::wstring CredentialTarget(std::wstring const& service,
                              std::wstring const& account) {
  return L"Rivet/" + service + L"/" + account;
}

[[noreturn]] void ThrowLastError(char const* operation) {
  throw std::system_error(static_cast<int>(::GetLastError()),
                          std::system_category(), operation);
}

CrashCallback g_crash_callback = nullptr;

LONG WINAPI UnhandledFilter(EXCEPTION_POINTERS* pointers) noexcept {
  if (g_crash_callback != nullptr) g_crash_callback(pointers);
  return EXCEPTION_CONTINUE_SEARCH;
}

struct DialogFilters final {
  std::vector<std::wstring> labels;
  std::vector<std::wstring> patterns;
  std::vector<COMDLG_FILTERSPEC> specs;
};

std::wstring NormalizeExtension(std::wstring extension) {
  extension.erase(0, extension.find_first_not_of(L" \t\r\n"));
  auto const last = extension.find_last_not_of(L" \t\r\n");
  if (last == std::wstring::npos) return {};
  extension.erase(last + 1);
  if (!extension.empty() && extension.front() == L'.') extension.erase(0, 1);
  if (extension.empty() || extension.find_first_of(L"/\\*?[];") != std::wstring::npos) {
    return {};
  }
  return extension;
}

DialogFilters BuildDialogFilters(std::vector<FileDialogFilter> const& filters) {
  DialogFilters result;
  result.labels.reserve(filters.size());
  result.patterns.reserve(filters.size());
  for (auto const& filter : filters) {
    std::wstring pattern;
    for (auto extension : filter.extensions) {
      extension = NormalizeExtension(std::move(extension));
      if (extension.empty()) continue;
      if (!pattern.empty()) pattern += L';';
      pattern += L"*." + extension;
    }
    if (pattern.empty()) continue;
    result.labels.push_back(filter.label.empty() ? pattern : filter.label);
    result.patterns.push_back(std::move(pattern));
  }
  result.specs.reserve(result.labels.size());
  for (std::size_t index = 0; index < result.labels.size(); ++index) {
    result.specs.push_back({result.labels[index].c_str(),
                            result.patterns[index].c_str()});
  }
  return result;
}

template <typename Dialog>
winrt::com_ptr<Dialog> MakeFileDialog(REFCLSID class_id) {
  winrt::com_ptr<Dialog> dialog;
  winrt::check_hresult(::CoCreateInstance(
      class_id, nullptr, CLSCTX_INPROC_SERVER, __uuidof(Dialog),
      dialog.put_void()));
  return dialog;
}

std::wstring ShellItemPath(IShellItem* item) {
  PWSTR raw = nullptr;
  winrt::check_hresult(item->GetDisplayName(SIGDN_FILESYSPATH, &raw));
  std::wstring path(raw);
  ::CoTaskMemFree(raw);
  return path;
}

bool ShowDialog(IFileDialog* dialog, HWND owner) {
  HRESULT result = dialog->Show(owner);
  if (result == HRESULT_FROM_WIN32(ERROR_CANCELLED)) return false;
  winrt::check_hresult(result);
  return true;
}

}  // namespace

SingleInstanceLease::SingleInstanceLease(std::wstring const& application_id) {
  auto const name = L"Local\\Rivet." + application_id;
  mutex_ = ::CreateMutexW(nullptr, FALSE, name.c_str());
  if (mutex_ == nullptr) ThrowLastError("CreateMutexW");
  primary_ = ::GetLastError() != ERROR_ALREADY_EXISTS;
}

SingleInstanceLease::~SingleInstanceLease() {
  if (mutex_ != nullptr) ::CloseHandle(mutex_);
}

void CredentialStore::Set(std::wstring const& service,
                          std::wstring const& account,
                          std::vector<std::uint8_t> const& secret) {
  if (secret.size() > CRED_MAX_CREDENTIAL_BLOB_SIZE) {
    throw std::invalid_argument("credential exceeds Windows Credential Manager limit");
  }
  auto target = CredentialTarget(service, account);
  CREDENTIALW credential{};
  credential.Type = CRED_TYPE_GENERIC;
  credential.TargetName = target.data();
  credential.CredentialBlobSize = static_cast<DWORD>(secret.size());
  credential.CredentialBlob = const_cast<LPBYTE>(secret.data());
  credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
  credential.UserName = const_cast<wchar_t*>(account.c_str());
  if (!::CredWriteW(&credential, 0)) ThrowLastError("CredWriteW");
}

std::optional<std::vector<std::uint8_t>> CredentialStore::Get(
    std::wstring const& service, std::wstring const& account) {
  auto const target = CredentialTarget(service, account);
  PCREDENTIALW credential = nullptr;
  if (!::CredReadW(target.c_str(), CRED_TYPE_GENERIC, 0, &credential)) {
    if (::GetLastError() == ERROR_NOT_FOUND) return std::nullopt;
    ThrowLastError("CredReadW");
  }
  std::vector<std::uint8_t> result(
      credential->CredentialBlob,
      credential->CredentialBlob + credential->CredentialBlobSize);
  ::CredFree(credential);
  return result;
}

void CredentialStore::Remove(std::wstring const& service,
                             std::wstring const& account) {
  auto const target = CredentialTarget(service, account);
  if (!::CredDeleteW(target.c_str(), CRED_TYPE_GENERIC, 0) &&
      ::GetLastError() != ERROR_NOT_FOUND) {
    ThrowLastError("CredDeleteW");
  }
}

bool Autostart::Enabled(std::wstring const& application_id) {
  HKEY key{};
  if (::RegOpenKeyExW(HKEY_CURRENT_USER,
                      L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", 0,
                      KEY_QUERY_VALUE, &key) != ERROR_SUCCESS) return false;
  auto const result = ::RegQueryValueExW(key, application_id.c_str(), nullptr,
                                         nullptr, nullptr, nullptr);
  ::RegCloseKey(key);
  return result == ERROR_SUCCESS;
}

void Autostart::SetEnabled(std::wstring const& application_id,
                           std::wstring const& executable, bool enabled) {
  HKEY key{};
  if (::RegCreateKeyExW(HKEY_CURRENT_USER,
                        L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", 0,
                        nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr) !=
      ERROR_SUCCESS) ThrowLastError("RegCreateKeyExW");
  LONG result{};
  if (enabled) {
    auto const command = L"\"" + executable + L"\" --autostart";
    result = ::RegSetValueExW(
        key, application_id.c_str(), 0, REG_SZ,
        reinterpret_cast<BYTE const*>(command.c_str()),
        static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  } else {
    result = ::RegDeleteValueW(key, application_id.c_str());
    if (result == ERROR_FILE_NOT_FOUND) result = ERROR_SUCCESS;
  }
  ::RegCloseKey(key);
  if (result != ERROR_SUCCESS) {
    ::SetLastError(static_cast<DWORD>(result));
    ThrowLastError(enabled ? "RegSetValueExW" : "RegDeleteValueW");
  }
}

TrayIcon::TrayIcon(HWND window, UINT identifier, UINT callback_message,
                   std::wstring const& tooltip, HICON icon)
    : window_(window),
      identifier_(identifier),
      callback_message_(callback_message),
      tooltip_(tooltip) {
  icon_ = ::CopyIcon(icon);
  if (icon_ == nullptr) ThrowLastError("CopyIcon");
  try {
    Add();
  } catch (...) {
    ::DestroyIcon(icon_);
    icon_ = nullptr;
    throw;
  }
}

TrayIcon::~TrayIcon() {
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = identifier_;
  ::Shell_NotifyIconW(NIM_DELETE, &data);
  if (icon_ != nullptr) ::DestroyIcon(icon_);
}

void TrayIcon::Add() {
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = identifier_;
  data.uFlags = NIF_MESSAGE | NIF_TIP | NIF_ICON;
  data.uCallbackMessage = callback_message_;
  data.hIcon = icon_;
  wcsncpy_s(data.szTip, tooltip_.c_str(), _TRUNCATE);
  if (!::Shell_NotifyIconW(NIM_ADD, &data)) ThrowLastError("Shell_NotifyIconW");
}

void TrayIcon::SetTooltip(std::wstring const& tooltip) {
  tooltip_ = tooltip;
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = identifier_;
  data.uFlags = NIF_TIP;
  wcsncpy_s(data.szTip, tooltip_.c_str(), _TRUNCATE);
  if (!::Shell_NotifyIconW(NIM_MODIFY, &data)) ThrowLastError("Shell_NotifyIconW");
}

void TrayIcon::Readd() {
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = identifier_;
  ::Shell_NotifyIconW(NIM_DELETE, &data);
  Add();
}

void TrayIcon::Notify(std::wstring const& title,
                      std::wstring const& body) const {
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = identifier_;
  data.uFlags = NIF_INFO;
  data.dwInfoFlags = NIIF_INFO;
  wcsncpy_s(data.szInfoTitle, title.c_str(), _TRUNCATE);
  wcsncpy_s(data.szInfo, body.c_str(), _TRUNCATE);
  if (!::Shell_NotifyIconW(NIM_MODIFY, &data)) ThrowLastError("Shell_NotifyIconW");
}

namespace {

HWND RequireTrayWindow(HWND window) {
  if (window == nullptr) throw std::invalid_argument("tray window must not be null");
  return window;
}

UINT RequireTrayCallbackMessage(UINT message) {
  if (message < WM_APP || message > 0xBFFF) {
    throw std::invalid_argument("tray callback message must be in the WM_APP range");
  }
  return message;
}

}  // namespace

TrayMenuItem::TrayMenuItem(UINT identifier, std::wstring label,
                           std::function<void()> activated, bool enabled,
                           bool checked)
    : identifier(identifier),
      label(std::move(label)),
      enabled(enabled),
      checked(checked),
      activated(std::move(activated)) {}

TrayController::TrayController(HWND window, UINT identifier,
                               UINT callback_message,
                               std::wstring const& tooltip, HICON icon,
                               std::vector<TrayMenuItem> menu,
                               std::function<void()> activated)
    : window_(RequireTrayWindow(window)),
      identifier_(identifier),
      callback_message_(RequireTrayCallbackMessage(callback_message)),
      subclass_id_(reinterpret_cast<UINT_PTR>(this)),
      activated_(std::move(activated)) {
  SetMenu(std::move(menu));
  taskbar_created_message_ = ::RegisterWindowMessageW(L"TaskbarCreated");
  if (taskbar_created_message_ == 0) ThrowLastError("RegisterWindowMessageW");
  icon_ = std::make_unique<TrayIcon>(window_, identifier_, callback_message_,
                                     tooltip, icon);
  if (!::SetWindowSubclass(window_, &TrayController::WindowSubclass,
                           subclass_id_, reinterpret_cast<DWORD_PTR>(this))) {
    ThrowLastError("SetWindowSubclass");
  }
}

TrayController::~TrayController() {
  if (window_ != nullptr) {
    ::RemoveWindowSubclass(window_, &TrayController::WindowSubclass,
                           subclass_id_);
  }
}

void TrayController::SetMenu(std::vector<TrayMenuItem> menu) {
  std::unordered_set<UINT> identifiers;
  for (auto const& item : menu) {
    if (item.type == TrayMenuItem::Type::separator) continue;
    if (item.identifier == 0 || item.identifier > 0xFFFF) {
      throw std::invalid_argument(
          "tray menu command identifiers must be between 1 and 65535");
    }
    if (item.label.empty()) {
      throw std::invalid_argument("tray menu item labels must not be empty");
    }
    if (!item.activated) {
      throw std::invalid_argument("tray menu items require a callback");
    }
    if (!identifiers.insert(item.identifier).second) {
      throw std::invalid_argument("tray menu command identifiers must be unique");
    }
  }
  menu_ = std::move(menu);
}

void TrayController::SetActivationHandler(std::function<void()> activated) {
  activated_ = std::move(activated);
}

void TrayController::SetTooltip(std::wstring const& tooltip) {
  if (!icon_) throw std::logic_error("tray window has already been destroyed");
  icon_->SetTooltip(tooltip);
}

void TrayController::Notify(std::wstring const& title,
                            std::wstring const& body) const {
  if (!icon_) throw std::logic_error("tray window has already been destroyed");
  icon_->Notify(title, body);
}

LRESULT CALLBACK TrayController::WindowSubclass(
    HWND window, UINT message, WPARAM w_param, LPARAM l_param, UINT_PTR,
    DWORD_PTR reference_data) noexcept {
  auto* self = reinterpret_cast<TrayController*>(reference_data);
  if (self == nullptr) return ::DefSubclassProc(window, message, w_param, l_param);
  return self->HandleMessage(message, w_param, l_param);
}

LRESULT TrayController::HandleMessage(UINT message, WPARAM w_param,
                                      LPARAM l_param) noexcept {
  if (message == WM_NCDESTROY) {
    auto const window = window_;
    icon_.reset();
    window_ = nullptr;
    ::RemoveWindowSubclass(window, &TrayController::WindowSubclass,
                           subclass_id_);
    return ::DefSubclassProc(window, message, w_param, l_param);
  }

  try {
    if (message == taskbar_created_message_) {
      if (icon_) icon_->Readd();
      return 0;
    }
    if (message == callback_message_ &&
        static_cast<UINT>(w_param) == identifier_) {
      auto const event = static_cast<UINT>(l_param);
      if (event == WM_RBUTTONUP || event == WM_CONTEXTMENU) {
        ShowMenu();
        return 0;
      }
      if (event == WM_LBUTTONUP || event == NIN_SELECT ||
          event == NIN_KEYSELECT) {
        auto activated = activated_;
        if (activated) activated();
        return 0;
      }
    }
    if (message == WM_COMMAND && HIWORD(w_param) == 0 && l_param == 0 &&
        DispatchCommand(LOWORD(w_param))) {
      return 0;
    }
  } catch (...) {
    ReportCallbackFailure();
    return 0;
  }
  return ::DefSubclassProc(window_, message, w_param, l_param);
}

void TrayController::ShowMenu() {
  if (menu_.empty() || window_ == nullptr) return;
  auto const owner = window_;
  auto const popup = ::CreatePopupMenu();
  if (popup == nullptr) ThrowLastError("CreatePopupMenu");
  try {
    for (auto const& item : menu_) {
      if (item.type == TrayMenuItem::Type::separator) {
        if (!::AppendMenuW(popup, MF_SEPARATOR, 0, nullptr)) {
          ThrowLastError("AppendMenuW");
        }
        continue;
      }
      UINT flags = MF_STRING;
      if (!item.enabled) flags |= MF_GRAYED;
      if (item.checked) flags |= MF_CHECKED;
      if (!::AppendMenuW(popup, flags, item.identifier, item.label.c_str())) {
        ThrowLastError("AppendMenuW");
      }
    }
    POINT point{};
    if (!::GetCursorPos(&point)) ThrowLastError("GetCursorPos");
    // Required by TrackPopupMenu: without a foreground owner the popup can
    // remain visible after the user clicks elsewhere.
    ::SetForegroundWindow(owner);
    ::TrackPopupMenu(popup, TPM_LEFTALIGN | TPM_BOTTOMALIGN | TPM_RIGHTBUTTON,
                     point.x, point.y, 0, owner, nullptr);
    ::PostMessageW(owner, WM_NULL, 0, 0);
  } catch (...) {
    ::DestroyMenu(popup);
    throw;
  }
  ::DestroyMenu(popup);
}

bool TrayController::DispatchCommand(UINT identifier) {
  auto const item = std::find_if(
      menu_.begin(), menu_.end(), [identifier](TrayMenuItem const& candidate) {
        return candidate.type == TrayMenuItem::Type::item &&
               candidate.identifier == identifier;
      });
  if (item == menu_.end()) return false;
  if (!item->enabled) return true;
  auto activated = item->activated;
  activated();
  return true;
}

void TrayController::ReportCallbackFailure() noexcept {
  ::OutputDebugStringW(
      L"Rivet TrayController contained an exception at the Win32 callback boundary.\n");
}

void InstallCrashHook(CrashCallback callback,
                      std::wstring const& restart_arguments) {
  g_crash_callback = callback;
  ::SetUnhandledExceptionFilter(&UnhandledFilter);
  if (!restart_arguments.empty()) {
    auto const result = ::RegisterApplicationRestart(restart_arguments.c_str(), 0);
    if (FAILED(result)) {
      throw std::system_error(static_cast<int>(result), std::system_category(),
                              "RegisterApplicationRestart");
    }
  }
}

std::vector<std::wstring> ActivationArguments() {
  int count = 0;
  auto arguments = ::CommandLineToArgvW(::GetCommandLineW(), &count);
  if (arguments == nullptr) ThrowLastError("CommandLineToArgvW");
  std::vector<std::wstring> result;
  for (int index = 1; index < count; ++index) result.emplace_back(arguments[index]);
  ::LocalFree(arguments);
  return result;
}

namespace {

std::function<void()> g_shutdown_callback;

BOOL WINAPI ConsoleCtrlHandler(DWORD event_type) {
  switch (event_type) {
    case CTRL_C_EVENT:
    case CTRL_CLOSE_EVENT:
    case CTRL_LOGOFF_EVENT:
    case CTRL_SHUTDOWN_EVENT:
      if (g_shutdown_callback != nullptr) g_shutdown_callback();
      return TRUE;
    default:
      return FALSE;
  }
}

}  // namespace

void InstallShutdownHook(std::function<void()> callback) {
  g_shutdown_callback = std::move(callback);
  if (::SetConsoleCtrlHandler(&ConsoleCtrlHandler, TRUE) == 0) {
    g_shutdown_callback = nullptr;
    ThrowLastError("SetConsoleCtrlHandler");
  }
}

bool GlobalShortcuts::available() {
  // RegisterHotKey needs a message pump on an interactive desktop, which
  // every Rivet host already runs; there is no portal or capability gate.
  return true;
}

namespace {

std::string LowercaseAscii(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](unsigned char c) {
                   return static_cast<char>(::tolower(c));
                 });
  return value;
}

constexpr wchar_t const* kShortcutWindowClass = L"RivetGlobalShortcuts";

bool ParseModifier(std::string const& token, std::uint32_t& modifiers) {
  if (token == "ctrl" || token == "control") {
    modifiers |= MOD_CONTROL;
  } else if (token == "alt" || token == "option") {
    modifiers |= MOD_ALT;
  } else if (token == "shift") {
    modifiers |= MOD_SHIFT;
  } else if (token == "win" || token == "meta" || token == "super" ||
             token == "cmd" || token == "command") {
    modifiers |= MOD_WIN;
  } else {
    return false;
  }
  return true;
}

bool ParseKey(std::string const& token, std::uint32_t& virtual_key) {
  if (token.size() == 1) {
    char const c = token[0];
    if (c >= 'a' && c <= 'z') {
      virtual_key = static_cast<std::uint32_t>('A' + (c - 'a'));
      return true;
    }
    if (c >= '0' && c <= '9') {
      virtual_key = static_cast<std::uint32_t>(c);
      return true;
    }
    return false;
  }
  struct NamedKey {
    char const* name;
    std::uint32_t key;
  };
  static NamedKey const named[] = {
      {"space", VK_SPACE},       {"tab", VK_TAB},
      {"enter", VK_RETURN},      {"return", VK_RETURN},
      {"escape", VK_ESCAPE},     {"esc", VK_ESCAPE},
      {"backspace", VK_BACK},    {"delete", VK_DELETE},
      {"del", VK_DELETE},        {"insert", VK_INSERT},
      {"home", VK_HOME},         {"end", VK_END},
      {"pageup", VK_PRIOR},      {"pagedown", VK_NEXT},
      {"up", VK_UP},             {"down", VK_DOWN},
      {"left", VK_LEFT},         {"right", VK_RIGHT},
      {"comma", VK_OEM_COMMA},   {"period", VK_OEM_PERIOD},
      {"slash", VK_OEM_2},       {"backslash", VK_OEM_5},
      {"semicolon", VK_OEM_1},   {"quote", VK_OEM_7},
      {"minus", VK_OEM_MINUS},   {"equal", VK_OEM_PLUS},
      {"bracketleft", VK_OEM_4}, {"bracketright", VK_OEM_6},
  };
  for (auto const& entry : named) {
    if (token == entry.name) {
      virtual_key = entry.key;
      return true;
    }
  }
  if (token.size() >= 2 && token[0] == 'f') {
    int value = 0;
    for (std::size_t index = 1; index < token.size(); ++index) {
      if (token[index] < '0' || token[index] > '9') return false;
      value = value * 10 + (token[index] - '0');
    }
    if (value >= 1 && value <= 24) {
      virtual_key = (value <= 12) ? VK_F1 + (value - 1) : VK_F13 + (value - 13);
      return true;
    }
  }
  return false;
}

}  // namespace

bool GlobalShortcuts::ParseTrigger(std::string const& trigger,
                                   std::uint32_t& modifiers,
                                   std::uint32_t& virtual_key) {
  modifiers = 0;
  virtual_key = 0;
  std::uint32_t parsed_modifiers = 0;
  std::uint32_t parsed_key = 0;
  bool has_key = false;
  std::string const text = LowercaseAscii(trigger);
  std::size_t start = 0;
  while (start <= text.size()) {
    std::size_t const separator = text.find('+', start);
    std::string const token =
        text.substr(start, separator == std::string::npos
                               ? std::string::npos
                               : separator - start);
    if (token.empty()) return false;
    if (ParseModifier(token, parsed_modifiers)) {
      // Modifier consumed; keys accumulate below.
    } else if (!has_key && ParseKey(token, parsed_key)) {
      has_key = true;
    } else {
      return false;
    }
    if (separator == std::string::npos) break;
    start = separator + 1;
  }
  if (!has_key) return false;
  modifiers = parsed_modifiers;
  virtual_key = parsed_key;
  return true;
}

LRESULT CALLBACK GlobalShortcuts::WndProc(HWND window, UINT message,
                                          WPARAM wparam,
                                          LPARAM lparam) noexcept {
  if (message == WM_HOTKEY) {
    auto* self = reinterpret_cast<GlobalShortcuts*>(
        ::GetWindowLongPtrW(window, GWLP_USERDATA));
    if (self != nullptr) {
      auto const hotkey_id = static_cast<std::uint32_t>(wparam);
      for (auto const& entry : self->registered_) {
        if (entry.first == hotkey_id && self->handler_) {
          self->handler_(entry.second,
                         static_cast<std::uint64_t>(
                             static_cast<unsigned long>(::GetMessageTime())),
                         std::string());
        }
      }
    }
    return 0;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

GlobalShortcuts::GlobalShortcuts() {
  WNDCLASSW window_class{};
  window_class.lpfnWndProc = &GlobalShortcuts::WndProc;
  window_class.hInstance = ::GetModuleHandleW(nullptr);
  window_class.lpszClassName = kShortcutWindowClass;
  ::RegisterClassW(&window_class);
  window_ = ::CreateWindowExW(0, kShortcutWindowClass, L"", 0, 0, 0, 0, 0,
                              HWND_MESSAGE, nullptr, window_class.hInstance,
                              nullptr);
  if (window_ == nullptr) ThrowLastError("CreateWindowExW");
  ::SetWindowLongPtrW(window_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
}

GlobalShortcuts::~GlobalShortcuts() {
  for (auto const& entry : registered_) {
    ::UnregisterHotKey(window_, static_cast<int>(entry.first));
  }
  if (window_ != nullptr) ::DestroyWindow(window_);
}

bool GlobalShortcuts::Register(std::string const& shortcut_id,
                               std::string const& trigger) {
  std::uint32_t modifiers = 0;
  std::uint32_t virtual_key = 0;
  if (!ParseTrigger(trigger, modifiers, virtual_key)) return false;
  if (next_hotkey_id_ > 0xBFFF) return false;
  for (auto const& entry : registered_) {
    if (entry.second == shortcut_id) return false;
  }
  if (::RegisterHotKey(window_, static_cast<int>(next_hotkey_id_), modifiers,
                       virtual_key) == 0) {
    return false;
  }
  registered_.emplace_back(next_hotkey_id_, shortcut_id);
  ++next_hotkey_id_;
  return true;
}

bool GlobalShortcuts::Unregister(std::string const& shortcut_id) {
  for (auto entry = registered_.begin(); entry != registered_.end(); ++entry) {
    if (entry->second == shortcut_id) {
      ::UnregisterHotKey(window_, static_cast<int>(entry->first));
      registered_.erase(entry);
      return true;
    }
  }
  return false;
}

void GlobalShortcuts::SetActivationHandler(ActivationHandler handler) {
  handler_ = std::move(handler);
}

namespace {

constexpr wchar_t const* kClipboardWindowClass = L"RivetClipboard";

std::wstring Utf8ToWide(std::string const& text) {
  if (text.empty()) return {};
  if (text.size() >
      static_cast<std::size_t>((std::numeric_limits<int>::max)())) {
    throw std::invalid_argument("clipboard text exceeds the Win32 size limit");
  }
  int const count = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()),
      nullptr, 0);
  if (count <= 0) ThrowLastError("MultiByteToWideChar");
  std::wstring result(static_cast<std::size_t>(count), L'\0');
  if (::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                            static_cast<int>(text.size()), result.data(),
                            count) != count) {
    ThrowLastError("MultiByteToWideChar");
  }
  return result;
}

std::string WideToUtf8(wchar_t const* text, int length) {
  if (length == 0) return {};
  int const count = ::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text,
                                          length, nullptr, 0, nullptr, nullptr);
  if (count <= 0) ThrowLastError("WideCharToMultiByte");
  std::string result(static_cast<std::size_t>(count), '\0');
  if (::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text, length,
                            result.data(), count, nullptr, nullptr) != count) {
    ThrowLastError("WideCharToMultiByte");
  }
  return result;
}

class ClipboardSession final {
 public:
  explicit ClipboardSession(HWND owner) {
    if (::OpenClipboard(owner) == 0) ThrowLastError("OpenClipboard");
  }
  ~ClipboardSession() { ::CloseClipboard(); }
  ClipboardSession(ClipboardSession const&) = delete;
  ClipboardSession& operator=(ClipboardSession const&) = delete;
};

}  // namespace

std::optional<std::string> Clipboard::ReadText() const {
  ClipboardSession session(window_);
  if (::IsClipboardFormatAvailable(CF_UNICODETEXT) == 0) return std::nullopt;
  HANDLE const handle = ::GetClipboardData(CF_UNICODETEXT);
  if (handle == nullptr) ThrowLastError("GetClipboardData");
  auto const* text = static_cast<wchar_t const*>(::GlobalLock(handle));
  if (text == nullptr) ThrowLastError("GlobalLock");
  std::size_t const capacity = ::GlobalSize(handle) / sizeof(wchar_t);
  std::size_t length = 0;
  while (length < capacity && text[length] != L'\0') ++length;
  try {
    if (length >
        static_cast<std::size_t>((std::numeric_limits<int>::max)())) {
      throw std::runtime_error("clipboard text exceeds the Win32 size limit");
    }
    auto result = WideToUtf8(text, static_cast<int>(length));
    ::GlobalUnlock(handle);
    return result;
  } catch (...) {
    ::GlobalUnlock(handle);
    throw;
  }
}

void Clipboard::WriteText(std::string const& text) const {
  if (text.find('\0') != std::string::npos) {
    throw std::invalid_argument(
        "clipboard text must not contain NUL characters");
  }
  std::wstring const wide = Utf8ToWide(text);
  std::size_t const bytes = (wide.size() + 1) * sizeof(wchar_t);
  HGLOBAL memory = ::GlobalAlloc(GMEM_MOVEABLE, bytes);
  if (memory == nullptr) ThrowLastError("GlobalAlloc");
  void* destination = ::GlobalLock(memory);
  if (destination == nullptr) {
    ::GlobalFree(memory);
    ThrowLastError("GlobalLock");
  }
  std::memcpy(destination, wide.c_str(), bytes);
  ::GlobalUnlock(memory);

  try {
    ClipboardSession session(window_);
    if (::EmptyClipboard() == 0) ThrowLastError("EmptyClipboard");
    if (::SetClipboardData(CF_UNICODETEXT, memory) == nullptr) {
      ThrowLastError("SetClipboardData");
    }
    // The system owns the allocation after a successful SetClipboardData.
    memory = nullptr;
  } catch (...) {
    if (memory != nullptr) ::GlobalFree(memory);
    throw;
  }
}

LRESULT CALLBACK Clipboard::WndProc(HWND window, UINT message, WPARAM wparam,
                                    LPARAM lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto const* create = reinterpret_cast<CREATESTRUCTW const*>(lparam);
    ::SetWindowLongPtrW(window, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  } else if (message == WM_CLIPBOARDUPDATE) {
    auto* self = reinterpret_cast<Clipboard*>(
        ::GetWindowLongPtrW(window, GWLP_USERDATA));
    if (self != nullptr && self->handler_) {
      try {
        auto const text = self->ReadText();
        auto handler = self->handler_;
        handler(text);
      } catch (...) {
        ::OutputDebugStringW(L"Rivet clipboard callback failed\n");
      }
    }
    return 0;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

Clipboard::Clipboard() {
  WNDCLASSW window_class{};
  window_class.lpfnWndProc = &Clipboard::WndProc;
  window_class.hInstance = ::GetModuleHandleW(nullptr);
  window_class.lpszClassName = kClipboardWindowClass;
  ::RegisterClassW(&window_class);
  window_ = ::CreateWindowExW(0, kClipboardWindowClass, L"", 0, 0, 0, 0, 0,
                              HWND_MESSAGE, nullptr, window_class.hInstance,
                              this);
  if (window_ == nullptr) ThrowLastError("CreateWindowExW");
  if (::AddClipboardFormatListener(window_) == 0) {
    ::DestroyWindow(window_);
    window_ = nullptr;
    ThrowLastError("AddClipboardFormatListener");
  }
}

Clipboard::~Clipboard() {
  if (window_ != nullptr) {
    ::RemoveClipboardFormatListener(window_);
    ::DestroyWindow(window_);
  }
}

void Clipboard::SetChangeHandler(ChangeHandler handler) {
  handler_ = std::move(handler);
}

std::optional<std::vector<std::wstring>> FileDialogs::OpenFiles(
    HWND owner, std::wstring const& title, bool allow_multiple,
    bool select_folders, std::vector<FileDialogFilter> const& filters) {
  auto dialog = MakeFileDialog<IFileOpenDialog>(CLSID_FileOpenDialog);
  FILEOPENDIALOGOPTIONS options{};
  winrt::check_hresult(dialog->GetOptions(&options));
  options |= FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST;
  if (select_folders) {
    options |= FOS_PICKFOLDERS;
  } else {
    options |= FOS_FILEMUSTEXIST;
  }
  if (allow_multiple) options |= FOS_ALLOWMULTISELECT;
  winrt::check_hresult(dialog->SetOptions(options));
  if (!title.empty()) winrt::check_hresult(dialog->SetTitle(title.c_str()));

  auto prepared = BuildDialogFilters(filters);
  if (!select_folders && !prepared.specs.empty()) {
    winrt::check_hresult(dialog->SetFileTypes(
        static_cast<UINT>(prepared.specs.size()), prepared.specs.data()));
  }
  if (!ShowDialog(dialog.get(), owner)) return std::nullopt;

  winrt::com_ptr<IShellItemArray> items;
  winrt::check_hresult(dialog->GetResults(items.put()));
  DWORD count{};
  winrt::check_hresult(items->GetCount(&count));
  std::vector<std::wstring> paths;
  paths.reserve(count);
  for (DWORD index = 0; index < count; ++index) {
    winrt::com_ptr<IShellItem> item;
    winrt::check_hresult(items->GetItemAt(index, item.put()));
    paths.push_back(ShellItemPath(item.get()));
  }
  return paths;
}

std::optional<std::wstring> FileDialogs::SaveFile(
    HWND owner, std::wstring const& title,
    std::wstring const& suggested_name,
    std::vector<FileDialogFilter> const& filters) {
  auto dialog = MakeFileDialog<IFileSaveDialog>(CLSID_FileSaveDialog);
  FILEOPENDIALOGOPTIONS options{};
  winrt::check_hresult(dialog->GetOptions(&options));
  winrt::check_hresult(dialog->SetOptions(
      options | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST | FOS_OVERWRITEPROMPT));
  if (!title.empty()) winrt::check_hresult(dialog->SetTitle(title.c_str()));
  if (!suggested_name.empty()) {
    winrt::check_hresult(dialog->SetFileName(suggested_name.c_str()));
  }

  auto prepared = BuildDialogFilters(filters);
  if (!prepared.specs.empty()) {
    winrt::check_hresult(dialog->SetFileTypes(
        static_cast<UINT>(prepared.specs.size()), prepared.specs.data()));
    auto const first_dot = prepared.patterns.front().find(L"*.");
    auto const first_end = prepared.patterns.front().find(L';');
    if (first_dot == 0) {
      auto extension = prepared.patterns.front().substr(
          2, first_end == std::wstring::npos ? std::wstring::npos
                                             : first_end - 2);
      if (!extension.empty()) {
        winrt::check_hresult(dialog->SetDefaultExtension(extension.c_str()));
      }
    }
  }
  if (!ShowDialog(dialog.get(), owner)) return std::nullopt;

  winrt::com_ptr<IShellItem> item;
  winrt::check_hresult(dialog->GetResult(item.put()));
  return ShellItemPath(item.get());
}

}  // namespace rivet::system
