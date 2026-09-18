#include "backend.hpp"
#include "win32_pipe_transport.hpp"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <fcntl.h>
#include <io.h>

#include <atomic>
#include <exception>
#include <future>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>

#include "chezscheme.h"
#include "racketcs.h"

namespace rivet::windows {
namespace {

class UniqueHandle {
 public:
  UniqueHandle() = default;
  explicit UniqueHandle(HANDLE handle) : handle_(handle) {}
  ~UniqueHandle() { reset(); }

  UniqueHandle(UniqueHandle const&) = delete;
  UniqueHandle& operator=(UniqueHandle const&) = delete;

  UniqueHandle(UniqueHandle&& other) noexcept : handle_(other.release()) {}
  UniqueHandle& operator=(UniqueHandle&& other) noexcept {
    if (this != &other) {
      reset(other.release());
    }
    return *this;
  }

  HANDLE get() const noexcept { return handle_; }

  HANDLE release() noexcept {
    auto const result = handle_;
    handle_ = INVALID_HANDLE_VALUE;
    return result;
  }

  void reset(HANDLE handle = INVALID_HANDLE_VALUE) noexcept {
    if (handle_ != INVALID_HANDLE_VALUE && handle_ != nullptr) {
      ::CloseHandle(handle_);
    }
    handle_ = handle;
  }

 private:
  HANDLE handle_{INVALID_HANDLE_VALUE};
};

struct PipePair {
  UniqueHandle read;
  UniqueHandle write;
};

PipePair create_pipe() {
  HANDLE read = INVALID_HANDLE_VALUE;
  HANDLE write = INVALID_HANDLE_VALUE;
  if (!::CreatePipe(&read, &write, nullptr, 0)) {
    throw std::runtime_error("CreatePipe failed with Win32 error " +
                             std::to_string(::GetLastError()));
  }
  return PipePair{UniqueHandle(read), UniqueHandle(write)};
}

int handle_to_binary_fd(UniqueHandle handle, int access_flags) {
  auto const raw = handle.release();
  auto const fd = _open_osfhandle(reinterpret_cast<intptr_t>(raw),
                                  access_flags | _O_BINARY);
  if (fd == -1) {
    ::CloseHandle(raw);
    throw std::runtime_error("_open_osfhandle failed");
  }
  return fd;
}

std::exception_ptr stopped_error() {
  return std::make_exception_ptr(std::runtime_error("Rivet backend stopped"));
}

ptr quoted_symbol(std::string const& name) {
  auto const quote = Sstring_to_symbol("quote");
  auto const module = Sstring_to_symbol(name.c_str());
  return Scons(quote, Scons(module, Snil));
}

}  // namespace

class Backend::Impl {
 public:
  explicit Impl(RacketRuntimeConfig config) : config_(std::move(config)) {}

  ~Impl() {
    try {
      stop();
    } catch (...) {
      // Destructors cannot surface shutdown failures.
    }
  }

  void start() {
    std::unique_lock state_lock(state_mutex_);
    if (started_) {
      throw std::logic_error("Rivet backend instances cannot be restarted");
    }
    started_ = true;

    auto request_pipe = create_pipe();   // native -> Racket
    auto response_pipe = create_pipe();  // Racket -> native

    auto server_read = std::move(request_pipe.read);
    auto server_write = std::move(response_pipe.write);

    transport_ = std::make_unique<Win32PipeTransport>(
        response_pipe.read.release(), request_pipe.write.release());

    ready_ = std::make_shared<std::promise<void>>();
    ready_future_ = ready_->get_future();
    running_.store(true, std::memory_order_release);

    reader_thread_ = std::thread([this] { reader_main(); });
    racket_thread_ = std::thread(
        [this, server_read = std::move(server_read),
         server_write = std::move(server_write)]() mutable {
          racket_main(std::move(server_read), std::move(server_write));
        });

    state_lock.unlock();

    // The first valid frame from Racket is Hello. Waiting for it makes start
    // fail synchronously when boot files, core.zo, or the entry point are bad.
    ready_future_.get();
  }

  void stop() {
    std::unique_lock state_lock(state_mutex_);
    if (!started_) {
      return;
    }

    auto* transport = transport_.get();
    auto const was_running = running_.exchange(false, std::memory_order_acq_rel);
    state_lock.unlock();

    if (was_running && transport != nullptr) {
      try {
        std::lock_guard write_lock(write_mutex_);
        write_frame(*transport, Frame{MessageType::Shutdown, 0, {}});
      } catch (...) {
        // The server may already have exited. Joining below is authoritative.
      }
    }

    if (racket_thread_.joinable()) {
      racket_thread_.join();
    }

    // Closing the native write end helps wake a failed server that never
    // reached the Racket loop; the server output end closing wakes the reader.
    {
      std::lock_guard lock(state_mutex_);
      transport_.reset();
    }

    if (reader_thread_.joinable()) {
      reader_thread_.join();
    }

    reject_all(stopped_error());
  }

