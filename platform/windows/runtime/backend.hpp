#pragma once

#include <cstdint>
#include <exception>
#include <functional>
#include <future>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "rivet/protocol.hpp"

namespace rivet::windows {

struct RacketRuntimeConfig {
  std::string executable_path;
  std::string petite_boot;
  std::string scheme_boot;
  std::string racket_boot;
  std::string backend_bundle;
  std::string module_name{"backend"};
  std::string entry_symbol{"start"};
  std::string collects_dir;
  std::string config_dir;
  std::wstring dll_dir;
};

struct PendingCall {
  std::uint64_t id{};
  std::future<Value> result;
};

struct CallResult {
  std::optional<Value> value;
  std::exception_ptr error;

  bool succeeded() const noexcept { return value.has_value() && !error; }
};

using CompletionHandler = std::function<void(CallResult)>;
using EventHandler = std::function<void(std::string const&, Value const&)>;

// Owns one embedded Racket CS instance and its RVT1 transport.
//
// Threading contract:
//   * start()/stop()/request()/request_async()/cancel() may be used by the UI layer.
//   * Racket CS is booted and entered on a dedicated worker thread.
//   * one reader thread resolves native futures and receives normal RPC completions.
//   * completion handlers are not UI-thread-affine: normal replies run them on
//     the reader thread, while immediate submission/shutdown failures can run
//     them on the initiating/shutdown thread. Always dispatch before touching
//     WinUI objects.
//   * event handlers run on the reader thread and require the same UI dispatch.
//   * completion/event handler exceptions are isolated from the transport loop.
//   * no Racket value crosses either native thread boundary.
class Backend final {
 public:
  explicit Backend(RacketRuntimeConfig config);
  ~Backend();

  Backend(Backend const&) = delete;
  Backend& operator=(Backend const&) = delete;

  void start();
  void stop();
  bool running() const noexcept;

  PendingCall request(std::string rpc_name, Value::List arguments = {});
  std::future<Value> call(std::string rpc_name, Value::List arguments = {});

  // Non-blocking request API. The returned id can be passed to cancel(). Every
  // accepted request produces exactly one completion unless the completion
  // itself throws, in which case the exception is isolated by the runtime.
  std::uint64_t request_async(std::string rpc_name,
                              Value::List arguments,
                              CompletionHandler completion);

  std::future<Value> get_state(std::string name) {
    Value::List args;
    args.emplace_back(std::move(name));
    return call("$state/get", std::move(args));
  }

  std::future<Value> set_state(std::string name, Value value) {
    Value::List args;
    args.emplace_back(std::move(name));
    args.emplace_back(std::move(value));
    return call("$state/set", std::move(args));
  }

  std::uint64_t get_state_async(std::string name, CompletionHandler completion) {
    Value::List args;
    args.emplace_back(std::move(name));
    return request_async("$state/get", std::move(args), std::move(completion));
  }

  std::uint64_t set_state_async(std::string name,
                                Value value,
                                CompletionHandler completion) {
    Value::List args;
    args.emplace_back(std::move(name));
    args.emplace_back(std::move(value));
    return request_async("$state/set", std::move(args), std::move(completion));
  }

  void cancel(std::uint64_t request_id);
  void set_event_handler(EventHandler handler);

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace rivet::windows
