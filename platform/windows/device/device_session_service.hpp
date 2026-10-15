#pragma once

#include <winsock2.h>
#include <windows.h>

#include <memory>
#include <string>

#include "device_identity.hpp"
#include "device_listener.hpp"
#include "rivet/device_session_host.hpp"

namespace rivet::windows {

// One-object façade for the desktop device gateway transport: the identity,
// the TLS listener, the DNS-SD advertisement, and the session host. The
// host supplies only the session-server boundaries through `HostFactory`
// (its pairing store, window coordinator, random source, UUIDs, and
// clock); binding the accepted scopes to the RVT1 gateway stays in the
// application handler, exactly as on macOS.
class DeviceSessionService {
 public:
  using HostFactory = std::function<std::unique_ptr<rivet::DeviceSessionHost>(
      rivet::Transport&)>;

  DeviceSessionService(DeviceIdentity& identity, std::string advertisement_id,
                       HostFactory make_host);
  ~DeviceSessionService();

  DeviceSessionService(DeviceSessionService const&) = delete;
  DeviceSessionService& operator=(DeviceSessionService const&) = delete;

  void start();
  void stop();

  // The pairing window is closed by default; the Devices UI opens it for
  // five minutes, mirroring the Apple gateway.
  void set_pairing_window_open(bool open);

  std::uint16_t port() const noexcept { return listener_.port(); }
  std::string const& advertisement_id() const noexcept {
    return listener_.advertisement_id();
  }

 private:
  DeviceIdentity& identity_;
  DeviceListener listener_;
  HostFactory make_host_;
};

}  // namespace rivet::windows