  bool running() const noexcept {
    return running_.load(std::memory_order_acquire);
  }

  PendingCall request(std::string rpc_name, Value::List arguments) {
    if (!running()) {
      throw std::runtime_error("Rivet backend is not running");
    }

    auto promise = std::make_unique<std::promise<Value>>();
    auto future = promise->get_future();
    auto const id = next_id_.fetch_add(1, std::memory_order_relaxed);

    {
      std::lock_guard pending_lock(pending_mutex_);
      pending_.emplace(id, std::move(promise));
    }

    Value::List request;
    request.reserve(arguments.size() + 1);
    request.emplace_back(std::move(rpc_name));
    for (auto& argument : arguments) {
      request.emplace_back(std::move(argument));
    }

    try {
      std::lock_guard write_lock(write_mutex_);
      auto* transport = transport_.get();
      if (transport == nullptr) {
        throw std::runtime_error("Rivet backend transport is closed");
      }
      write_frame(*transport,
                  Frame{MessageType::Request, id,
                        encode_value(Value(std::move(request)))});
    } catch (...) {
      fail_request(id, std::current_exception());
    }

    return PendingCall{id, std::move(future)};
  }

  std::future<Value> call(std::string rpc_name, Value::List arguments) {
    return request(std::move(rpc_name), std::move(arguments)).result;
  }

  void cancel(std::uint64_t request_id) {
    if (!running()) {
      return;
    }
    {
      std::lock_guard lock(pending_mutex_);
      if (pending_.find(request_id) == pending_.end()) {
        return;
      }
    }
    std::lock_guard write_lock(write_mutex_);
    auto* transport = transport_.get();
    if (transport != nullptr) {
      write_frame(*transport, Frame{MessageType::Cancel, request_id, {}});
    }
  }

  void set_event_handler(EventHandler handler) {
    std::lock_guard lock(event_mutex_);
    event_handler_ = std::move(handler);
  }

 private:
  void racket_main(UniqueHandle server_read, UniqueHandle server_write) noexcept {
    try {
      auto const in_fd = handle_to_binary_fd(std::move(server_read), _O_RDONLY);
      auto const out_fd = handle_to_binary_fd(std::move(server_write), _O_WRONLY);

      racket_boot_arguments_t boot{};
      boot.boot1_path = config_.petite_boot.c_str();
      boot.boot2_path = config_.scheme_boot.c_str();
      boot.boot3_path = config_.racket_boot.c_str();
      boot.exec_file = config_.executable_path.c_str();
      if (!config_.collects_dir.empty()) {
        boot.collects_dir = config_.collects_dir.c_str();
      }
      if (!config_.config_dir.empty()) {
        boot.config_dir = config_.config_dir.c_str();
      }
      if (!config_.dll_dir.empty()) {
        boot.dll_dir = const_cast<wchar_t*>(config_.dll_dir.c_str());
      }

      racket_boot(&boot);
      racket_embedded_load_file(config_.backend_bundle.c_str(), 1);

      auto const module = quoted_symbol(config_.module_name);
      auto const entry = Sstring_to_symbol(config_.entry_symbol.c_str());
      // racket_dynamic_require returns the requested export directly.
      // Only racket_apply wraps procedure results in a list.
      auto const procedure = racket_dynamic_require(module, entry);
      auto const args = Scons(Sfixnum(in_fd), Scons(Sfixnum(out_fd), Snil));

      // The application entry procedure owns the CRT descriptors through
      // `serve-fds` and normally returns only after receiving Shutdown.
      (void)racket_apply(procedure, args);
      Sscheme_deinit();
    } catch (...) {
      // Closing server handles/fds makes the native reader observe EOF. Racket
      // exceptions must be contained on the Racket side because the embedding
      // API requires entry procedures not to escape through racket_apply.
    }

    running_.store(false, std::memory_order_release);
  }

  void reader_main() noexcept {
    try {
      for (;;) {
        Win32PipeTransport* transport = nullptr;
        {
          std::lock_guard lock(state_mutex_);
          transport = transport_.get();
        }
        if (transport == nullptr) {
          break;
        }

        auto frame = read_frame(*transport);
        if (!frame.has_value()) {
          break;
        }

        switch (frame->type) {
          case MessageType::Hello:
            accept_hello(*frame);
            break;
          case MessageType::Response:
            resolve_request(frame->id, decode_value(frame->payload));
            break;
          case MessageType::Error: {
            auto error_value = decode_value(frame->payload);
            std::string message{"Rivet backend error"};
            if (auto* text = std::get_if<std::string>(&error_value.data)) {
              message = *text;
            }
            fail_request(
                frame->id,
                std::make_exception_ptr(std::runtime_error(std::move(message))));
            break;
          }
          case MessageType::Event:
            deliver_event(decode_value(frame->payload));
            break;
          default:
            throw std::runtime_error("unexpected Rivet message from backend");
        }
      }

      if (!hello_seen_.load(std::memory_order_acquire)) {
        set_ready_exception(stopped_error());
      }
    } catch (...) {
      set_ready_exception(std::current_exception());
      reject_all(std::current_exception());
    }

    running_.store(false, std::memory_order_release);
    reject_all(stopped_error());
  }

