#include "pch.h"
#include "MainWindow.xaml.h"
#if __has_include("MainWindow.g.cpp")
#include "MainWindow.g.cpp"
#endif

#include <stdexcept>

namespace winrt::RivetHost::implementation {
namespace {

std::filesystem::path executable_path() {
  std::wstring buffer(32768, L'\0');
  auto const length = ::GetModuleFileNameW(nullptr, buffer.data(),
                                          static_cast<DWORD>(buffer.size()));
  if (length == 0 || length == buffer.size()) {
    throw std::runtime_error("GetModuleFileNameW failed");
  }
  buffer.resize(length);
  return std::filesystem::path(buffer);
}

std::string utf8(std::filesystem::path const& path) {
  auto const wide = path.wstring();
  if (wide.empty()) return {};
  auto const size = ::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                          wide.data(), static_cast<int>(wide.size()),
                                          nullptr, 0, nullptr, nullptr);
  if (size <= 0) throw std::runtime_error("WideCharToMultiByte failed");
  std::string result(static_cast<std::size_t>(size), '\0');
  if (::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(),
                            static_cast<int>(wide.size()), result.data(), size,
                            nullptr, nullptr) != size) {
    throw std::runtime_error("WideCharToMultiByte failed");
  }
  return result;
}

rivet::windows::RacketRuntimeConfig runtime_config() {
  auto const exe = executable_path();
  auto const root = exe.parent_path();
  auto const runtime = root / L"runtime";
  rivet::windows::RacketRuntimeConfig config;
  config.executable_path = utf8(exe);
  config.petite_boot = utf8(runtime / L"petite.boot");
  config.scheme_boot = utf8(runtime / L"scheme.boot");
  config.racket_boot = utf8(runtime / L"racket.boot");
  config.backend_bundle = utf8(root / L"res" / L"core.zo");
  config.module_name = rivet_app::kModuleName;
  config.entry_symbol = rivet_app::kEntryName;
  config.dll_dir = runtime.wstring();
  return config;
}

std::wstring status_text(rivet_app::TaskStatus status) {
  switch (status) {
    case rivet_app::TaskStatus::backlog: return L"Backlog";
    case rivet_app::TaskStatus::active: return L"In progress";
    case rivet_app::TaskStatus::done: return L"Done";
  }
  return L"Unknown";
}

}  // namespace

MainWindow::MainWindow() {
  InitializeComponent();
  Title(L"Rivet Taskboard — Racket + WinUI 3");
  (void)rivet::system::ApplyAppIcon(*this);
  TaskList().ItemsSource(task_rows_);
  ChartHost().Content(chart_);
  chart_.set_title("offsetFromMaster / meanPathDelay");
  try {
    auto const window = rivet::system::NativeWindowHandle(*this);
    std::vector<rivet::system::TrayMenuItem> menu;
    menu.emplace_back(1, L"Open Taskboard",
                      [this] { ActivateFromTray(); });
    menu.emplace_back(rivet::system::TrayMenuItem::Type::separator);
    menu.emplace_back(2, L"Exit", [this] { Close(); });
    tray_controller_ = std::make_unique<rivet::system::TrayController>(
        window, 1, WM_APP + 42, L"Rivet Taskboard",
        ::LoadIconW(nullptr, IDI_APPLICATION), std::move(menu),
        [this] { ActivateFromTray(); });
  } catch (...) {
    // Notification availability is platform policy and never blocks startup.
  }
  Closed([this](auto const&, auto const&) {
    // Release the hidden tray window before asking the embedded runtime to
    // stop. Keeping either owner alive after the last XAML window closes would
    // strand an apparently exited GUI process.
    closing_.store(true, std::memory_order_release);
    tray_controller_.reset();
    if (backend_) backend_->stop();
  });
  InitializeBackendAsync();
}

void MainWindow::ActivateFromTray() {
  auto const window = rivet::system::NativeWindowHandle(*this);
  ::ShowWindow(window, SW_RESTORE);
  ::SetForegroundWindow(window);
  Activate();
}

