#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <cstdint>
#include <filesystem>
#include <future>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>

#include "backend.hpp"

namespace {

std::filesystem::path executable_path() {
  std::wstring buffer(32768, L'\0');
  auto const length = ::GetModuleFileNameW(
      nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
  if (length == 0 || length == buffer.size()) {
    throw std::runtime_error("GetModuleFileNameW failed");
  }
  buffer.resize(length);
  return std::filesystem::path(buffer);
}

std::string utf8(std::filesystem::path const& path) {
  auto const wide = path.wstring();
  auto const size = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(), static_cast<int>(wide.size()),
      nullptr, 0, nullptr, nullptr);
  if (size <= 0) {
    throw std::runtime_error("WideCharToMultiByte failed");
  }
  std::string result(static_cast<std::size_t>(size), '\0');
  if (::WideCharToMultiByte(
          CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(),
          static_cast<int>(wide.size()), result.data(), size, nullptr,
          nullptr) != size) {
    throw std::runtime_error("WideCharToMultiByte failed");
  }
  return result;
}

std::int64_t expect_int(rivet::Value const& value, char const* operation) {
  auto const* result = std::get_if<std::int64_t>(&value.data);
  if (result == nullptr) {
    throw std::runtime_error(std::string(operation) + " returned non-Int64");
  }
  return *result;
}

void progress(char const* message) {
  std::cerr << "[rivet-integration] " << message << "\n" << std::flush;
}

}  // namespace

int main() {
  try {
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

    progress("starting backend");
    rivet::windows::Backend backend(std::move(config));
    backend.start();
    progress("backend started");

    progress("calling increment");
    auto increment = backend.call(
        "increment", rivet::Value::List{rivet::Value(std::int64_t{41})});
    if (expect_int(increment.get(), "increment") != 42) {
      throw std::runtime_error("increment(41) did not return 42");
    }

    progress("calling increment through completion API");
    auto async_value = std::make_shared<std::promise<std::int64_t>>();
    auto async_future = async_value->get_future();
    auto const async_id = backend.request_async(
        "increment", rivet::Value::List{rivet::Value(std::int64_t{99})},
        [async_value](rivet::windows::CallResult result) {
          try {
            if (result.error) {
              std::rethrow_exception(result.error);
            }
            if (!result.value.has_value()) {
              throw std::runtime_error("async increment completed without a value");
            }
            async_value->set_value(expect_int(*result.value, "async increment"));
            // The runtime must isolate application completion exceptions from
            // the reader loop so subsequent requests can still complete.
            throw std::runtime_error("intentional completion exception");
          } catch (...) {
            try {
              async_value->set_exception(std::current_exception());
            } catch (...) {
              // set_value above may already have fulfilled the promise.
            }
            throw;
          }
        });
    if (async_id == 0 || async_future.get() != 100) {
      throw std::runtime_error("async increment(99) did not return 100");
    }

    progress("cancelling pending request");
    auto cancellable = backend.request("wait-for-cancel", {});
    backend.cancel(cancellable.id);
    bool cancelled = false;
    try {
      (void)cancellable.result.get();
    } catch (std::exception const& error) {
      cancelled = std::string(error.what()) == "request cancelled";
      if (!cancelled) {
        throw;
      }
    }
    if (!cancelled) {
      throw std::runtime_error("cancelled request completed successfully");
    }

    progress("calling increment after cancellation");
    auto post_cancel = backend.call(
        "increment", rivet::Value::List{rivet::Value(std::int64_t{1})});
    if (expect_int(post_cancel.get(), "increment after cancel") != 2) {
      throw std::runtime_error("increment after cancellation did not return 2");
    }

    progress("reading initial state");
    auto initial = backend.get_state("counter");
    if (expect_int(initial.get(), "get_state") != 10) {
      throw std::runtime_error("initial counter state is not 10");
    }

    progress("writing state");
    auto updated = backend.set_state("counter", rivet::Value(std::int64_t{11}));
    if (expect_int(updated.get(), "set_state") != 11) {
      throw std::runtime_error("set_state(counter, 11) did not return 11");
    }

    progress("confirming state");
    auto confirmed = backend.get_state("counter");
    if (expect_int(confirmed.get(), "get_state") != 11) {
      throw std::runtime_error("counter state did not persist as 11");
    }

    progress("stopping backend");
    backend.stop();
    progress("backend stopped");
    std::cout << "Rivet embedded Windows round-trip passed\n";
    return 0;
  } catch (std::exception const& error) {
    std::cerr << "Rivet integration failure: " << error.what() << "\n";
    return 1;
  }
}
