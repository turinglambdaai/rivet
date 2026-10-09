#include "system_services.hpp"

#include <shellapi.h>
#include <wincred.h>

#include <functional>
#include <stdexcept>
#include <system_error>
#include <utility>

#pragma comment(lib, "Advapi32.lib")
#pragma comment(lib, "Shell32.lib")

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
    : window_(window), identifier_(identifier) {
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = window;
  data.uID = identifier;
  data.uFlags = NIF_MESSAGE | NIF_TIP | NIF_ICON;
  data.uCallbackMessage = callback_message;
  data.hIcon = icon;
  wcsncpy_s(data.szTip, tooltip.c_str(), _TRUNCATE);
  if (!::Shell_NotifyIconW(NIM_ADD, &data)) ThrowLastError("Shell_NotifyIconW");
}

TrayIcon::~TrayIcon() {
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = identifier_;
  ::Shell_NotifyIconW(NIM_DELETE, &data);
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

}  // namespace rivet::system