winrt::fire_and_forget MainWindow::InitializeBackendAsync() {
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = std::make_shared<rivet::windows::Backend>(runtime_config());

  backend->set_event_handler([dispatcher, weak](std::string const& name,
                                                 rivet::Value const& value) {
    try {
      auto event = rivet_app::decode_event(name, value);
      if (auto progress = std::get_if<rivet_app::Operation_progressEvent>(&event)) {
        auto message = progress->value.message;
        dispatcher.TryEnqueue([weak, message = std::move(message)] {
          if (auto window = weak.get()) {
            window->StatusBar().Message(winrt::to_hstring(message));
          }
        });
      }
      if (auto batch = std::get_if<rivet_app::Chart_batchEvent>(&event)) {
        auto envelope = batch->value;
        dispatcher.TryEnqueue([weak, envelope = std::move(envelope)]() mutable {
          if (auto window = weak.get()) {
            window->chart_.append_batch(envelope.series, envelope.batch);
          }
        });
      }
    } catch (...) {
      // Unknown application events are intentionally ignored by this screen.
    }
  });

  try {
    co_await winrt::resume_background();
    backend->start();
    dispatcher.TryEnqueue([weak, backend = std::move(backend)]() mutable {
      if (auto window = weak.get()) {
        if (window->closing_.load(std::memory_order_acquire)) {
          std::thread([backend = std::move(backend)]() mutable {
            backend->stop();
          }).detach();
        } else {
          window->backend_ = std::move(backend);
          window->SetReadyUi();
          window->LoadTasksAsync();
          window->ConfigureChartAsync();
        }
      } else {
        std::thread([backend = std::move(backend)]() mutable { backend->stop(); }).detach();
      }
    });
  } catch (std::exception const& e) {
    auto message = std::string(e.what());
    dispatcher.TryEnqueue([weak, message = std::move(message)] {
      if (auto window = weak.get()) window->SetErrorUi(message, true);
    });
  }
}

void MainWindow::LoadTasksAsync(std::optional<std::int64_t> preferred) {
  auto backend = backend_;
  if (!backend || !backend->running()) {
    return SetErrorUi("Racket backend is not running", true);
  }
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  rivet_app::API api(*backend);
  (void)api.list_tasks_async(
      [dispatcher, weak, preferred](rivet_app::Result<std::vector<rivet_app::BoardTask>> result) {
        try {
          auto items = result.get();
          dispatcher.TryEnqueue([weak, preferred, items = std::move(items)]() mutable {
            if (auto window = weak.get()) window->ApplyTasks(std::move(items), preferred);
          });
        } catch (std::exception const& e) {
          auto message = std::string(e.what());
          dispatcher.TryEnqueue([weak, message = std::move(message)] {
            if (auto window = weak.get()) window->SetErrorUi(message);
          });
        }
      });
}

void MainWindow::ApplyTasks(std::vector<rivet_app::BoardTask> items,
                            std::optional<std::int64_t> preferred) {
  tasks_ = std::move(items);
  task_rows_.Clear();
  for (auto const& task : tasks_) {
    auto row = winrt::single_threaded_map<
        winrt::hstring, winrt::Windows::Foundation::IInspectable>();
    row.Insert(L"Id", winrt::box_value(task.id));
    row.Insert(L"Title", winrt::box_value(winrt::to_hstring(task.title)));
    row.Insert(L"AutomationId",
               winrt::box_value(L"task-row-" + std::to_wstring(task.id)));
    task_rows_.Append(row);
  }
  TaskList().IsEnabled(true);
  selected_id_ = preferred;
  std::uint32_t index = 0;
  bool found = false;
  for (auto const& task : tasks_) {
    if (preferred && task.id == *preferred) { found = true; break; }
    ++index;
  }
  if (!found) index = 0;
  if (!tasks_.empty()) TaskList().SelectedIndex(static_cast<std::int32_t>(index));
  else {
    selected_id_.reset();
    ShowSelectedTask();
  }
  SetBusy(false);
}

