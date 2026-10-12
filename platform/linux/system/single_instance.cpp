#include "system_services.hpp"
#include "system_services_internal.hpp"

#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>
#include <stdexcept>

namespace rivet::system {
namespace {

using detail::write_all;

std::uint64_t fnv1a(std::string const& value) {
  std::uint64_t hash = 1469598103934665603ull;
  for (unsigned char byte : value) {
    hash ^= byte;
    hash *= 1099511628211ull;
  }
  return hash;
}


void write_size(int fd, std::uint32_t value) {
  write_all(fd, &value, sizeof(value));
}


std::vector<std::string> read_arguments(int fd) {
  auto read_exact = [fd](void* data, std::size_t size) {
    char* bytes = static_cast<char*>(data);
    std::size_t remaining = size;
    while (remaining > 0) {
      ssize_t received = ::read(fd, bytes, remaining);
      if (received == 0)
        throw std::runtime_error("activation stream closed before completion");
      if (received < 0) {
        if (errno == EINTR) continue;
        throw std::runtime_error(std::string("single-instance read failed: ") +
                                 std::strerror(errno));
      }
      bytes += received;
      remaining -= static_cast<std::size_t>(received);
    }
  };
  std::uint32_t count = 0;
  read_exact(&count, sizeof(count));
  if (count > 64) throw std::runtime_error("activation argument count exceeds the limit");
  std::vector<std::string> arguments;
  arguments.reserve(count);
  for (std::uint32_t index = 0; index < count; ++index) {
    std::uint32_t size = 0;
    read_exact(&size, sizeof(size));
    if (size > 4096) throw std::runtime_error("activation argument exceeds the size limit");
    std::string argument(size, '\0');
    if (size > 0) read_exact(argument.data(), size);
    arguments.push_back(std::move(argument));
  }
  return arguments;
}


std::string abstract_lease_name(std::string const& application_id) {
  // Abstract-namespace names are limited to about 107 bytes; long
  // application ids collapse to a bounded prefix plus a stable hash. The
  // leading NUL is what selects the abstract namespace, so the prefix is
  // constructed with an explicit length instead of a strlen'd literal.
  return std::string("\0rivet-single-instance-", 23) +
         application_id.substr(0, 40) + "-" +
         std::to_string(fnv1a(application_id));
}


}  // namespace

SingleInstanceLease::SingleInstanceLease(std::string const& application_id)
    : application_id_(application_id) {
  int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0)
    throw std::runtime_error(std::string("single-instance socket failed: ") +
                             std::strerror(errno));

  std::string name = abstract_lease_name(application_id);
  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  if (name.size() >= sizeof(address.sun_path)) {
    ::close(fd);
    throw std::runtime_error("single-instance lease name exceeds the address limit");
  }
  std::memcpy(address.sun_path, name.data(), name.size());

  socklen_t address_size = static_cast<socklen_t>(
      sizeof(address) - sizeof(address.sun_path) + name.size());
  if (::bind(fd, reinterpret_cast<sockaddr const*>(&address), address_size) == 0) {
    if (::listen(fd, 8) != 0) {
      int saved = errno;
      ::close(fd);
      throw std::runtime_error(std::string("single-instance listen failed: ") +
                               std::strerror(saved));
    }
    socket_fd_ = fd;
    primary_ = true;
    return;
  }
  if (errno == EADDRINUSE) {
    // Another process owns the lease; this instance is a secondary.
    ::close(fd);
    primary_ = false;
    return;
  }
  int saved = errno;
  ::close(fd);
  throw std::runtime_error(std::string("single-instance bind failed: ") +
                           std::strerror(saved));
}

SingleInstanceLease::~SingleInstanceLease() {
  bool was_watching = watcher_.joinable();
  if (was_watching && wakeup_fd_ >= 0) {
    ssize_t unused = ::write(wakeup_fd_, "x", 1);
    (void)unused;
  }
  if (socket_fd_ >= 0) {
    ::close(socket_fd_);
    socket_fd_ = -1;
  }
  if (was_watching) watcher_.join();
  if (wakeup_fd_ >= 0) {
    ::close(wakeup_fd_);
    wakeup_fd_ = -1;
  }
}

