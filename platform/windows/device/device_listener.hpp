#pragma once

#include <winsock2.h>
#include <windows.h>
#include <ws2tcpip.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <thread>

#include "device_identity.hpp"
#include "rivet/protocol.hpp"

namespace rivet::windows {

// Binds an ephemeral TCP port on all interfaces, accepts at most a bounded
// number of pending TLS connections, and publishes the canonical
// _rivet-device._tcp advertisement through DNS-SD while the listener is
// ready. Disabling the listener or tearing it down closes the accepted
// transport, matching the macOS listener's fail-closed lifecycle.
class DeviceListener {
 public:
  // Runs on the accept thread with an already handshaken transport. The
  // handler owns it from the call.
  using ConnectionHandler =
      std::function<void(std::unique_ptr<rivet::Transport>)>;

  DeviceListener(DeviceIdentity& identity, std::string advertisement_id,
                 ConnectionHandler handler,
                 std::size_t admission_cap = 4);
  ~DeviceListener();

  DeviceListener(DeviceListener const&) = delete;
  DeviceListener& operator=(DeviceListener const&) = delete;

  // Binds, starts the accept thread, and publishes the advertisement.
  // Throws std::runtime_error when the port cannot be bound or the
  // advertisement cannot be registered.
  void start();

  // Idempotent. Unpublishes the advertisement, closes the listening
  // socket, and joins the accept thread. Accepted transports are closed by
  // their owners.
  void stop();

  // Updates the pairing-window bit and republishes the advertisement.
  void set_pairing_window_open(bool open);

  std::uint16_t port() const noexcept { return port_; }
  std::string const& advertisement_id() const noexcept {
    return advertisement_id_;
  }

 private:
  void accept_loop();
  void publish();
  void unpublish();

  DeviceIdentity& identity_;
  std::string advertisement_id_;
  ConnectionHandler handler_;
  std::size_t admission_cap_;

  SOCKET listen_socket_ = INVALID_SOCKET;
  std::uint16_t port_ = 0;
  std::atomic<bool> pairing_window_open_{false};
  std::atomic<bool> running_{false};
  std::thread accept_thread_;

  // DNS-SD registration lives behind type-erased storage so this header
  // does not pull C++/WinRT into every consumer.
  struct Registration;
  std::unique_ptr<Registration> registration_;
};

}  // namespace rivet::windows