void MainWindow::ShowSelectedTask() {
  auto found = std::find_if(tasks_.begin(), tasks_.end(), [this](auto const& task) {
    return selected_id_ && task.id == *selected_id_;
  });
  if (found == tasks_.end()) {
    TaskTitle().Text(L"Select a task");
    TaskStatus().Text(L"");
    TaskNotes().Text(L"Task details are provided by the shared Racket backend.");
    AdvanceButton().IsEnabled(false);
    DeleteButton().IsEnabled(false);
    EditButton().IsEnabled(false);
    return;
  }
  TaskTitle().Text(winrt::to_hstring(found->title));
  TaskStatus().Text(status_text(found->status));
  TaskNotes().Text(winrt::to_hstring(found->notes));
  AdvanceButton().Content(winrt::box_value(
      found->status == rivet_app::TaskStatus::backlog ? L"Start Task" : L"Mark Done"));
  AdvanceButton().IsEnabled(found->status != rivet_app::TaskStatus::done);
  DeleteButton().IsEnabled(!title_editing_);
  EditButton().IsEnabled(!title_editing_);
}

void MainWindow::NotifyCompleted(std::string const& title) {
  if (!tray_controller_) return;
  try {
    tray_controller_->Notify(L"Task completed", winrt::to_hstring(title).c_str());
  } catch (...) {
    // A denied notification does not turn a successful backend update into an
    // application failure.
  }
}

void MainWindow::TaskList_SelectionChanged(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&) {
  auto row = TaskList().SelectedItem().try_as<
      winrt::Windows::Foundation::Collections::IMap<
          winrt::hstring, winrt::Windows::Foundation::IInspectable>>();
  if (!row) return;
  selected_id_ = winrt::unbox_value<std::int64_t>(row.Lookup(L"Id"));
  ShowSelectedTask();
  if (backend_ && backend_->running()) {
    rivet_app::API api(*backend_);
    (void)api.select_task_async(*selected_id_, [](auto) {});
  }
}

void MainWindow::TaskList_ContainerContentChanging(
    Microsoft::UI::Xaml::Controls::ListViewBase const&,
    Microsoft::UI::Xaml::Controls::ContainerContentChangingEventArgs const& args) {
  if (args.InRecycleQueue()) return;
  auto row = args.Item().try_as<
      winrt::Windows::Foundation::Collections::IMap<
          winrt::hstring, winrt::Windows::Foundation::IInspectable>>();
  auto container = args.ItemContainer().try_as<
      Microsoft::UI::Xaml::Controls::ListViewItem>();
  if (!row || !container) return;
  Microsoft::UI::Xaml::Automation::AutomationProperties::SetAutomationId(
      container, winrt::unbox_value<winrt::hstring>(
                     row.Lookup(L"AutomationId")));
}

void MainWindow::New_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  if (!backend_) return;
  SetBusy(true);
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  rivet_app::API api(*backend_);
  (void)api.create_task_async("New task", "Edit the Racket backend to make this workflow your own.",
      [dispatcher, weak](rivet_app::Result<rivet_app::BoardTask> result) {
        try {
          auto id = result.get().id;
          dispatcher.TryEnqueue([weak, id] { if (auto window = weak.get()) window->LoadTasksAsync(id); });
        } catch (std::exception const& e) {
          auto message = std::string(e.what());
          dispatcher.TryEnqueue([weak, message = std::move(message)] { if (auto window = weak.get()) window->SetErrorUi(message); });
        }
      });
}

void MainWindow::Samples_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  if (!backend_) return;
  SetBusy(true);
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  rivet_app::API api(*backend_);
  (void)api.reload_sample_tasks_async([dispatcher, weak](auto result) {
    try { auto items = result.get(); dispatcher.TryEnqueue([weak, items = std::move(items)]() mutable { if (auto window = weak.get()) window->ApplyTasks(std::move(items)); }); }
    catch (std::exception const& e) { auto message = std::string(e.what()); dispatcher.TryEnqueue([weak, message = std::move(message)] { if (auto window = weak.get()) window->SetErrorUi(message); }); }
  });
}

