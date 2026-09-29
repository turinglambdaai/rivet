#include "backend.hpp"

#include <fcntl.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <atomic>
#include <cstring>
#include <map>
#include <mutex>
#include <stdexcept>
#include <utility>
#include <vector>

// racketcs C API. The same symbols the Windows backend links against are
// exported by libracketcs on every platform; they are declared here because
// libracketcs ships without a public header for the embedding entry points.
extern "C" {
struct racket_boot_arguments_t {
  char const* boot1_path;
  char const* boot2_path;
  char const* boot3_path;
  char const* exec_file;
  char const* collects_dir;
  char const* config_dir;
  char const* dll_dir;
  void* reserved1;
  void* reserved2;
};

void racket_boot(racket_boot_arguments_t* args);
void racket_embedded_load_file(char const* filename, int with_path);
void* racket_dynamic_require(void* quoted_module_symbol, void* symbol);
void* racket_apply(void* procedure, void* args);
void* Scons(void* a, void* d);
void* Snil(void);
void* Sfixnum(long v);
void* Sstring_to_symbol(char const* s);
void* Scar(void* pair);
int Sscheme_deinit();
}

namespace rivet::linux {
namespace {

// 'module as a quoted symbol, the shape racket_dynamic_require expects.
void* quoted_symbol(char const* name) {
  auto const quote = Sstring_to_symbol("quote");
  auto const module = Sstring_to_symbol(name);
  return Scons(quote, Scons(module, Snil()));
}

// A rivet::Transport over a POSIX fd. Ownership is explicit: the long-lived
// reader transport borrows its fd (the socketpair end lives as long as the
// process), and per-request write transports borrow it too. Nothing here
// closes the fd; process teardown and the Racket side own its lifetime.
class FdTransport final : public rivet::Transport {
 public:
  explicit FdTransport(int fd) : fd_(fd) {}

  bool read_exact(std::uint8_t* destination, std::size_t size) override {
    std::size_t done = 0;
    while (done < size) {
      ssize_t n = ::read(fd_, destination + done, size - done);
      if (n == 0) {
        return done == 0;  // clean EOF before any byte
      }
      if (n < 0) {
        if (errno == EINTR) continue;
        return false;
      }
      done += static_cast<std::size_t>(n);
    }
    return true;
  }

  void write_all(std::uint8_t const* source, std::size_t size) override {
    std::size_t done = 0;
    while (done < size) {
      ssize_t n = ::write(fd_, source + done, size - done);
      if (n < 0) {
        if (errno == EINTR) continue;
        throw std::runtime_error("RVT1 transport write failed");
      }
      done += static_cast<std::size_t>(n);
    }
  }

  void flush() override {}

 private:
  int fd_;
};

}  // namespace

struct Backend::Impl {
  RacketRuntimeConfig config;
  std::atomic<bool> running{false};

  std::mutex state_mutex;
  std::map<std::uint64_t, CompletionHandler> pending;
  std::uint64_t next_request_id{1};
  EventHandler event_handler;

  int socket_fd{-1};  // our end of the RVT1 socketpair

  std::thread racket_thread;
  std::thread reader_thread;

  explicit Impl(RacketRuntimeConfig cfg) : config(std::move(cfg)) {}

  std::uint64_t allocate_request_id() {
    std::lock_guard lock(state_mutex);
    return next_request_id++;
  }

  void resolve_request(std::uint64_t id, Value value) {
    CompletionHandler handler;
    {
      std::lock_guard lock(state_mutex);
      auto it = pending.find(id);
      if (it == pending.end()) return;
      handler = std::move(it->second);
      pending.erase(it);
    }
    handler(CallResult{std::move(value), nullptr});
  }

  void fail_request(std::uint64_t id, std::exception_ptr error) {
    CompletionHandler handler;
    {
      std::lock_guard lock(state_mutex);
      auto it = pending.find(id);
      if (it == pending.end()) return;
      handler = std::move(it->second);
      pending.erase(it);
    }
    handler(CallResult{std::nullopt, std::move(error)});
  }

  void fail_all(std::exception_ptr error) {
    std::map<std::uint64_t, CompletionHandler> drained;
    {
      std::lock_guard lock(state_mutex);
      drained = std::move(pending);
      pending.clear();
    }
    for (auto& [id, handler] : drained) {
      handler(CallResult{std::nullopt, error});
    }
  }

  void racket_main() noexcept {
    // One socketpair carries the whole RVT1 connection: requests go from
    // socket_fd into the backend, Responses/Events come back on the same
    // duplex socket. serve-fds consumes both fd numbers; they name one fd,
    // which keeps the transport as close to the named-pipe shape as POSIX
    // allows.
    int fds[2];
    if (::socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) {
      running.store(false, std::memory_order_release);
      return;
    }
    socket_fd = fds[0];
    int const backend_fd = fds[1];

    try {
      racket_boot_arguments_t boot{};
      std::memset(&boot, 0, sizeof(boot));
      boot.boot1_path = config.petite_boot.c_str();
      boot.boot2_path = config.scheme_boot.c_str();
      boot.boot3_path = config.racket_boot.c_str();
      boot.exec_file = config.executable_path.c_str();
      boot.collects_dir =
          config.collects_dir.empty() ? nullptr : config.collects_dir.c_str();
      boot.config_dir =
          config.config_dir.empty() ? nullptr : config.config_dir.c_str();
      boot.dll_dir = config.dll_dir.empty() ? nullptr : config.dll_dir.c_str();

      racket_boot(&boot);
      racket_embedded_load_file(config.backend_bundle.c_str(), 1);

      auto const module = quoted_symbol(config.module_name.c_str());
      auto const entry = Sstring_to_symbol(config.entry_symbol.c_str());
      // racket_dynamic_require returns a list of result values; the
      // requested export is the first result.
      auto const results = racket_dynamic_require(module, entry);
      auto const procedure = Scar(results);
      auto const args =
          Scons(Sfixnum(backend_fd), Scons(Sfixnum(backend_fd), Snil()));

      // serve-fds owns the backend fd from here; closing it (teardown or
      // exit) is what makes the native reader observe EOF.
      (void)racket_apply(procedure, args);
      Sscheme_deinit();
    } catch (...) {
      // A failed startup leaves socket_fd open; stop() still joins cleanly
      // and fail_all() reports the backend as dead.
    }

    running.store(false, std::memory_order_release);
  }

