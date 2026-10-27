#include "pch.h"
#include "App.xaml.h"
#include "MainWindow.xaml.h"

#include <winrt/Microsoft.UI.Windowing.h>

namespace winrt::RivetHost::implementation {

App::App() {
  InitializeComponent();

#if defined(_DEBUG) && !defined(DISABLE_XAML_GENERATED_BREAK_ON_UNHANDLED_EXCEPTION)
  UnhandledException([](winrt::Windows::Foundation::IInspectable const&,
                        Microsoft::UI::Xaml::UnhandledExceptionEventArgs const& e) {
    if (::IsDebuggerPresent()) {
      auto const message = e.Message();
      (void)message;
      __debugbreak();
    }
  });
#endif
}

void App::OnLaunched(Microsoft::UI::Xaml::LaunchActivatedEventArgs const&) {
  window_ = winrt::make<MainWindow>();
  // The reference layout (status, task list, timing chart, actions) needs more
  // height than the WinUI default window provides; at that default the list
  // collapses into a virtualizing sliver whose rows never realize.
  window_.AppWindow().Resize({ 980, 700 });
  window_.Closed([this](auto const&, auto const&) {
    // A WinUI 3 desktop Application owns its dispatcher independently of its
    // windows. Releasing the final Window reference is necessary, but it does
    // not consistently end the dispatcher on hosted CI desktops. The window's
    // Closed handler was registered first and has already stopped the backend,
    // so explicitly terminate the application lifecycle here.
    window_ = nullptr;
    Microsoft::UI::Xaml::Application::Current().Exit();
  });
  window_.Activate();

  // An explicitly requested test-only second top-level window proves that
  // the same executable icon resource is usable by non-scaffold windows.
  // It does not change the reference app's normal single-window UX.
  wchar_t probe_flag[2]{};
  if (::GetEnvironmentVariableW(L"RIVET_TEST_ICON_PROBE", probe_flag, 2) == 1 &&
      probe_flag[0] == L'1') {
    icon_probe_window_ = Microsoft::UI::Xaml::Window();
    icon_probe_window_.Title(L"Rivet Icon Probe");
    if (!rivet::system::ApplyAppIcon(icon_probe_window_)) {
      winrt::throw_hresult(E_FAIL);
    }
    // Missing resource must return false without crashing or changing the
    // icon that was just applied from the real EXE resource.
    if (rivet::system::detail::ApplyIconResource(
            icon_probe_window_, ::GetModuleHandleW(nullptr), 0xFFFF)) {
      winrt::throw_hresult(E_FAIL);
    }
    icon_probe_window_.Activate();
  }
}

}  // namespace winrt::RivetHost::implementation
