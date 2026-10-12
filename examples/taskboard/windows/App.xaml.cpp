#include "pch.h"
#include "App.xaml.h"
#include "MainWindow.xaml.h"

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
}

}  // namespace winrt::RivetHost::implementation
