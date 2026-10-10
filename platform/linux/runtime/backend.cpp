#include "backend.hpp"

#include <fcntl.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <cstring>
#include <exception>
#include <initializer_list>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>

#include "chezscheme.h"
#include "racketcs.h"
#include "rivet/detail/backend_completion_registry.hpp"

namespace rivet::linux_runtime {
namespace {

class UniqueFd {
 public:
  UniqueFd() = default;
  explicit UniqueFd(int fd) : fd_(fd) {}
  ~UniqueFd() { reset(); }

  UniqueFd(UniqueFd const&) = delete;
  UniqueFd& operator=(UniqueFd const&) = delete;

  UniqueFd(UniqueFd&& other) noexcept : fd_(other.release()) {}
  UniqueFd& operator=(UniqueFd&& other) noexcept {
    if (this != &other) {
      reset(other.release());
    }
    return *this;
  }

  int get() const noexcept { return fd_; }

  int release() noexcept {
    auto const result = fd_;
    fd_ = -1;
    return result;
  }

  void reset(int fd = -1) noexcept {
    if (fd_ >= 0) {
      (void)::close(fd_);
    }
    fd_ = fd;
  }

 private:
  int fd_{-1};
};

struct SocketEndpoints {
  UniqueFd native;
  UniqueFd server_read;
  UniqueFd server_write;
};

SocketEndpoints create_socket_endpoints() {
  int fds[2]{-1, -1};
#if defined(SOCK_CLOEXEC)
  int const rc = ::socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, fds);
#else
  int const rc = ::socketpair(AF_UNIX, SOCK_STREAM, 0, fds);
#endif
  if (rc != 0) {
    throw std::runtime_error("socketpair failed: " +
                             std::string(std::strerror(errno)));
  }

  UniqueFd native(fds[0]);
  UniqueFd server_read(fds[1]);
#if !defined(SOCK_CLOEXEC)
  // Platforms without SOCK_CLOEXEC (macOS): set the flag on both ends right
  // after the pair exists. Own the descriptors first so an fcntl failure
  // cannot leak either endpoint while the exception unwinds.
  for (int const fd : {native.get(), server_read.get()}) {
    int const flags = ::fcntl(fd, F_GETFD, 0);
    if (flags < 0 || ::fcntl(fd, F_SETFD, flags | FD_CLOEXEC) != 0) {
      throw std::runtime_error("fcntl(FD_CLOEXEC) failed: " +
                               std::string(std::strerror(errno)));
    }
  }
#endif
  UniqueFd server_write(::dup(server_read.get()));
  if (server_write.get() < 0) {
    throw std::runtime_error("dup failed: " +
                             std::string(std::strerror(errno)));
  }
  if (::fcntl(server_write.get(), F_SETFD, FD_CLOEXEC) != 0) {
    throw std::runtime_error("fcntl(FD_CLOEXEC) failed: " +
                             std::string(std::strerror(errno)));
  }
  return SocketEndpoints{std::move(native), std::move(server_read),
                         std::move(server_write)};
}

class FdTransport final : public rivet::Transport {
 public:
  explicit FdTransport(UniqueFd fd) : fd_(std::move(fd)) {}

  bool read_exact(std::uint8_t* destination, std::size_t size) override {
    std::size_t done = 0;
    while (done < size) {
      auto const count = ::read(fd_.get(), destination + done, size - done);
      if (count == 0) {
        if (done == 0) {
          return false;
        }
        throw std::runtime_error("unexpected EOF in RVT1 frame");
      }
      if (count < 0) {
        if (errno == EINTR) {
          continue;
        }
        throw std::runtime_error("RVT1 transport read failed: " +
                                 std::string(std::strerror(errno)));
      }
      done += static_cast<std::size_t>(count);
    }
    return true;
  }

  void write_all(std::uint8_t const* source, std::size_t size) override {
    std::size_t done = 0;
    while (done < size) {
      auto const count =
          ::send(fd_.get(), source + done, size - done, MSG_NOSIGNAL);
      if (count == 0) {
        throw std::runtime_error("RVT1 transport write made no progress");
      }
      if (count < 0) {
        if (errno == EINTR) {
          continue;
        }
        throw std::runtime_error("RVT1 transport write failed: " +
                                 std::string(std::strerror(errno)));
      }
      done += static_cast<std::size_t>(count);
    }
  }

  void flush() override {}

 private:
  UniqueFd fd_;
};

std::exception_ptr stopped_error() {
  return std::make_exception_ptr(std::runtime_error("Rivet backend stopped"));
}

std::string exception_message(std::exception_ptr error) noexcept {
  if (!error) return "unknown failure";
  try {
    std::rethrow_exception(error);
  } catch (std::exception const& exception) {
    return exception.what();
  } catch (...) {
    return "non-standard exception";
  }
}

ptr quoted_symbol(std::string const& name) {
  auto const quote = Sstring_to_symbol("quote");
  auto const module = Sstring_to_symbol(name.c_str());
  return Scons(quote, Scons(module, Snil));
}

}  // namespace

