#include "device_listener.hpp"

#include <windns.h>

#include <stdexcept>
#include <utility>

#include "rivet/discovery_advertisement.hpp"
#include "schannel_transport.hpp"

#pragma comment(lib, "dnsapi")

namespace rivet::windows {
namespace {

std::wstring instance_name(std::string const& id) {
  // <instance>._rivet-device._tcp.local
  std::string name = "Rivet-" + id.substr(0, 8) + "._rivet-device._tcp.local";
  return std::wstring(name.begin(), name.end());
}

}  // namespace

// The DNS-SD registration handle for DnsServiceDeRegister. The classic
// dnsapi service registration is a plain C structure, so no WinRT state
// lives in the listener; every pointer field targets storage owned by the
// other members.
struct DeviceListener::Registration {
  std::wstring name;
  std::wstring host_name;
  std::vector<std::wstring> keys;
  std::vector<std::wstring> values;
  std::vector<PWSTR> key_pointers;
  std::vector<PWSTR> value_pointers;
  IP4_ADDRESS ipv4{};
  DNS_SERVICE_INSTANCE instance{};
  DNS_SERVICE_REGISTER_REQUEST request{};
  bool registered = false;
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
    throw std::runtime_error("invalid Rivet device listener configuration");
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
  auto registration = std::make_unique<Registration>();
  registration->name = instance_name(advertisement_id_);
  DeviceAdvertisement advertisement(advertisement_id_,
                                    pairing_window_open_.load());
  Bytes record = encode_discovery_txt(advertisement);
  // Split the canonical record back into key/value pairs so the published
  // TXT is exactly the shared encoding, property for property.
  std::size_t offset = 0;
  while (offset < record.size()) {
    std::size_t length = record[offset];
    ++offset;
    auto const* begin = reinterpret_cast<char const*>(record.data() + offset);
    std::wstring entry(begin, begin + length);
    std::size_t separator = entry.find(L'=');
    registration->keys.push_back(entry.substr(0, separator));
    registration->values.push_back(entry.substr(separator + 1));
    offset += length;
  }
  registration->key_pointers.reserve(registration->keys.size());
  registration->value_pointers.reserve(registration->values.size());
  for (auto const& key : registration->keys) {
    registration->key_pointers.push_back(
        const_cast<PWSTR>(key.c_str()));
  }
  for (auto const& value : registration->values) {
    registration->value_pointers.push_back(
        const_cast<PWSTR>(value.c_str()));
  }

  registration->instance.pszInstanceName = registration->name.data();
  registration->instance.pszHostName = registration->host_name.data();
  registration->instance.ip4Address = &registration->ipv4;
  registration->instance.wPort = port_;
  registration->instance.dwPropertyCount =
      static_cast<DWORD>(registration->keys.size());
  registration->instance.keys = registration->key_pointers.data();
  registration->instance.values = registration->value_pointers.data();

  registration->request.Version = DNS_QUERY_REQUEST_VERSION1;
  registration->request.InterfaceIndex = 0;  // all interfaces
  registration->request.pServiceInstance = &registration->instance;
  // A null completion callback makes the registration synchronous.
  registration->request.pRegisterCompletionCallback = nullptr;

  DWORD status = DnsServiceRegister(&registration->request, nullptr);
  if (status != ERROR_SUCCESS) {
    throw std::runtime_error("registering the device advertisement failed ("
                             + std::to_string(status) + ")");
  }
  registration->registered = true;
  registration_ = std::move(registration);
}

void DeviceListener::unpublish() {
  if (!registration_ || !registration_->registered) {
    registration_.reset();
    return;
  }
  // DnsServiceDeRegister only needs the service identity; a null callback
  // keeps it synchronous.
  DNS_SERVICE_REGISTER_REQUEST request{};
  request.Version = DNS_QUERY_REQUEST_VERSION1;
  request.InterfaceIndex = 0;
  request.pServiceInstance = &registration_->instance;
  request.pRegisterCompletionCallback = nullptr;
  (void)DnsServiceDeRegister(&request, nullptr);
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
    // The handler runs on this thread, so the cap bounds sockets admitted
    // while a previous handler is still finishing.
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
