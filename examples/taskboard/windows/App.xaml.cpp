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
    // App owns the last strong reference to the desktop window. Releasing it
    // lets WinUI finish its normal last-window shutdown after Closed unwinds;
    // forcing Application::Exit from this callback can race teardown of a
    // large virtualized tree and strand the host in process-detach cleanup.
    window_ = nullptr;
  });
  window_.Activate();
}

}  // namespace winrt::RivetHost::implementation