void MainWindow::Generate_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  if (!backend_) return;
  SetBusy(true);
  CancelButton().Visibility(Microsoft::UI::Xaml::Visibility::Visible);
  StatusBar().Message(L"Preparing the bounded 1,000-row workload…");
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  rivet_app::API api(*backend_);
  generation_request_ = api.generate_demo_tasks_async(1000, [dispatcher, weak](auto result) {
    try { auto items = result.get(); dispatcher.TryEnqueue([weak, items = std::move(items)]() mutable { if (auto window = weak.get()) { auto const message = "Generated " + std::to_string(items.size()) + " tasks"; window->generation_request_.reset(); window->ApplyTasks(std::move(items)); window->StatusBar().Message(winrt::to_hstring(message)); } }); }
    catch (std::exception const& e) { auto message = std::string(e.what()); dispatcher.TryEnqueue([weak, message = std::move(message)] { if (auto window = weak.get()) { window->generation_request_.reset(); window->SetReadyUi(); window->StatusBar().Message(winrt::to_hstring(message)); } }); }
  });
}

void MainWindow::Cancel_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  if (backend_ && generation_request_) backend_->cancel(*generation_request_);
}

// A draft is isolated from list navigation and mutations until the user
// explicitly saves or discards it. Failed RPCs retain the TextBox contents.
void MainWindow::Edit_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  if (title_editing_ || !backend_ || !selected_id_) return;
  auto found = std::find_if(tasks_.begin(), tasks_.end(),
      [this](auto const& task) { return task.id == *selected_id_; });
  if (found == tasks_.end()) return;
  EditTitleBox().Text(winrt::to_hstring(found->title));
  title_editing_ = true;
  title_save_pending_ = false;
  EditTitleBox().Visibility(Microsoft::UI::Xaml::Visibility::Visible);
  SaveEditButton().Visibility(Microsoft::UI::Xaml::Visibility::Visible);
  CancelEditButton().Visibility(Microsoft::UI::Xaml::Visibility::Visible);
  SetBusy(false);
  StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Informational);
  StatusBar().Message(L"Draft pending — select Save or Discard draft.");
  EditTitleBox().Focus(Microsoft::UI::Xaml::FocusState::Programmatic);
}

void MainWindow::FinishTitleEdit() {
  title_editing_ = false;
  title_save_pending_ = false;
  EditTitleBox().Visibility(Microsoft::UI::Xaml::Visibility::Collapsed);
  SaveEditButton().Visibility(Microsoft::UI::Xaml::Visibility::Collapsed);
  CancelEditButton().Visibility(Microsoft::UI::Xaml::Visibility::Collapsed);
  SetBusy(false);
  EditButton().Focus(Microsoft::UI::Xaml::FocusState::Programmatic);
}

void MainWindow::CancelEdit_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  if (!title_editing_ || title_save_pending_) return;
  FinishTitleEdit();
  StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Informational);
  StatusBar().Message(L"Draft discarded — no changes saved.");
}

void MainWindow::EditTitle_KeyDown(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::Input::KeyRoutedEventArgs const& args) {
  // Do not bind Enter to Save: IME composition must never submit a draft.
  if (args.Key() == winrt::Windows::System::VirtualKey::Escape &&
      title_editing_ && !title_save_pending_) {
    args.Handled(true);
    FinishTitleEdit();
    StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Informational);
    StatusBar().Message(L"Draft discarded — no changes saved.");
  }
}

void MainWindow::SaveEdit_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  if (!title_editing_ || title_save_pending_ || !backend_ || !selected_id_) return;
  auto found = std::find_if(tasks_.begin(), tasks_.end(),
      [this](auto const& task) { return task.id == *selected_id_; });
  if (found == tasks_.end()) return;
  auto const id = found->id;
  auto const title = winrt::to_string(EditTitleBox().Text());
  auto const notes = found->notes;
  auto const status = found->status;
  title_save_pending_ = true;
  SetBusy(true);
  StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Informational);
  StatusBar().Message(L"Saving title to this device…");
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  rivet_app::API api(*backend_);
  (void)api.update_task_async(id, title, notes, status,
    [dispatcher, weak, id](auto result) {
      try {
        (void)result.get();
        dispatcher.TryEnqueue([weak, id] {
          if (auto window = weak.get()) {
            window->FinishTitleEdit();
            window->StatusBar().Severity(
                Microsoft::UI::Xaml::Controls::InfoBarSeverity::Success);
            window->StatusBar().Message(L"Task title saved to this device.");
            window->LoadTasksAsync(id);
          }
        });
      } catch (std::exception const& e) {
        auto message = std::string(e.what());
        dispatcher.TryEnqueue([weak, message = std::move(message)] {
          if (auto window = weak.get()) {
            window->title_save_pending_ = false;
            window->SetBusy(false);
            window->StatusBar().Severity(
                Microsoft::UI::Xaml::Controls::InfoBarSeverity::Error);
            window->StatusBar().Message(
                winrt::to_hstring("Update failed; draft retained: " + message));
            window->EditTitleBox().Focus(
                Microsoft::UI::Xaml::FocusState::Programmatic);
          }
        });
      }
    });
}

