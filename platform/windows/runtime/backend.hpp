#pragma once

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

// Owns one embedded Racket CS instance and its RPC transport.
//
// Threading contract:
//   * start()/stop()/call() may be used by the UI layer.
//   * Racket CS is booted and entered on a dedicated worker thread.
//   * one reader thread resolves native futures from Racket responses.
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

  std::future<Value> call(std::string rpc_name, Value::List arguments = {});

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace rivet::windows
