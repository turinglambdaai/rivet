#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <future>
#include <iostream>
#include <iterator>
#include <memory>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

#include <gio/gio.h>

#include "backend.hpp"
#include "system_services.hpp"

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

bool has_capability(std::vector<std::string> const& capabilities,
                    std::string const& name) {
  for (std::string const& capability : capabilities) {
    if (capability == name) return true;
  }
  return false;
}

void require(bool condition, std::string const& message) {
  if (!condition) {
    throw std::runtime_error(message);
  }
}

class TempEnvOverride {
 public:
  TempEnvOverride(char const* name, std::string const& value) : name_(name) {
    char const* previous = getenv(name);
    if (previous) previous_ = previous;
    setenv(name, value.c_str(), 1);
  }
  ~TempEnvOverride() {
    if (previous_) setenv(name_.c_str(), previous_->c_str(), 1);
    else unsetenv(name_.c_str());
  }
  TempEnvOverride(TempEnvOverride const&) = delete;
  TempEnvOverride& operator=(TempEnvOverride const&) = delete;

 private:
  std::string name_;
  std::optional<std::string> previous_;
};

std::filesystem::path make_temp_directory(char const* prefix) {
  std::string pattern = std::string("/tmp/") + prefix + "-XXXXXX";
  std::vector<char> buffer(pattern.begin(), pattern.end());
  buffer.push_back('\0');
  char* created = mkdtemp(buffer.data());
  if (created == nullptr) {
    throw std::runtime_error("mkdtemp failed for system self-check");
  }
  return std::filesystem::path(created);
}