  void reader_main() noexcept {
    try {
      FdTransport transport(socket_fd);
      for (;;) {
        auto frame = rivet::read_frame(transport);
        if (!frame.has_value()) {
          break;
        }
        switch (frame->type) {
          case MessageType::Hello:
            running.store(true, std::memory_order_release);
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
            fail_request(frame->id,
                         std::make_exception_ptr(
                             std::runtime_error(std::move(message))));
            break;
          }
          case MessageType::Event: {
            auto event_value = decode_value(frame->payload);
            EventHandler handler;
            {
              std::lock_guard lock(state_mutex);
              handler = event_handler;
            }
            if (handler) {
              if (auto* list = std::get_if<Value::List>(&event_value.data);
                  list != nullptr && !list->empty()) {
                if (auto* name = std::get_if<std::string>(&(*list)[0].data)) {
                  Value payload = list->size() > 1
                                      ? (*list)[1]
                                      : Value(std::string{});
                  handler(*name, payload);
                }
              }
            }
            break;
          }
          default:
            break;
        }
      }
    } catch (...) {
      // Transport dead: fall through to failure delivery.
    }
    running.store(false, std::memory_order_release);
    fail_all(std::make_exception_ptr(
        std::runtime_error("Rivet backend transport closed")));
  }
};

Backend::Backend(RacketRuntimeConfig config)
    : impl_(std::make_unique<Impl>(std::move(config))) {}

Backend::~Backend() { stop(); }

bool Backend::running() const noexcept {
  return impl_->running.load(std::memory_order_acquire);
}

void Backend::start() {
  if (impl_->running.load(std::memory_order_relaxed)) {
    throw std::runtime_error("Rivet backend is already running");
  }
  impl_->running.store(true, std::memory_order_release);
  impl_->racket_thread = std::thread(
      [impl = impl_.get()]() mutable { impl->racket_main(); });
  impl_->reader_thread = std::thread(
      [impl = impl_.get()]() mutable { impl->reader_main(); });

  // Wait for Hello (bounded) so startup failures surface synchronously.
  auto const deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(20);
  while (!impl_->running.load(std::memory_order_acquire)) {
    if (std::chrono::steady_clock::now() > deadline) {
      stop();
      throw std::runtime_error(
          "Rivet backend did not reach Hello within 20s");
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  }
}

void Backend::stop() {
  // Shutdown frame, then join both threads. Safe to call twice; a failed
  // write means the backend is already gone and the reader has hit EOF.
  if (impl_->socket_fd >= 0) {
    try {
      FdTransport transport(impl_->socket_fd);
      write_frame(transport, Frame{MessageType::Shutdown, 0, {}});
      transport.flush();
    } catch (...) {
    }
  }
  if (impl_->racket_thread.joinable()) impl_->racket_thread.join();
  if (impl_->reader_thread.joinable()) impl_->reader_thread.join();
  impl_->fail_all(std::make_exception_ptr(
      std::runtime_error("Rivet backend stopped")));
}

std::future<Value> Backend::call(std::string rpc_name, Value::List arguments) {
  auto const id = impl_->allocate_request_id();
  auto promise = std::make_shared<std::promise<Value>>();
  auto future = promise->get_future();
  {
    std::lock_guard lock(impl_->state_mutex);
    impl_->pending[id] = [promise](CallResult result) mutable {
      if (result.succeeded()) {
        promise->set_value(std::move(*result.value));
      } else {
        promise->set_exception(result.error);
      }
    };
  }
  Value::List request;
  request.emplace_back(std::move(rpc_name));
  for (auto& argument : arguments) {
    request.emplace_back(std::move(argument));
  }
  try {
    FdTransport transport(impl_->socket_fd);
    write_frame(transport,
                Frame{MessageType::Request, id,
                      encode_value(Value(std::move(request)))});
    transport.flush();
  } catch (...) {
    impl_->fail_request(id, std::current_exception());
  }
  return future;
}

std::uint64_t Backend::request_async(std::string rpc_name,
                                     Value::List arguments,
                                     CompletionHandler completion) {
  auto const id = impl_->allocate_request_id();
  {
    std::lock_guard lock(impl_->state_mutex);
    impl_->pending[id] = std::move(completion);
  }
  Value::List request;
  request.emplace_back(std::move(rpc_name));
  for (auto& argument : arguments) {
    request.emplace_back(std::move(argument));
  }
  try {
    FdTransport transport(impl_->socket_fd);
    write_frame(transport,
                Frame{MessageType::Request, id,
                      encode_value(Value(std::move(request)))});
    transport.flush();
  } catch (...) {
    impl_->fail_request(id, std::current_exception());
  }
  return id;
}

void Backend::cancel(std::uint64_t request_id) {
  try {
    FdTransport transport(impl_->socket_fd);
    write_frame(transport, Frame{MessageType::Cancel, request_id, {}});
    transport.flush();
  } catch (...) {
  }
}

void Backend::set_event_handler(EventHandler handler) {
  std::lock_guard lock(impl_->state_mutex);
  impl_->event_handler = std::move(handler);
}

}  // namespace rivet::linux
