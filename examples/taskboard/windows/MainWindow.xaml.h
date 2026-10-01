#pragma once

#include "pch.h"
#include "MainWindow.g.h"
#include "GeneratedBackend.hpp"
#include <microsoft.ui.xaml.window.h>
#include "../../../platform/windows/system/system_services.hpp"

namespace winrt::RivetHost::implementation {

struct MainWindow : MainWindowT<MainWindow> {
  MainWindow();

  void TaskList_SelectionChanged(
      winrt::Windows::Foundation::IInspectable const& sender,
      Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const& args);
  void New_Click(winrt::Windows::Foundation::IInspectable const& sender,
                 Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void Samples_Click(winrt::Windows::Foundation::IInspectable const& sender,
                     Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void Generate_Click(winrt::Windows::Foundation::IInspectable const& sender,
                      Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void Cancel_Click(winrt::Windows::Foundation::IInspectable const& sender,
                    Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void Advance_Click(winrt::Windows::Foundation::IInspectable const& sender,
                     Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void Delete_Click(winrt::Windows::Foundation::IInspectable const& sender,
                    Microsoft::UI::Xaml::RoutedEventArgs const& args);

 private:
  winrt::fire_and_forget InitializeBackendAsync();
  void LoadTasksAsync(std::optional<std::int64_t> preferred = std::nullopt);
  void ApplyTasks(std::vector<rivet_app::BoardTask> items,
                  std::optional<std::int64_t> preferred = std::nullopt);
  void ShowSelectedTask();
  void NotifyCompleted(std::string const& title);
  void SetBusy(bool busy);
  void SetReadyUi();
  void SetErrorUi(std::string const& message, bool fatal = false);

  std::shared_ptr<rivet::windows::Backend> backend_;
  std::vector<rivet_app::BoardTask> tasks_;
  std::optional<std::int64_t> selected_id_;
  std::optional<std::uint64_t> generation_request_;
  std::unique_ptr<rivet::system::TrayIcon> tray_icon_;
};

}  // namespace winrt::RivetHost::implementation

namespace winrt::RivetHost::factory_implementation {
struct MainWindow : MainWindowT<MainWindow, implementation::MainWindow> {};
}  // namespace winrt::RivetHost::factory_implementation
