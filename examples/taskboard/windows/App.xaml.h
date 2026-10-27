#pragma once

#include "pch.h"
#include "App.xaml.g.h"

namespace winrt::RivetHost::implementation {

struct App : AppT<App> {
  App();
  void OnLaunched(Microsoft::UI::Xaml::LaunchActivatedEventArgs const&);

 private:
  Microsoft::UI::Xaml::Window window_{nullptr};
  // Only instantiated by the packaged Windows native UI icon regression.
  Microsoft::UI::Xaml::Window icon_probe_window_{nullptr};
};

}  // namespace winrt::RivetHost::implementation
