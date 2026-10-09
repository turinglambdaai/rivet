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
  try {
    auto const window = rivet::system::NativeWindowHandle(*this);
    tray_icon_ = std::make_unique<rivet::system::TrayIcon>(
        window, 1, WM_APP + 42, L"Rivet Taskboard",
        ::LoadIconW(nullptr, IDI_APPLICATION));
  } catch (...) {
    // Notification availability is platform policy and never blocks startup.
  }
  InitializeBackendAsync();
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
    } catch (...) {
      // Unknown application events are intentionally ignored by this screen.
    }
  });

  try {
    co_await winrt::resume_background();
    backend->start();
    dispatcher.TryEnqueue([weak, backend = std::move(backend)]() mutable {
      if (auto window = weak.get()) {
        window->backend_ = std::move(backend);
        window->SetReadyUi();
        window->LoadTasksAsync();
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
  TaskList().Items().Clear();
  for (auto const& task : tasks_) {
    Microsoft::UI::Xaml::Controls::ListViewItem item;
    item.Content(winrt::box_value(winrt::to_hstring(task.title)));
    item.Tag(winrt::box_value(task.id));
    Microsoft::UI::Xaml::Automation::AutomationProperties::SetAutomationId(
        item, L"task-row-" + std::to_wstring(task.id));
    TaskList().Items().Append(item);
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
    return;
  }
  TaskTitle().Text(winrt::to_hstring(found->title));
  TaskStatus().Text(status_text(found->status));
  TaskNotes().Text(winrt::to_hstring(found->notes));
  AdvanceButton().Content(winrt::box_value(
      found->status == rivet_app::TaskStatus::backlog ? L"Start Task" : L"Mark Done"));
  AdvanceButton().IsEnabled(found->status != rivet_app::TaskStatus::done);
  DeleteButton().IsEnabled(true);
}

void MainWindow::NotifyCompleted(std::string const& title) {
  if (!tray_icon_) return;
  try {
    tray_icon_->Notify(L"Task completed", winrt::to_hstring(title).c_str());
  } catch (...) {
    // A denied notification does not turn a successful backend update into an
    // application failure.
  }
}

void MainWindow::TaskList_SelectionChanged(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&) {
  auto item = TaskList().SelectedItem().try_as<Microsoft::UI::Xaml::Controls::ListViewItem>();
  if (!item) return;
  selected_id_ = winrt::unbox_value<std::int64_t>(item.Tag());
  ShowSelectedTask();
  if (backend_ && backend_->running()) {
    rivet_app::API api(*backend_);
    (void)api.select_task_async(*selected_id_, [](auto) {});
  }
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
    try { auto items = result.get(); dispatcher.TryEnqueue([weak, items = std::move(items)]() mutable { if (auto window = weak.get()) { window->generation_request_.reset(); window->ApplyTasks(std::move(items)); window->StatusBar().Message(L"Generated 1,000 tasks"); } }); }
    catch (std::exception const& e) { auto message = std::string(e.what()); dispatcher.TryEnqueue([weak, message = std::move(message)] { if (auto window = weak.get()) { window->generation_request_.reset(); window->SetReadyUi(); window->StatusBar().Message(winrt::to_hstring(message)); } }); }
  });
}

void MainWindow::Cancel_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  if (backend_ && generation_request_) backend_->cancel(*generation_request_);
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
  NewButton().IsEnabled(!busy);
  SamplesButton().IsEnabled(!busy);
  GenerateButton().IsEnabled(!busy);
  TaskList().IsEnabled(!busy);
  if (!busy) CancelButton().Visibility(Microsoft::UI::Xaml::Visibility::Collapsed);
}

void MainWindow::SetReadyUi() {
  StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Success);
  StatusBar().Message(L"Embedded Racket CS is ready");
  SetBusy(false);
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