int run_system_self_check(std::vector<std::string> const& arguments) {
  auto const capabilities = rivet::system::Capabilities();
  progress("checking activation arguments");
  require(rivet::system::ActivationArguments() == arguments,
          "ActivationArguments must round-trip the process payload");

  progress("checking single-instance lease and activation forwarding");
  rivet::system::SingleInstanceLease primary("org.rivet.integration.test");
  require(primary.is_primary(), "the first lease must be primary");
  std::promise<std::vector<std::string>> delivered;
  auto delivery = delivered.get_future();
  primary.set_activation_handler(
      [&delivered](std::vector<std::string> activation) {
        delivered.set_value(std::move(activation));
      });
  {
    rivet::system::SingleInstanceLease secondary("org.rivet.integration.test");
    require(!secondary.is_primary(), "the second lease must not be primary");
    require(secondary.forward_arguments({"open", "file.txt"}),
            "forwarding to the primary instance failed");
  }
  if (delivery.wait_for(std::chrono::seconds(3)) != std::future_status::ready) {
    throw std::runtime_error("the primary instance never received the activation");
  }
  require((delivery.get() == std::vector<std::string>{"open", "file.txt"}),
          "the forwarded activation payload does not match");

  progress("checking XDG autostart entries");
  std::string const autostart_id = "org.rivet.autostart.integration";
  {
    auto config_dir = make_temp_directory("rivet-autostart");
    TempEnvOverride config_override("XDG_CONFIG_HOME", config_dir.string());
    require(!rivet::system::Autostart::Enabled(autostart_id),
            "autostart must start disabled");
    rivet::system::Autostart::SetEnabled(autostart_id, "/usr/bin/rivet-demo", true);
    require(rivet::system::Autostart::Enabled(autostart_id),
            "autostart did not persist after SetEnabled(true)");
    std::ifstream entry(config_dir / "autostart" / (autostart_id + ".desktop"));
    require(entry.is_open(), "the autostart entry file is missing");
    std::string contents((std::istreambuf_iterator<char>(entry)),
                         std::istreambuf_iterator<char>());
    require(contents.find("Exec=/usr/bin/rivet-demo") != std::string::npos,
            "the autostart entry lost its Exec line");
    rivet::system::Autostart::SetEnabled(autostart_id, "", false);
    require(!rivet::system::Autostart::Enabled(autostart_id),
            "autostart stayed enabled after SetEnabled(false)");
    std::filesystem::remove_all(config_dir);
  }

  if (has_capability(capabilities, "notification")) {
    progress("checking desktop notifications");
    std::uint32_t const first =
        rivet::system::Notifications::Notify("RivetIntegration", "integration",
                                             "Rivet Linux integration",
                                             "tagged notification");
    require(first != 0, "Notify returned no notification id");
    std::uint32_t const replaced = rivet::system::Notifications::Notify(
        "RivetIntegration", "integration", "Rivet Linux integration",
        "replacement notification");
    require(replaced == first, "a tagged notification must replace, not stack");
    rivet::system::Notifications::CloseTag("integration");
  } else {
    progress("skipping notifications (no session bus or notification host)");
  }

  if (has_capability(capabilities, "tray")) {
    progress("checking the StatusNotifierItem tray");
    require(rivet::system::TrayIcon::available(),
            "the tray capability must imply an available StatusNotifierItem watcher");
    rivet::system::TrayIcon tray("org.rivet.integration.test",
                                 "Rivet Linux integration",
                                 "network-transmit-receive");
    std::vector<rivet::system::TrayMenuItem> items;
    items.emplace_back("Open", [] {});
    items.emplace_back(rivet::system::TrayMenuItem::Type::separator);
    items.emplace_back("Disabled", [] {}, false);
    tray.set_menu(std::move(items));
    tray.set_tooltip("Rivet Linux integration", "tray self-check");
    // Registration went to the watcher; a desktop session answers the
    // layout/property fetches from the main loop this thread must run.
  } else {
    progress("skipping tray (no session bus or StatusNotifierItem watcher)");
  }

  if (has_capability(capabilities, "secure-storage")) {
    progress("checking Secret Service secure storage");
    std::string const service = "org.rivet.integration.test";
    std::string const account = "roundtrip";
    rivet::system::SecretStore::Set(service, account,
                                    {0x00, 0x01, 0x02, 0x00, 0xFF});
    auto stored = rivet::system::SecretStore::Get(service, account);
    require(stored.has_value(), "secure storage lost the stored secret");
    require((*stored == std::vector<std::uint8_t>{0x00, 0x01, 0x02, 0x00, 0xFF}),
            "secure storage returned different bytes");
    rivet::system::SecretStore::Remove(service, account);
    require(!rivet::system::SecretStore::Get(service, account).has_value(),
            "secure storage kept the secret after Remove");
  } else {
    progress("skipping secure storage (no Secret Service provider)");
  }

  progress("installing the crash hook");
  {
    auto state_dir = make_temp_directory("rivet-crash");
    TempEnvOverride state_override("XDG_STATE_HOME", state_dir.string());
    rivet::system::InstallCrashHook([](int) noexcept {}, "integration crash args");
    require(std::filesystem::exists(state_dir / "rivet" / "crash.log"),
            "the crash hook did not prepare its crash log");
    std::filesystem::remove_all(state_dir);
  }

  std::cout << "Rivet Linux system adapter checks passed\n";
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  std::vector<std::string> arguments(argv + 1, argv + argc);
  if (!arguments.empty() && arguments.front() == "--system") {
    try {
      return run_system_self_check(arguments);
    } catch (std::exception const& error) {
      std::cerr << "Rivet Linux system adapter failure: " << error.what() << "\n";
      return 1;
    }
  }
  try {
    auto const exe = executable_path();
    auto const root = exe.parent_path();
    auto const runtime = root / "runtime";

    rivet::linux_runtime::RacketRuntimeConfig config;
    config.executable_path = exe.string();
    config.petite_boot = (runtime / "petite.boot").string();
    config.scheme_boot = (runtime / "scheme.boot").string();
    config.racket_boot = (runtime / "racket.boot").string();
    config.backend_bundle = (root / "res" / "core.zo").string();
    config.module_name = "backend";
    config.entry_symbol = "start";
    config.max_pending_requests = 32;

    std::mutex diagnostics_mutex;
    std::vector<rivet::DiagnosticRecord> diagnostics;
    config.diagnostic_sink = [&](rivet::DiagnosticRecord const& record) {
      std::lock_guard lock(diagnostics_mutex);
      diagnostics.push_back(record);
    };

    auto require_diagnostic = [&](std::string const& layer,
                                  std::string const& event,
                                  std::string const& status) {
      std::lock_guard lock(diagnostics_mutex);
      for (auto const& record : diagnostics) {
        if (record.layer == layer && record.event == event &&
            record.status == status) {
          return;
        }
      }
      throw std::runtime_error("missing diagnostic: " + layer + "/" + event +
                               "/" + status);
    };

    progress("starting backend");
    rivet::linux_runtime::Backend backend(std::move(config));
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
        [async_value](rivet::linux_runtime::CallResult result) {
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
    std::vector<rivet::linux_runtime::PendingCall> cancellable;
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
    require_diagnostic("abi-bridge", "backend-init", "success");
    require_diagnostic("protocol", "handshake", "success");
    require_diagnostic("native-client", "rpc-dispatch", "success");
    require_diagnostic("native-runtime", "backend-stop", "success");
    std::cout << "Rivet embedded Linux round-trip passed\n";
    return 0;
  } catch (std::exception const& error) {
    std::cerr << "Rivet Linux integration failure: " << error.what() << "\n";
    return 1;
  }
}