class Backend::Impl {
 public:
  explicit Impl(RacketRuntimeConfig config)
      : config_(std::move(config)),
        completions_(config_.max_pending_requests) {}

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
    emit_diagnostic("native-runtime", "backend-start", "begin");

    auto endpoints = create_socket_endpoints();
    auto server_read = std::move(endpoints.server_read);
    auto server_write = std::move(endpoints.server_write);
    transport_ = std::make_unique<FdTransport>(std::move(endpoints.native));
    emit_diagnostic("transport", "channel-opened", "success");

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
    try {
      ready_future_.get();
      emit_diagnostic("protocol", "handshake", "success");
      emit_diagnostic("native-runtime", "backend-start", "success");
    } catch (...) {
      emit_diagnostic("protocol", "handshake", "failure",
                      exception_message(std::current_exception()));
      emit_diagnostic("native-runtime", "backend-start", "failure",
                      exception_message(std::current_exception()));
      throw;
    }
  }

  void stop() {
    std::lock_guard stop_lock(stop_mutex_);

    {
      std::lock_guard state_lock(state_mutex_);
      if (!started_) {
        return;
      }
      stopping_.store(true, std::memory_order_release);
      running_.store(false, std::memory_order_release);
    }
    emit_diagnostic("native-runtime", "backend-stop", "begin");

    try {
      std::lock_guard write_lock(write_mutex_);
      auto* transport = transport_.get();
      if (transport != nullptr) {
        note_protocol_event("shutdown");
        write_frame(*transport, Frame{MessageType::Shutdown, 0, {}});
      }
    } catch (...) {
      // The server may already have exited. Joining below is authoritative.
    }

    if (racket_thread_.joinable()) {
      racket_thread_.join();
    }
    if (reader_thread_.joinable()) {
      reader_thread_.join();
    }

    {
      std::lock_guard write_lock(write_mutex_);
      std::lock_guard state_lock(state_mutex_);
      transport_.reset();
    }

    completions_.reject_all(stopped_error());
    emit_diagnostic("native-runtime", "backend-stop", "success");
  }

  bool running() const noexcept {
    return running_.load(std::memory_order_acquire);
  }

  PendingCall request(std::string rpc_name, Value::List arguments) {
    if (!running()) {
      throw std::runtime_error("Rivet backend is not running");
    }
    auto pending = completions_.insert_future();
    submit_request(pending.id, std::move(rpc_name), std::move(arguments));
    return PendingCall{pending.id, std::move(pending.result)};
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
    if (!running()) {
      throw std::runtime_error("Rivet backend is not running");
    }
    auto const id = completions_.insert_completion(std::move(completion));
    submit_request(id, std::move(rpc_name), std::move(arguments));
    return id;
  }

  void cancel(std::uint64_t request_id) {
    if (!running()) {
      return;
    }

    std::lock_guard write_lock(write_mutex_);
    if (!running()) {
      return;
    }
    (void)completions_.request_cancel(request_id, [&] {
      auto* transport = transport_.get();
      if (transport != nullptr) {
        note_protocol_event("cancel");
        emit_diagnostic("native-client", "request-cancel", "begin", "",
                        request_id);
        write_frame(*transport, Frame{MessageType::Cancel, request_id, {}});
      }
    });
  }

  void set_event_handler(EventHandler handler) {
    std::lock_guard lock(event_mutex_);
    event_handler_ = std::move(handler);
  }

 private:
  void note_protocol_event(std::string event) noexcept {
    std::lock_guard lock(diagnostic_mutex_);
    last_protocol_event_ = std::move(event);
  }

  void emit_diagnostic(std::string layer,
                       std::string event,
                       std::string status,
                       std::string message = {},
                       std::optional<std::uint64_t> request_id = std::nullopt)
      noexcept {
    DiagnosticRecord record;
    {
      std::lock_guard lock(diagnostic_mutex_);
      record = DiagnosticRecord{std::move(layer), std::move(event),
                                std::move(status), last_protocol_event_,
                                request_id, std::move(message)};
    }
    try {
      if (config_.diagnostic_sink) config_.diagnostic_sink(record);
    } catch (...) {
      // Diagnostics must never become a new runtime failure path.
    }
  }

  void submit_request(std::uint64_t id,
                      std::string rpc_name,
                      Value::List arguments) {
    note_protocol_event("request");
    emit_diagnostic("native-client", "rpc-dispatch", "begin", rpc_name, id);

    Value::List request;
    request.reserve(arguments.size() + 1);
    request.emplace_back(std::move(rpc_name));
    for (auto& argument : arguments) {
      request.emplace_back(std::move(argument));
    }

    try {
      std::lock_guard write_lock(write_mutex_);
      if (!running()) {
        throw std::runtime_error("Rivet backend is not running");
      }
      auto* transport = transport_.get();
      if (transport == nullptr) {
        throw std::runtime_error("Rivet backend transport is closed");
      }
      write_frame(*transport,
                  Frame{MessageType::Request, id,
                        encode_value(Value(std::move(request)))});

      bool const send_deferred_cancel = completions_.mark_request_sent(id);
      if (send_deferred_cancel) {
        write_frame(*transport, Frame{MessageType::Cancel, id, {}});
      }
    } catch (...) {
      emit_diagnostic("transport", "request-write", "failure",
                      exception_message(std::current_exception()), id);
      completions_.fail(id, std::current_exception());
    }
  }

  void racket_main(UniqueFd server_read, UniqueFd server_write) noexcept {
    emit_diagnostic("abi-bridge", "backend-init", "begin");
    bool initialized = false;
    try {
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

      racket_boot(&boot);
      racket_embedded_load_file(config_.backend_bundle.c_str(), 1);

      auto const module = quoted_symbol(config_.module_name);
      auto const entry = Sstring_to_symbol(config_.entry_symbol.c_str());
      auto const results = racket_dynamic_require(module, entry);
      auto const procedure = Scar(results);
      auto const args =
          Scons(Sfixnum(server_read.get()),
                Scons(Sfixnum(server_write.get()), Snil));

      initialized = true;
      emit_diagnostic("abi-bridge", "backend-init", "success");

      // The ports created by serve-fds own distinct descriptors referring to
      // the same full-duplex socket. They close them during server teardown.
      (void)server_read.release();
      (void)server_write.release();
      (void)racket_apply(procedure, args);
      Sscheme_deinit();
      emit_diagnostic(
          "racket-backend", "backend-exit",
          stopping_.load(std::memory_order_acquire) ? "success" : "failure",
          stopping_.load(std::memory_order_acquire)
              ? ""
              : "backend returned before native shutdown");
    } catch (...) {
      emit_diagnostic(initialized ? "racket-backend" : "abi-bridge",
                      initialized ? "backend-exit" : "backend-init", "failure",
                      exception_message(std::current_exception()));
      // Owned descriptors are closed on native startup failures. Once they are
      // transferred, serve-fds owns their lifetime.
    }

    running_.store(false, std::memory_order_release);
  }

  void reader_main() noexcept {
    try {
      for (;;) {
        FdTransport* transport = nullptr;
        {
          std::lock_guard lock(state_mutex_);
          transport = transport_.get();
        }
        if (transport == nullptr) {
          break;
        }

        auto frame = read_frame(*transport);
        if (!frame.has_value()) {
          if (!stopping_.load(std::memory_order_acquire)) {
            emit_diagnostic("transport", "channel-closed", "failure",
                            "Rivet transport closed unexpectedly");
          }
          break;
        }

        switch (frame->type) {
          case MessageType::Hello:
            note_protocol_event("hello");
            accept_hello(*frame);
            break;
          case MessageType::Response:
            note_protocol_event("response");
            emit_diagnostic("native-client", "rpc-dispatch", "success", "",
                            frame->id);
            completions_.resolve(frame->id, decode_value(frame->payload));
            break;
          case MessageType::Error: {
            note_protocol_event("error");
            auto error_value = decode_value(frame->payload);
            std::string message{"Rivet backend error"};
            if (auto* text = std::get_if<std::string>(&error_value.data)) {
              message = *text;
            }
            emit_diagnostic("racket-backend", "rpc-dispatch", "failure",
                            message, frame->id);
            completions_.fail(
                frame->id,
                std::make_exception_ptr(std::runtime_error(std::move(message))));
            break;
          }
          case MessageType::Event:
            note_protocol_event("event");
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
      emit_diagnostic("protocol", "reader-loop", "failure",
                      exception_message(std::current_exception()));
      set_ready_exception(std::current_exception());
      completions_.reject_all(std::current_exception());
    }

    running_.store(false, std::memory_order_release);
    completions_.reject_all(stopped_error());
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

  RacketRuntimeConfig config_;
  mutable std::mutex state_mutex_;
  std::mutex stop_mutex_;
  std::mutex write_mutex_;
  std::mutex event_mutex_;
  std::mutex diagnostic_mutex_;
  std::unique_ptr<FdTransport> transport_;
  std::thread racket_thread_;
  std::thread reader_thread_;
  detail::BackendCompletionRegistry<Value, CallResult, CompletionHandler>
      completions_;
  EventHandler event_handler_;
  std::atomic<bool> running_{false};
  std::atomic<bool> hello_seen_{false};
  std::atomic<bool> stopping_{false};
  std::string last_protocol_event_{"none"};
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

}  // namespace rivet::linux_runtime
