#pragma once

#include "pch.h"
#include "MainWindow.g.h"
#include "GeneratedBackend.hpp"
#include <microsoft.ui.xaml.window.h>
#include "../../../platform/windows/chart/rivet_chart_control.hpp"
#include "../../../platform/windows/system/system_services.hpp"
#include "../../../platform/windows/system/winui_window.hpp"

namespace winrt::RivetHost::implementation {

struct MainWindow : MainWindowT<MainWindow> {
  MainWindow();

  void TaskList_SelectionChanged(
      winrt::Windows::Foundation::IInspectable const& sender,
      Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const& args);
  void TaskList_ContainerContentChanging(
      Microsoft::UI::Xaml::Controls::ListViewBase const& sender,
      Microsoft::UI::Xaml::Controls::ContainerContentChangingEventArgs const& args);
  void New_Click(winrt::Windows::Foundation::IInspectable const& sender,
                 Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void Samples_Click(winrt::Windows::Foundation::IInspectable const& sender,
                     Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void Generate_Click(winrt::Windows::Foundation::IInspectable const& sender,
                      Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void Cancel_Click(winrt::Windows::Foundation::IInspectable const& sender,
                    Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void Edit_Click(winrt::Windows::Foundation::IInspectable const& sender,
                  Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void SaveEdit_Click(winrt::Windows::Foundation::IInspectable const& sender,
                      Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void CancelEdit_Click(winrt::Windows::Foundation::IInspectable const& sender,
                        Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void EditTitle_KeyDown(winrt::Windows::Foundation::IInspectable const& sender,
                         Microsoft::UI::Xaml::Input::KeyRoutedEventArgs const& args);
  void Advance_Click(winrt::Windows::Foundation::IInspectable const& sender,
                     Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void Delete_Click(winrt::Windows::Foundation::IInspectable const& sender,
                    Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void StreamToggle_Toggled(winrt::Windows::Foundation::IInspectable const& sender,
                            Microsoft::UI::Xaml::RoutedEventArgs const& args);

 private:
  winrt::fire_and_forget InitializeBackendAsync();
  void LoadTasksAsync(std::optional<std::int64_t> preferred = std::nullopt);
  void ApplyTasks(std::vector<rivet_app::BoardTask> items,
                  std::optional<std::int64_t> preferred = std::nullopt);
  void ShowSelectedTask();
  void FinishTitleEdit();
  void ActivateFromTray();
  void NotifyCompleted(std::string const& title);
  void SetBusy(bool busy);
  void SetReadyUi();
  void SetErrorUi(std::string const& message, bool fatal = false);
  void ConfigureChartAsync();
  void RepullChartWindow(std::string const& series);

  std::shared_ptr<rivet::windows::Backend> backend_;
  std::vector<rivet_app::BoardTask> tasks_;
  winrt::Windows::Foundation::Collections::IObservableVector<
      winrt::Windows::Foundation::IInspectable>
      task_rows_{winrt::single_threaded_observable_vector<
          winrt::Windows::Foundation::IInspectable>()};
  std::optional<std::int64_t> selected_id_;
  bool title_editing_{false};
  bool title_save_pending_{false};
  std::optional<std::uint64_t> generation_request_;
  std::unique_ptr<rivet::system::TrayController> tray_controller_;
  rivet::win_ui::ChartControl chart_;
  bool chart_configured_{false};
  std::atomic<bool> closing_{false};
};

}  // namespace winrt::RivetHost::implementation

namespace winrt::RivetHost::factory_implementation {
struct MainWindow : MainWindowT<MainWindow, implementation::MainWindow> {};
}  // namespace winrt::RivetHost::factory_implementation
