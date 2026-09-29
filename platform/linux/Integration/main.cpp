#include <chrono>
#include <cstdint>
#include <filesystem>
#include <future>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include "backend.hpp"

namespace {

std::filesystem::path executable_path() {
  return std::filesystem::read_symlink("/proc/self/exe");
}

std::int64_t expect_int(rivet::Value const& value, char const* operation) {
  auto const* result = std::get_if<std::int64_t>(&value.data);
  if (result == nullptr) {
    throw std::runtime_error(std::string(operation) + " returned non-Int64");
  }
  return *result;
}

void progress(char const* message) {
  std::cerr << "[rivet-linux-integration] " << message << "\n" << std::flush;
}

}  // namespace

int main() {
  try {
    auto const exe = executable_path();
    auto const root = exe.parent_path();
    auto const runtime = root / "runtime";

    rivet::linux::RacketRuntimeConfig config;
    config.executable_path = exe.string();
    config.petite_boot = (runtime / "petite.boot").string();
    config.scheme_boot = (runtime / "scheme.boot").string();
    config.racket_boot = (runtime / "racket.boot").string();
    config.backend_bundle = (root / "res" / "core.zo").string();
    config.module_name = "backend";
    config.entry_symbol = "start";
    config.max_pending_requests = 32;

    progress("starting backend");
    rivet::linux::Backend backend(std::move(config));
    backend.start();
    progress("backend started");

    auto increment = backend.call(
        "increment", rivet::Value::List{rivet::Value(std::int64_t{41})});
    if (expect_int(increment.get(), "increment") != 42) {
      throw std::runtime_error("increment(41) did not return 42");
    }

    progress("checking completion isolation");
    auto async_value = std::make_shared<std::promise<std::int64_t>>();
    auto async_future = async_value->get_future();
    auto const async_id = backend.request_async(
        "increment", rivet::Value::List{rivet::Value(std::int64_t{99})},
        [async_value](rivet::linux::CallResult result) {
          if (result.error) {
            async_value->set_exception(result.error);
            return;
          }
          async_value->set_value(expect_int(*result.value, "async increment"));
          throw std::runtime_error("intentional completion exception");
        });
    if (async_id == 0 || async_future.get() != 100) {
      throw std::runtime_error("async increment(99) did not return 100");
    }

    progress("checking pending limit and cancellation");
    std::vector<rivet::linux::PendingCall> cancellable;
    cancellable.reserve(32);
    for (int i = 0; i < 32; ++i) {
      cancellable.push_back(backend.request("wait-for-cancel", {}));
    }
    bool overload_rejected = false;
    try {
      (void)backend.request("increment",
                            {rivet::Value(std::int64_t{1})});
    } catch (std::runtime_error const& error) {
      overload_rejected =
          std::string(error.what()) ==
          "too many native pending requests (limit 32)";
      if (!overload_rejected) {
        throw;
      }
    }
    if (!overload_rejected) {
      throw std::runtime_error("native pending request limit was not enforced");
    }
    for (auto const& pending : cancellable) {
      backend.cancel(pending.id);
    }
    for (auto& pending : cancellable) {
      bool cancelled = false;
      try {
        (void)pending.result.get();
      } catch (std::exception const& error) {
        cancelled = std::string(error.what()) == "request cancelled";
        if (!cancelled) {
          throw;
        }
      }
      if (!cancelled) {
        throw std::runtime_error("cancelled request completed successfully");
      }
    }

    progress("checking concurrent request writes");
    std::vector<std::future<void>> concurrent;
    for (int i = 0; i < 16; ++i) {
      concurrent.push_back(std::async(std::launch::async, [&backend, i] {
        auto result = backend.call(
            "increment", {rivet::Value(static_cast<std::int64_t>(i))});
        if (expect_int(result.get(), "concurrent increment") != i + 1) {
          throw std::runtime_error("concurrent increment returned wrong value");
        }
      }));
    }
    for (auto& operation : concurrent) {
      operation.get();
    }

    progress("checking State access");
    if (expect_int(backend.get_state("counter").get(), "get_state") != 10) {
      throw std::runtime_error("initial counter state is not 10");
    }
    if (expect_int(backend.set_state("counter", rivet::Value(std::int64_t{11})).get(),
                   "set_state") != 11) {
      throw std::runtime_error("set_state(counter, 11) did not return 11");
    }

    progress("stopping backend concurrently with pending work");
    auto pending_at_stop = backend.request("wait-for-cancel", {});
    auto stop_one = std::async(std::launch::async, [&backend] { backend.stop(); });
    auto stop_two = std::async(std::launch::async, [&backend] { backend.stop(); });
    stop_one.get();
    stop_two.get();

    bool pending_failed = false;
    try {
      (void)pending_at_stop.result.get();
    } catch (std::exception const&) {
      pending_failed = true;
    }
    if (!pending_failed) {
      throw std::runtime_error("request pending at shutdown completed successfully");
    }

    progress("backend stopped");
    std::cout << "Rivet embedded Linux round-trip passed\n";
    return 0;
  } catch (std::exception const& error) {
    std::cerr << "Rivet Linux integration failure: " << error.what() << "\n";
    return 1;
  }
}
