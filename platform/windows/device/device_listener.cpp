#include "device_listener.hpp"

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Networking.h>
#include <winrt/Windows.Networking.ServiceDiscovery.Dnssd.h>
#include <winrt/impl/Windows.Foundation.Collections.h>

#include <stdexcept>
#include <utility>

#include "rivet/discovery_advertisement.hpp"
#include "schannel_transport.hpp"

namespace rivet::windows {
namespace {

std::vector<std::uint8_t> advertisement_bytes(std::string const& id,
                                              bool pairing_open) {
  DeviceAdvertisement advertisement(id, pairing_open);
  return encode_discovery_txt(advertisement);
}

}  // namespace

// The DNS-SD registration and its async bookkeeping. C++/WinRT objects stay
// here so the rest of the gateway never depends on the WinRT projection.
struct DeviceListener::Registration {
  winrt::Windows::Networking::ServiceDiscovery::Dnssd::DnssdServiceInstance
      instance{nullptr};
  winrt::Windows::Foundation::IAsyncAction action{nullptr};
};

DeviceListener::DeviceListener(DeviceIdentity& identity,
                               std::string advertisement_id,
                               ConnectionHandler handler,
                               std::size_t admission_cap)
    : identity_(identity),
      advertisement_id_(std::move(advertisement_id)),
      handler_(std::move(handler)),
      admission_cap_(admission_cap) {
  if (!handler_ || !valid_discovery_advertisement_id(advertisement_id_)) {
    throw std::runtime_error(
        "invalid Rivet device listener configuration");
  }
}

DeviceListener::~DeviceListener() { stop(); }

void DeviceListener::start() {
  if (running_.exchange(true)) {
    return;
  }
  WSADATA wsa{};
  if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
    running_ = false;
    throw std::runtime_error("starting Winsock failed");
  }

  listen_socket_ = ::socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP);
  if (listen_socket_ == INVALID_SOCKET) {
    running_ = false;
    WSACleanup();
    throw std::runtime_error("creating the listener socket failed");
  }
  int v6only = 0;
  (void)setsockopt(listen_socket_, IPPROTO_IPV6, IPV6_V6ONLY,
                   reinterpret_cast<char const*>(&v6only), sizeof(v6only));
  BOOL exclusive = TRUE;
  (void)setsockopt(listen_socket_, SOL_SOCKET, SO_EXCLUSIVEADDRUSE,
                   reinterpret_cast<char const*>(&exclusive), sizeof(exclusive));

  sockaddr_in6 address{};
  address.sin6_family = AF_INET6;
  address.sin6_addr = in6addr_any;
  address.sin6_port = 0;  // ephemeral
  if (::bind(listen_socket_, reinterpret_cast<sockaddr const*>(&address),
             sizeof(address)) == SOCKET_ERROR ||
      ::listen(listen_socket_, 4) == SOCKET_ERROR) {
    int error = WSAGetLastError();
    closesocket(listen_socket_);
    listen_socket_ = INVALID_SOCKET;
    running_ = false;
    WSACleanup();
    throw std::runtime_error("binding the device listener failed (error " +
                             std::to_string(error) + ")");
  }
  sockaddr_in6 bound{};
  int bound_size = sizeof(bound);
  (void)getsockname(listen_socket_, reinterpret_cast<sockaddr*>(&bound),
                    &bound_size);
  port_ = ntohs(bound.sin6_port);

  try {
    publish();
  } catch (...) {
    closesocket(listen_socket_);
    listen_socket_ = INVALID_SOCKET;
    running_ = false;
    WSACleanup();
    throw;
  }

  accept_thread_ = std::thread([this] { accept_loop(); });
}

void DeviceListener::publish() {
  registration_ = std::make_unique<Registration>();
  try {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    auto instance_name = winrt::to_hstring("Rivet-" +
                                           advertisement_id_.substr(0, 8) +
                                           "._rivet-device._tcp.local");
    registration_->instance =
        winrt::Windows::Networking::ServiceDiscovery::Dnssd::DnssdServiceInstance(
            instance_name, nullptr, port_);
    auto attributes = registration_->instance.TextAttributes();
    attributes.Insert(L"id", winrt::to_hstring(advertisement_id_));
    attributes.Insert(
        L"pair",
        pairing_window_open_.load() ? winrt::hstring(L"1") : winrt::hstring(L"0"));
    attributes.Insert(L"v", winrt::hstring(L"1"));
    registration_->action = registration_->instance.RegisterAsync();
    // The registration completes almost immediately; block briefly so a
    // failure surfaces from start() instead of disappearing into the async
    // world.
    (void)registration_->action.get();
  } catch (...) {
    registration_.reset();
    throw std::runtime_error("publishing the device advertisement failed");
  }
}

void DeviceListener::unpublish() {
  // WinRT Dnssd exposes no explicit deregistration: the record decays with
  // its TTL once the process and its sockets close. Drop the registration
  // objects so nothing renews it.
  registration_.reset();
}

void DeviceListener::accept_loop() {
  std::size_t live = 0;
  while (running_.load()) {
    sockaddr_storage remote{};
    int remote_size = sizeof(remote);
    SOCKET accepted =
        ::accept(listen_socket_, reinterpret_cast<sockaddr*>(&remote),
                 &remote_size);
    if (accepted == INVALID_SOCKET) {
      break;  // listener closed by stop()
    }
    // Admission is capped before any transport or session state exists.
    // The handler runs on this thread, so "live" is exactly one at a time
    // per accepted socket handed off; the cap bounds sockets admitted while
    // a previous handler is still finishing.
    if (live + 1 > admission_cap_) {
      closesocket(accepted);
      continue;
    }
    ++live;
    try {
      auto transport = std::make_unique<SchannelTransport>(
          accepted, identity_.context(), port_);
      handler_(std::move(transport));
    } catch (...) {
      closesocket(accepted);
    }
    --live;
  }
}

void DeviceListener::stop() {
  if (!running_.exchange(false)) {
    return;
  }
  unpublish();
  if (listen_socket_ != INVALID_SOCKET) {
    closesocket(listen_socket_);
    listen_socket_ = INVALID_SOCKET;
  }
  if (accept_thread_.joinable()) {
    accept_thread_.join();
  }
  WSACleanup();
}

void DeviceListener::set_pairing_window_open(bool open) {
  pairing_window_open_.store(open);
  if (running_.load()) {
    unpublish();
    publish();
  }
}

}  // namespace rivet::windows
