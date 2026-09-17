#include "pch.h"
#include "MainWindow.xaml.h"

#include <array>
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
  if (wide.empty()) {
    return {};
  }
  auto const size = ::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                          wide.data(),
                                          static_cast<int>(wide.size()),
                                          nullptr, 0, nullptr, nullptr);
  if (size <= 0) {
    throw std::runtime_error("WideCharToMultiByte failed");
  }
  std::string result(static_cast<std::size_t>(size), '\0');
  if (::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                            wide.data(), static_cast<int>(wide.size()),
                            result.data(), size, nullptr, nullptr) != size) {
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
  config.module_name = "backend";
  config.entry_symbol = "start";
  config.dll_dir = runtime.wstring();
  return config;
}

}  // namespace

MainWindow::MainWindow() {
  InitializeComponent();
  Title(L"Rivet — Racket + WinUI 3");
  InitializeBackendAsync();
}

winrt::fire_and_forget MainWindow::InitializeBackendAsync() {
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();

  try {
    auto backend = std::make_unique<rivet::windows::Backend>(runtime_config());
    co_await winrt::resume_background();
    backend->start();

    if (auto self = weak.get()) {
      self->backend_ = std::move(backend);
      dispatcher.TryEnqueue([weak] {
        if (auto window = weak.get()) {
          window->SetReadyUi();
        }
      });
    } else {
      backend->stop();
    }
  } catch (std::exception const& e) {
    auto message = std::string(e.what());
    dispatcher.TryEnqueue([weak, message = std::move(message)] {
      if (auto window = weak.get()) {
        window->SetErrorUi(message);
      }
    });
  }
}

void MainWindow::Increment_Click(
    winrt::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  IncrementAsync();
}

winrt::fire_and_forget MainWindow::IncrementAsync() {
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto* backend = backend_.get();
  if (backend == nullptr || !backend->running()) {
    SetErrorUi("Racket backend is not running");
    co_return;
  }

  auto const current = count_.load(std::memory_order_relaxed);
  IncrementButton().IsEnabled(false);

  try {
    co_await winrt::resume_background();
    auto future = backend->call(
        "increment",
        rivet::Value::List{rivet::Value(static_cast<std::int64_t>(current))});
    auto value = future.get();
    auto const* next = std::get_if<std::int64_t>(&value.data);
    if (next == nullptr) {
      throw std::runtime_error("increment returned a non-Int64 value");
    }
    count_.store(*next, std::memory_order_relaxed);

    dispatcher.TryEnqueue([weak, next_value = *next] {
      if (auto window = weak.get()) {
        window->CountText().Text(
            winrt::hstring(L"Count: ") + winrt::to_hstring(next_value));
        window->IncrementButton().IsEnabled(true);
      }
    });
  } catch (std::exception const& e) {
    auto message = std::string(e.what());
    dispatcher.TryEnqueue([weak, message = std::move(message)] {
      if (auto window = weak.get()) {
        window->SetErrorUi(message);
        window->IncrementButton().IsEnabled(true);
      }
    });
  }
}

void MainWindow::SetReadyUi() {
  StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Success);
  StatusBar().Message(L"Embedded Racket CS is ready");
  IncrementButton().IsEnabled(true);
}

void MainWindow::SetErrorUi(std::string const& message) {
  StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Error);
  StatusBar().Message(winrt::to_hstring(message));
}

}  // namespace winrt::RivetHost::implementation
