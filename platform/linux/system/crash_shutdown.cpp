#include "system_services.hpp"
#include "system_services_internal.hpp"

#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <thread>

namespace rivet::system {
namespace {

// Crash-hook state is written once at install time and only read from the
// signal handler, which must avoid allocations.
int crash_log_fd = -1;
std::string crash_note_suffix;
void (*crash_user_callback)(int) = nullptr;

void write_number_async_signal_safe(int number) {
  char digits[12];
  int length = 0;
  if (number < 0) {
    ssize_t unused = ::write(crash_log_fd, "-", 1);
    (void)unused;
    number = -number;
  }
  do {
    digits[length++] = static_cast<char>('0' + number % 10);
    number /= 10;
  } while (number > 0);
  while (length > 0) {
    ssize_t unused = ::write(crash_log_fd, &digits[--length], 1);
    (void)unused;
  }
}

extern "C" void rivet_crash_signal_handler(int signal_number) {
  if (crash_log_fd >= 0) {
    {
      ssize_t unused = ::write(crash_log_fd, "signal ", 7);
      (void)unused;
    }
    write_number_async_signal_safe(signal_number);
    if (!crash_note_suffix.empty()) {
      ssize_t unused = ::write(crash_log_fd, crash_note_suffix.data(),
                               crash_note_suffix.size());
      (void)unused;
    }
    ssize_t unused = ::write(crash_log_fd, "\n", 1);
    (void)unused;
  }
  if (crash_user_callback) crash_user_callback(signal_number);
  // Chain to the default disposition so core-dump semantics stay honest.
  struct sigaction default_action;
  std::memset(&default_action, 0, sizeof(default_action));
  default_action.sa_handler = SIG_DFL;
  sigaction(signal_number, &default_action, nullptr);
  raise(signal_number);
}

}  // namespace

using detail::xdg_state_home;

void InstallCrashHook(CrashCallback callback,
                      std::string const& restart_arguments) {
  if (crash_log_fd >= 0)
    throw std::runtime_error("crash hook is already installed");

  std::string directory = xdg_state_home() + "/rivet";
  ::mkdir(xdg_state_home().c_str(), 0700);
  ::mkdir(directory.c_str(), 0700);
  std::string path = directory + "/crash.log";
  int fd = ::open(path.c_str(), O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
  if (fd < 0)
    throw std::runtime_error(std::string("crash hook could not open ") + path +
                             ": " + std::strerror(errno));

  crash_log_fd = fd;
  crash_note_suffix =
      restart_arguments.empty() ? std::string() : " restart=" + restart_arguments;
  crash_user_callback = callback;

  int const watched_signals[] = {SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGABRT};
  struct sigaction action;
  std::memset(&action, 0, sizeof(action));
  action.sa_handler = rivet_crash_signal_handler;
  sigemptyset(&action.sa_mask);
  for (int signal_number : watched_signals) {
    if (sigaction(signal_number, &action, nullptr) != 0) {
      int saved = errno;
      crash_log_fd = -1;
      crash_user_callback = nullptr;
      ::close(fd);
      throw std::runtime_error(std::string("crash hook installation failed: ") +
                               std::strerror(saved));
    }
  }
}

// ---------------------------------------------------------- shutdown hook

namespace {

int shutdown_pipe_read = -1;
volatile sig_atomic_t shutdown_pipe_write = -1;
volatile sig_atomic_t shutdown_signal_received = 0;
std::function<void()> shutdown_callback;

extern "C" void rivet_shutdown_signal_handler(int signal_number) noexcept {
  // Async-signal-safe: a single write into the self-pipe is all the handler
  // does; everything else happens on the watcher thread. The write end is
  // non-blocking, so a full pipe can never wedge signal delivery (a queued
  // byte already represents the pending shutdown).
  int const saved_errno = errno;
  if (shutdown_signal_received != 0) {
    ::_exit(128 + signal_number);
  }
  shutdown_signal_received = 1;
  sig_atomic_t const write_fd = shutdown_pipe_write;
  if (write_fd >= 0) {
    char const byte = 's';
    ssize_t ignored = ::write(static_cast<int>(write_fd), &byte, 1);
    (void)ignored;
  }
  errno = saved_errno;
}

void rivet_shutdown_watch_loop() {
  char byte = 0;
  while (true) {
    ssize_t const read_bytes = ::read(shutdown_pipe_read, &byte, 1);
    if (read_bytes == 1) break;
    if (read_bytes < 0 && errno == EINTR) continue;
    std::_Exit(EXIT_FAILURE);
  }

  // A second signal must hard-kill even if the callback hangs: restore the
  // default disposition right before the callback runs.
  struct sigaction action;
  std::memset(&action, 0, sizeof(action));
  action.sa_handler = SIG_DFL;
  sigemptyset(&action.sa_mask);
  ::sigaction(SIGTERM, &action, nullptr);
  ::sigaction(SIGINT, &action, nullptr);

  try {
    if (shutdown_callback) shutdown_callback();
    std::_Exit(EXIT_SUCCESS);
  } catch (...) {
    std::_Exit(EXIT_FAILURE);
  }
}

}  // namespace

void InstallShutdownHook(std::function<void()> callback) {
  if (shutdown_pipe_read >= 0)
    throw std::runtime_error("shutdown hook is already installed");

  int fds[2]{-1, -1};
  if (::pipe2(fds, O_CLOEXEC) != 0) {
    throw std::runtime_error(std::string("shutdown hook pipe failed: ") +
                             std::strerror(errno));
  }

  auto close_pipe = [&] {
    ::close(fds[0]);
    ::close(fds[1]);
  };
  int const write_flags = ::fcntl(fds[1], F_GETFL, 0);
  if (write_flags < 0 ||
      ::fcntl(fds[1], F_SETFL, write_flags | O_NONBLOCK) != 0) {
    int const saved = errno;
    close_pipe();
    throw std::runtime_error(std::string("shutdown hook pipe setup failed: ") +
                             std::strerror(saved));
  }

  shutdown_pipe_read = fds[0];
  shutdown_pipe_write = fds[1];
  shutdown_callback = std::move(callback);

  struct sigaction action;
  std::memset(&action, 0, sizeof(action));
  action.sa_handler = rivet_shutdown_signal_handler;
  sigemptyset(&action.sa_mask);
  sigaddset(&action.sa_mask, SIGTERM);
  sigaddset(&action.sa_mask, SIGINT);
  action.sa_flags = SA_RESTART;

  struct sigaction previous_term;
  struct sigaction previous_int;
  if (::sigaction(SIGTERM, &action, &previous_term) != 0) {
    int const saved = errno;
    shutdown_pipe_read = -1;
    shutdown_pipe_write = -1;
    shutdown_signal_received = 0;
    shutdown_callback = nullptr;
    close_pipe();
    throw std::runtime_error(std::string("shutdown hook installation failed: ") +
                             std::strerror(saved));
  }
  if (::sigaction(SIGINT, &action, &previous_int) != 0) {
    int const saved = errno;
    ::sigaction(SIGTERM, &previous_term, nullptr);
    shutdown_pipe_read = -1;
    shutdown_pipe_write = -1;
    shutdown_signal_received = 0;
    shutdown_callback = nullptr;
    close_pipe();
    throw std::runtime_error(std::string("shutdown hook installation failed: ") +
                             std::strerror(saved));
  }

  try {
    std::thread(rivet_shutdown_watch_loop).detach();
  } catch (...) {
    ::sigaction(SIGTERM, &previous_term, nullptr);
    ::sigaction(SIGINT, &previous_int, nullptr);
    shutdown_pipe_read = -1;
    shutdown_pipe_write = -1;
    shutdown_signal_received = 0;
    shutdown_callback = nullptr;
    close_pipe();
    throw;
  }
}



}  // namespace rivet::system