void MainWindow::Advance_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  if (!backend_ || !selected_id_) return;
  auto found = std::find_if(tasks_.begin(), tasks_.end(), [this](auto const& task) { return task.id == *selected_id_; });
  if (found == tasks_.end()) return;
  auto const next = found->status == rivet_app::TaskStatus::backlog ? rivet_app::TaskStatus::active : rivet_app::TaskStatus::done;
  auto const id = found->id;
  auto const title = found->title;
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  SetBusy(true);
  rivet_app::API api(*backend_);
  (void)api.update_task_async(id, found->title, found->notes, next, [dispatcher, weak, id, title, next](auto result) {
    try { (void)result.get(); dispatcher.TryEnqueue([weak, id, title, next] { if (auto window = weak.get()) { if (next == rivet_app::TaskStatus::done) window->NotifyCompleted(title); window->LoadTasksAsync(id); } }); }
    catch (std::exception const& e) { auto message = std::string(e.what()); dispatcher.TryEnqueue([weak, message = std::move(message)] { if (auto window = weak.get()) window->SetErrorUi(message); }); }
  });
}

void MainWindow::Delete_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  if (!backend_ || !selected_id_) return;
  auto const id = *selected_id_;
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  SetBusy(true);
  rivet_app::API api(*backend_);
  (void)api.delete_task_async(id, [dispatcher, weak](auto result) {
    try { (void)result.get(); dispatcher.TryEnqueue([weak] { if (auto window = weak.get()) window->LoadTasksAsync(); }); }
    catch (std::exception const& e) { auto message = std::string(e.what()); dispatcher.TryEnqueue([weak, message = std::move(message)] { if (auto window = weak.get()) window->SetErrorUi(message); }); }
  });
}

void MainWindow::SetBusy(bool busy) {
  auto const can_mutate = !busy && !title_editing_;
  NewButton().IsEnabled(can_mutate);
  SamplesButton().IsEnabled(can_mutate);
  GenerateButton().IsEnabled(can_mutate);
  TaskList().IsEnabled(can_mutate);
  EditButton().IsEnabled(can_mutate && selected_id_.has_value());
  SaveEditButton().IsEnabled(title_editing_ && !busy);
  CancelEditButton().IsEnabled(title_editing_ && !busy);
  EditTitleBox().IsEnabled(title_editing_ && !busy);
  auto found = std::find_if(tasks_.begin(), tasks_.end(),
      [this](auto const& task) { return selected_id_ && task.id == *selected_id_; });
  AdvanceButton().IsEnabled(can_mutate && found != tasks_.end() &&
      found->status != rivet_app::TaskStatus::done);
  DeleteButton().IsEnabled(can_mutate && found != tasks_.end());
  if (!busy) CancelButton().Visibility(Microsoft::UI::Xaml::Visibility::Collapsed);
}

void MainWindow::SetReadyUi() {
  StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Success);
  StatusBar().Message(L"Embedded Racket CS is ready");
  SetBusy(false);
}