bool SingleInstanceLease::forward_arguments(
    std::vector<std::string> const& arguments) const {
  if (primary_)
    throw std::runtime_error("the primary instance cannot forward arguments");
  int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return false;

  std::string name = abstract_lease_name(application_id_);
  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  std::memcpy(address.sun_path, name.data(), name.size());
  socklen_t address_size = static_cast<socklen_t>(
      sizeof(address) - sizeof(address.sun_path) + name.size());

  if (::connect(fd, reinterpret_cast<sockaddr const*>(&address), address_size) !=
      0) {
    ::close(fd);
    return false;
  }

  try {
    write_size(fd, static_cast<std::uint32_t>(arguments.size()));
    for (std::string const& argument : arguments) {
      write_size(fd, static_cast<std::uint32_t>(argument.size()));
      if (!argument.empty()) write_all(fd, argument.data(), argument.size());
    }
    // Wait for the primary's acknowledgement so a secondary only exits when
    // the activation actually landed.
    pollfd watched{fd, POLLIN, 0};
    int ready = ::poll(&watched, 1, 2000);
    unsigned char acknowledgement = 0;
    if (ready == 1) {
      ssize_t received = ::read(fd, &acknowledgement, 1);
      if (received == 1 && acknowledgement == 0x01) {
        ::close(fd);
        return true;
      }
    }
  } catch (...) {
    ::close(fd);
    return false;
  }
  ::close(fd);
  return false;
}

void SingleInstanceLease::set_activation_handler(ActivationHandler handler) {
  if (!primary_)
    throw std::runtime_error("only the primary instance can watch for activations");
  if (!handler) throw std::runtime_error("activation handler must not be empty");
  if (watcher_.joinable())
    throw std::runtime_error("activation handler is already installed");

  // A close() does not reliably wake a thread blocked in accept(); poll on a
  // self-pipe alongside the listening socket so shutdown is deterministic.
  int pipe_fds[2];
  if (::pipe2(pipe_fds, O_CLOEXEC) != 0)
    throw std::runtime_error(std::string("single-instance pipe failed: ") +
                             std::strerror(errno));
  wakeup_fd_ = pipe_fds[1];

  watching_.store(true);
  int listening_fd = socket_fd_;
  int wake_fd = pipe_fds[0];
  watcher_ = std::thread([this, listening_fd, wake_fd,
                          handler = std::move(handler)]() {
    while (watching_.load()) {
      pollfd watched[2]{{listening_fd, POLLIN, 0}, {wake_fd, POLLIN, 0}};
      int ready = ::poll(watched, 2, -1);
      if (ready <= 0) {
        if (errno == EINTR) continue;
        break;
      }
      if (watched[1].revents != 0) break;  // Wakeup: the lease is shutting down.
      if (watched[0].revents == 0) continue;
      int connection = ::accept(listening_fd, nullptr, nullptr);
      if (connection < 0) {
        if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
        break;
      }
      // The abstract namespace has no permission bits, so any local process
      // can connect. Forwarded activations tell the primary which files and
      // URLs to open, which crosses a trust boundary when another user on a
      // shared machine injects them; require the peer to share our uid.
      ucred credentials{};
      socklen_t credentials_size = sizeof(credentials);
      if (::getsockopt(connection, SOL_SOCKET, SO_PEERCRED, &credentials,
                       &credentials_size) != 0 ||
          credentials.uid != ::geteuid()) {
        ::close(connection);
        continue;
      }
      try {
        auto arguments = read_arguments(connection);
        unsigned char acknowledgement = 0x01;
        ssize_t unused = ::write(connection, &acknowledgement, 1);
        (void)unused;
        handler(std::move(arguments));
      } catch (...) {
        // A malformed activation must not take the primary down.
      }
      ::close(connection);
    }
  });
}



}  // namespace rivet::system
