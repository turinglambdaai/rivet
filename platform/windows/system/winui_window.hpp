#pragma once

#include <windows.h>
#include <microsoft.ui.xaml.window.h>
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Windowing.h>

#include <cstdint>

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


namespace detail {
// Injectable resource ID makes the no-resource fallback testable without
// changing the public app icon identity (which remains RT_GROUP_ICON ID 1).
template <typename Window>
[[nodiscard]] bool ApplyIconResource(Window const& window,
                                     HMODULE module, WORD resource_id) {
  if (!module) return false;
  HICON const icon = ::LoadIconW(module, MAKEINTRESOURCEW(resource_id));
  if (!icon) return false;
  window.AppWindow().SetIcon(winrt::Microsoft::UI::IconId{
      static_cast<std::uint64_t>(reinterpret_cast<UINT_PTR>(icon))});
  return true;
}
}  // namespace detail

// Opt-in icon identity for titled WinUI 3 desktop windows. Rivet's Windows
// packager embeds the product icon as RT_GROUP_ICON resource ID 1 in the EXE.
// Secondary Settings/About windows call this helper after their
// InitializeComponent() (before or after Activate()).
//
// LoadIconW returns a *shared*, module-owned icon handle: do not DestroyIcon.
// The executable resource remains loaded for the lifetime of the process.
// Missing resources are normal for unbranded templates; return false and
// leave the existing native title-bar icon unchanged. The SetIcon(String)
// overload expects an .ico path, not an executable filename.
template <typename Window>
[[nodiscard]] bool ApplyAppIcon(Window const& window) {
  return detail::ApplyIconResource(window, ::GetModuleHandleW(nullptr), 1);
}

}  // namespace rivet::system
