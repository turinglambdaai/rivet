#include "device_session_service.hpp"

#include <utility>

namespace rivet::windows {

DeviceSessionService::DeviceSessionService(DeviceIdentity& identity,
                                           std::string advertisement_id,
                                           HostFactory make_host)
    : identity_(identity),
      listener_(identity, std::move(advertisement_id),
                [this](std::unique_ptr<rivet::Transport> transport) {
                  // Runs on the accept thread: one session at a time, the
                  // same single-connection shape as the Apple host. The
                  // host owns the transport and closes it when the session
                  // ends.
                  auto host = make_host_(*transport);
                  host->run();
                }),
      make_host_(std::move(make_host)) {
  if (!make_host_) {
    throw std::runtime_error(
        "invalid Rivet device session service configuration");
  }
}

DeviceSessionService::~DeviceSessionService() { stop(); }

void DeviceSessionService::start() { listener_.start(); }

void DeviceSessionService::stop() { listener_.stop(); }

void DeviceSessionService::set_pairing_window_open(bool open) {
  listener_.set_pairing_window_open(open);
}

}  // namespace rivet::windows
