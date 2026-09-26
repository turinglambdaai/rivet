#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <future>
#include <iomanip>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>

#include "backend.hpp"

namespace {

using BenchmarkClock = std::chrono::steady_clock;

struct BenchmarkMetric {
  int iterations{};
  double total_ms{};
  double us_per_operation{};
};

char const* benchmark_architecture() noexcept {
#if defined(_M_ARM64) || defined(__aarch64__)
  return "arm64";
#elif defined(_M_X64) || defined(__x86_64__)
  return "x64";
#else
  return "unknown";
#endif
}

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

double elapsed_ms(BenchmarkClock::time_point begin,
                  BenchmarkClock::time_point end) {
  return std::chrono::duration<double, std::milli>(end - begin).count();
}

template <typename Operation>
BenchmarkMetric benchmark_operations(int iterations, Operation&& operation) {
  auto const begin = BenchmarkClock::now();
  for (int i = 0; i < iterations; ++i) {
    operation(i);
  }
  auto const total_ms = elapsed_ms(begin, BenchmarkClock::now());
  return BenchmarkMetric{
      iterations,
      total_ms,
      (total_ms * 1000.0) / static_cast<double>(iterations),
  };
}

void print_metric_json(char const* name,
                       BenchmarkMetric const& metric,
                       bool trailing_comma) {
  std::cout << "\"" << name << "\":{"iterations":" << metric.iterations
            << ",\"total_ms\":" << metric.total_ms
            << ",\"us_per_operation\":" << metric.us_per_operation << "}";
  if (trailing_comma) {
    std::cout << ",";
  }
}

void run_benchmark(rivet::windows::Backend& backend, double startup_ms) {
  constexpr int warmup_iterations = 50;
  constexpr int rpc_iterations = 1000;
  constexpr int state_get_iterations = 1000;
  constexpr int state_set_iterations = 500;

  for (int i = 0; i < warmup_iterations; ++i) {
    auto result = backend.call(
        "increment", rivet::Value::List{rivet::Value(std::int64_t{41})});
    if (expect_int(result.get(), "benchmark warmup") != 42) {
      throw std::runtime_error("benchmark warmup returned an unexpected value");
    }
  }

  auto const rpc = benchmark_operations(rpc_iterations, [&](int) {
    auto result = backend.call(
        "increment", rivet::Value::List{rivet::Value(std::int64_t{41})});
    if (expect_int(result.get(), "benchmark RPC") != 42) {
      throw std::runtime_error("benchmark RPC returned an unexpected value");
    }
  });

  auto const state_get = benchmark_operations(state_get_iterations, [&](int) {
    auto result = backend.get_state("counter");
    auto const value = expect_int(result.get(), "benchmark state get");
    if (value != 10) {
      throw std::runtime_error("benchmark state get returned an unexpected value");
    }
  });

  auto const state_set = benchmark_operations(state_set_iterations, [&](int i) {
    auto const expected = std::int64_t{10 + (i & 1)};
    auto result = backend.set_state("counter", rivet::Value(expected));
    if (expect_int(result.get(), "benchmark state set") != expected) {
      throw std::runtime_error("benchmark state set returned an unexpected value");
    }
  });

  std::cout << std::fixed << std::setprecision(3);
  std::cout << "{\"schema_version\":1,\"platform\":\"windows\","
            << "\"architecture\":\"" << benchmark_architecture() << "\","
            << "\"configuration\":\"release\","
            << "\"startup_ms\":" << startup_ms << ","
            << "\"warmup_iterations\":" << warmup_iterations << ",";
  print_metric_json("rpc", rpc, true);
  print_metric_json("state_get", state_get, true);
  print_metric_json("state_set", state_set, false);
  std::cout << "}\n";
}

bool benchmark_mode(int argc, char** argv) {
  if (argc == 1) {
    return false;
  }
  if (argc == 2 && std::string(argv[1]) == "--benchmark") {
    return true;
  }
  throw std::runtime_error("usage: RivetIntegration [--benchmark]");
}

}  // namespace

int main(int argc, char** argv) {
  try {
    auto const benchmark = benchmark_mode(argc, argv);
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
    auto const startup_begin = BenchmarkClock::now();
    backend.start();
    auto const startup_ms = elapsed_ms(startup_begin, BenchmarkClock::now());
    progress("backend started");

    if (benchmark) {
      run_benchmark(backend, startup_ms);
      backend.stop();
      return 0;
    }

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
