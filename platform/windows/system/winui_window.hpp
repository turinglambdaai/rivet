#pragma once

#include <windows.h>
#include <microsoft.ui.xaml.window.h>
#include <winrt/Microsoft.UI.Xaml.h>

namespace rivet::system {

// Official WinUI 3 desktop interop bridge. This avoids title-based
// FindWindowW lookups and centralizes the raw App SDK ABI header required by
// RegisterHotKey, SetWindowSubclass, clipboard listeners, tray icons, and
// other HWND-owned platform features. Call only after InitializeComponent.
// Lives outside system_services.hpp so the platform library (compiled
// without the Windows App SDK include paths) stays WinUI-free; WinUI hosts
// include this header directly.
template <typename Window>
[[nodiscard]] HWND NativeWindowHandle(Window const& window) {
  auto native = window.template try_as<::IWindowNative>();
  if (!native) winrt::check_hresult(E_NOINTERFACE);
  HWND handle{};
  winrt::check_hresult(native->get_WindowHandle(&handle));
  if (handle == nullptr) winrt::check_hresult(E_HANDLE);
  return handle;
}

}  // namespace rivet::system
