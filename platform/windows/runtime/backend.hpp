#pragma once

#include <cstdint>
#include <functional>
#include <future>
#include <memory>
#include <string>
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

using EventHandler = std::function<void(std::string const&, Value const&)>;

// Owns one embedded Racket CS instance and its RVT1 transport.
//
// Threading contract:
//   * start()/stop()/request()/cancel() may be used by the UI layer.
//   * Racket CS is booted and entered on a dedicated worker thread.
//   * one reader thread resolves native futures and invokes event handlers.
//   * event handlers therefore run on the reader thread and must dispatch to
//     the UI thread before touching WinUI objects.
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
  void cancel(std::uint64_t request_id);
  void set_event_handler(EventHandler handler);

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace rivet::windows