  void accept_hello(Frame const& frame) {
    auto hello = decode_value(frame.payload);
    auto const* list = std::get_if<Value::List>(&hello.data);
    if (list == nullptr || list->size() != 2) {
      throw std::runtime_error("invalid Rivet Hello payload");
    }

    auto const* name = std::get_if<std::string>(&(*list)[0].data);
    auto const* version = std::get_if<std::int64_t>(&(*list)[1].data);
    if (name == nullptr || *name != "rivet" || version == nullptr ||
        *version != kProtocolVersion) {
      throw std::runtime_error("Rivet protocol handshake mismatch");
    }

    bool expected = false;
    if (!hello_seen_.compare_exchange_strong(expected, true,
                                             std::memory_order_acq_rel)) {
      throw std::runtime_error("duplicate Rivet Hello frame");
    }
    ready_->set_value();
  }

  void deliver_event(Value value) noexcept {
    try {
      auto const* list = std::get_if<Value::List>(&value.data);
      if (list == nullptr || list->size() != 2) {
        return;
      }
      auto const* name = std::get_if<std::string>(&(*list)[0].data);
      if (name == nullptr) {
        return;
      }

      EventHandler handler;
      {
        std::lock_guard lock(event_mutex_);
        handler = event_handler_;
      }
      if (handler) {
        try {
          handler(*name, (*list)[1]);
        } catch (...) {
          // Application event handlers are isolated from the transport loop.
        }
      }
    } catch (...) {
      // Malformed events are ignored; request/response transport stays alive.
    }
  }

  void set_ready_exception(std::exception_ptr error) noexcept {
    bool expected = false;
    if (hello_seen_.compare_exchange_strong(expected, true,
                                            std::memory_order_acq_rel)) {
      try {
        ready_->set_exception(error);
      } catch (...) {
      }
    }
  }

  std::unique_ptr<std::promise<Value>> take_request(std::uint64_t id) {
    std::lock_guard lock(pending_mutex_);
    auto it = pending_.find(id);
    if (it == pending_.end()) {
      return nullptr;
    }
    auto promise = std::move(it->second);
    pending_.erase(it);
    return promise;
  }

  void resolve_request(std::uint64_t id, Value value) {
    auto promise = take_request(id);
    if (promise != nullptr) {
      promise->set_value(std::move(value));
    }
  }

  void fail_request(std::uint64_t id, std::exception_ptr error) noexcept {
    auto promise = take_request(id);
    if (promise != nullptr) {
      try {
        promise->set_exception(error);
      } catch (...) {
      }
    }
  }

  void reject_all(std::exception_ptr error) noexcept {
    std::unordered_map<std::uint64_t, std::unique_ptr<std::promise<Value>>> pending;
    {
      std::lock_guard lock(pending_mutex_);
      pending.swap(pending_);
    }
    for (auto& [id, promise] : pending) {
      (void)id;
      try {
        promise->set_exception(error);
      } catch (...) {
      }
    }
  }

  RacketRuntimeConfig config_;
  mutable std::mutex state_mutex_;
  std::mutex write_mutex_;
  std::mutex pending_mutex_;
  std::mutex event_mutex_;
  std::unique_ptr<Win32PipeTransport> transport_;
  std::thread racket_thread_;
  std::thread reader_thread_;
  std::unordered_map<std::uint64_t, std::unique_ptr<std::promise<Value>>> pending_;
  EventHandler event_handler_;
  std::atomic<std::uint64_t> next_id_{1};
  std::atomic<bool> running_{false};
  std::atomic<bool> hello_seen_{false};
  bool started_{false};
  std::shared_ptr<std::promise<void>> ready_;
  std::future<void> ready_future_;
};

Backend::Backend(RacketRuntimeConfig config)
    : impl_(std::make_unique<Impl>(std::move(config))) {}

Backend::~Backend() = default;

void Backend::start() { impl_->start(); }
void Backend::stop() { impl_->stop(); }
bool Backend::running() const noexcept { return impl_->running(); }

PendingCall Backend::request(std::string rpc_name, Value::List arguments) {
  return impl_->request(std::move(rpc_name), std::move(arguments));
}

std::future<Value> Backend::call(std::string rpc_name, Value::List arguments) {
  return impl_->call(std::move(rpc_name), std::move(arguments));
}

void Backend::cancel(std::uint64_t request_id) {
  impl_->cancel(request_id);
}

void Backend::set_event_handler(EventHandler handler) {
  impl_->set_event_handler(std::move(handler));
}

}  // namespace rivet::windows