// Specs and thresholds come through typed RPCs; the live samples then flow
// as chart batches through the event handler above. A gap (ring eviction
// on the Racket side) is repaired by re-pulling the window.
void MainWindow::ConfigureChartAsync() {
  if (chart_configured_ || !backend_) {
    return;
  }
  chart_configured_ = true;
  auto dispatcher = DispatcherQueue();
  auto weak = get_weak();
  auto backend = backend_;

  // API objects only need to outlive the synchronous issue call, so each
  // request gets its own short-lived instance on this stack frame.
  {
    rivet_app::API api(*backend);
    (void)api.timing_series_specs_async(
        [dispatcher, weak](rivet_app::Result<std::vector<rivet_app::TimingSeries>> result) {
          if (result.error) {
            return;
          }
          auto const& received = result.get();
          auto* specs = new std::vector<rivet::win_ui::ChartSeriesSpec>();
          for (auto const& timing : received) {
            specs->push_back({timing.id, timing.label, timing.color, timing.unit});
          }
          dispatcher.TryEnqueue([weak, specs] {
            std::unique_ptr<std::vector<rivet::win_ui::ChartSeriesSpec>> owned(specs);
            if (auto window = weak.get()) {
              window->chart_.set_series(std::move(*owned));
              window->chart_.on_gap = [weak](std::string const& series) {
                if (auto window = weak.get()) {
                  window->RepullChartWindow(series);
                }
              };
            }
          });
        });
  }
  {
    rivet_app::API api(*backend);
    (void)api.timing_decoration_async(
        [dispatcher, weak](rivet_app::Result<std::vector<rivet_app::TimingThreshold>> result) {
          if (result.error) {
            return;
          }
          auto const& received = result.get();
          auto* thresholds = new std::vector<rivet::win_ui::ChartThreshold>();
          for (auto const& timing : received) {
            thresholds->push_back({timing.value, timing.label, timing.color});
          }
          dispatcher.TryEnqueue([weak, thresholds] {
            std::unique_ptr<std::vector<rivet::win_ui::ChartThreshold>> owned(thresholds);
            if (auto window = weak.get()) {
              window->chart_.set_thresholds(std::move(*owned));
            }
          });
        });
  }
  {
    rivet_app::API api(*backend);
    (void)api.timing_start_async([](rivet_app::Result<bool>) {});
  }
}

void MainWindow::RepullChartWindow(std::string const& series) {
  if (!backend_) {
    return;
  }
  auto dispatcher = DispatcherQueue();
  auto weak = get_weak();
  rivet_app::API api(*backend_);
  (void)api.timing_window_async(
      series,
      [dispatcher, weak, series](rivet_app::Result<rivet_app::TimingWindow> window) {
        if (window.error) {
          return;
        }
        auto const& received = window.get();
        struct Delivery {
          std::string series;
          std::uint64_t watermark;
          std::vector<rivet::chart::Sample> samples;
        };
        auto* delivery =
            new Delivery{series, static_cast<std::uint64_t>(received.watermark), {}};
        for (auto const& sample : received.samples) {
          delivery->samples.push_back({sample.ts, sample.value});
        }
        dispatcher.TryEnqueue([weak, delivery] {
          std::unique_ptr<Delivery> owned(delivery);
          if (auto window = weak.get()) {
            window->chart_.replace_series(owned->series, std::move(owned->samples),
                                          owned->watermark);
          }
        });
      });
}

void MainWindow::StreamToggle_Toggled(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  if (!backend_) {
    return;
  }
  auto api = std::make_unique<rivet_app::API>(*backend_);
  auto starting = StreamToggle().IsOn();
  if (starting) {
    (void)api->timing_start_async([](rivet_app::Result<bool>) {});
  } else {
    (void)api->timing_stop_async([](rivet_app::Result<bool>) {});
  }
}

void MainWindow::SetErrorUi(std::string const& message, bool fatal) {
  StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Error);
  StatusBar().Message(winrt::to_hstring(message));
  generation_request_.reset();
  CancelButton().Visibility(Microsoft::UI::Xaml::Visibility::Collapsed);
  if (fatal) {
    NewButton().IsEnabled(false);
    SamplesButton().IsEnabled(false);
    GenerateButton().IsEnabled(false);
    TaskList().IsEnabled(false);
    AdvanceButton().IsEnabled(false);
    DeleteButton().IsEnabled(false);
  } else {
    SetBusy(false);
  }
}

}  // namespace winrt::RivetHost::implementation
