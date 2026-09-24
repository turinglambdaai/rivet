#include "backend.hpp"
#include "win32_pipe_transport.hpp"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

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
#include "rivet/detail/request_id_allocator.hpp"

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

struct PendingRequest {
  std::unique_ptr<std::promise<Value>> promise;
  CompletionHandler completion;
  detail::RequestCancellationGate cancellation;
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
    auto promise = std::make_unique<std::promise<Value>>();
    auto future = promise->get_future();
    auto const id = submit_request(
        std::move(rpc_name), std::move(arguments),
        PendingRequest{std::move(promise), CompletionHandler{}});
    return PendingCall{id, std::move(future)};
  }

  std::future<Value> call(std::string rpc_name, Value::List arguments) {
    return request(std::move(rpc_name), std::move(arguments)).result;
  }

  std::uint64_t request_async(std::string rpc_name,
                              Value::List arguments,
                              CompletionHandler completion) {
    if (!completion) {
      throw std::invalid_argument("Rivet async completion handler is empty");
    }
    return submit_request(
        std::move(rpc_name), std::move(arguments),
        PendingRequest{nullptr, std::move(completion)});
  }

  void cancel(std::uint64_t request_id) {
    if (!running()) {
      return;
    }

    bool should_send = false;
    {
      std::lock_guard lock(pending_mutex_);
      auto it = pending_.find(request_id);
      if (it == pending_.end()) {
        return;
      }
      // Before Request transmission, cancellation is only latched. Whichever
      // side first observes that Request is on the wire claims the single
      // permission to emit Cancel.
      should_send = it->second.cancellation.request_cancel();
    }
    if (!should_send) {
      return;
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
  std::uint64_t submit_request(std::string rpc_name,
                               Value::List arguments,
                               PendingRequest pending) {
    if (!running()) {
      throw std::runtime_error("Rivet backend is not running");
    }

    std::uint64_t id = 0;
    {
      // Selection and insertion share one lock. A wrapped allocator therefore
      // cannot hand the same still-pending id to two concurrent submitters.
      std::lock_guard pending_lock(pending_mutex_);
      id = request_ids_.allocate(
          pending_.size(),
          [this](std::uint64_t candidate) {
            return pending_.find(candidate) != pending_.end();
          });
      auto const [it, inserted] = pending_.emplace(id, std::move(pending));
      (void)it;
      if (!inserted) {
        throw std::logic_error("Rivet request id collision");
      }
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

      bool send_deferred_cancel = false;
      {
        std::lock_guard pending_lock(pending_mutex_);
        auto it = pending_.find(id);
        if (it != pending_.end()) {
          send_deferred_cancel = it->second.cancellation.mark_request_sent();
        }
      }
      // Keep write_mutex_ while emitting a latched cancellation so no other
      // frame can interleave between this Request and its deferred Cancel.
      if (send_deferred_cancel) {
        write_frame(*transport, Frame{MessageType::Cancel, id, {}});
      }
    } catch (...) {
      fail_request(id, std::current_exception());
    }

    return id;
  }

  void racket_main(UniqueHandle server_read, UniqueHandle server_write) noexcept {
    try {
      // `unsafe-file-descriptor->port` consumes a Rktio system descriptor.
      // On Windows that descriptor is the native HANDLE value, not a CRT fd.
      // Keep ownership in UniqueHandle through startup and transfer it to the
      // Racket ports immediately before entering the application procedure.
      auto const in_handle = reinterpret_cast<intptr_t>(server_read.get());
      auto const out_handle = reinterpret_cast<intptr_t>(server_write.get());

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
      // racket_dynamic_require is implemented in terms of racket_apply and
      // therefore returns a list of result values. The requested export is
      // the first result.
      auto const results = racket_dynamic_require(module, entry);
      auto const procedure = Scar(results);
      auto const args =
          Scons(Sfixnum(in_handle), Scons(Sfixnum(out_handle), Snil));

      // From this point the Racket ports created by serve-fds own the native
      // handles and close them during server teardown.
      (void)server_read.release();
      (void)server_write.release();
      (void)racket_apply(procedure, args);
      Sscheme_deinit();
    } catch (...) {
      // UniqueHandle closes endpoints for native startup failures. Once the
      // handles are transferred, serve-fds owns their lifetime on the Racket
      // side. Closing the server ends makes the native reader observe EOF.
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

  std::optional<PendingRequest> take_request(std::uint64_t id) {
    std::lock_guard lock(pending_mutex_);
    auto it = pending_.find(id);
    if (it == pending_.end()) {
      return std::nullopt;
    }
    auto pending = std::move(it->second);
    pending_.erase(it);
    return pending;
  }

  void resolve_request(std::uint64_t id, Value value) noexcept {
    auto pending = take_request(id);
    if (!pending.has_value()) {
      return;
    }

    if (pending->promise != nullptr) {
      try {
        pending->promise->set_value(std::move(value));
      } catch (...) {
      }
      return;
    }

    if (pending->completion) {
      try {
        pending->completion(CallResult{std::move(value), nullptr});
      } catch (...) {
        // Application completions are isolated from the transport loop.
      }
    }
  }

  void fail_request(std::uint64_t id, std::exception_ptr error) noexcept {
    auto pending = take_request(id);
    if (!pending.has_value()) {
      return;
    }

    if (pending->promise != nullptr) {
      try {
        pending->promise->set_exception(error);
      } catch (...) {
      }
      return;
    }

    if (pending->completion) {
      try {
        pending->completion(CallResult{std::nullopt, error});
      } catch (...) {
        // Application completions are isolated from the transport loop.
      }
    }
  }

  void reject_all(std::exception_ptr error) noexcept {
    std::unordered_map<std::uint64_t, PendingRequest> pending;
    {
      std::lock_guard lock(pending_mutex_);
      pending.swap(pending_);
    }
    for (auto& [id, request] : pending) {
      (void)id;
      if (request.promise != nullptr) {
        try {
          request.promise->set_exception(error);
        } catch (...) {
        }
      } else if (request.completion) {
        try {
          request.completion(CallResult{std::nullopt, error});
        } catch (...) {
          // Application completions must not interrupt shutdown.
        }
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
  std::unordered_map<std::uint64_t, PendingRequest> pending_;
  EventHandler event_handler_;
  detail::RequestIdAllocator request_ids_;
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

std::uint64_t Backend::request_async(std::string rpc_name,
                                     Value::List arguments,
                                     CompletionHandler completion) {
  return impl_->request_async(
      std::move(rpc_name), std::move(arguments), std::move(completion));
}

void Backend::cancel(std::uint64_t request_id) {
  impl_->cancel(request_id);
}

void Backend::set_event_handler(EventHandler handler) {
  impl_->set_event_handler(std::move(handler));
}

}  // namespace rivet::windows
