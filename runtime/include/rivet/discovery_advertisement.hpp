#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "rivet/device_session.hpp"

namespace rivet {

// The privacy-bounded discovery advertisement shared by every Rivet
// companion platform: a DNS-SD TXT record carrying only the session
// protocol version, a per-listener ephemeral identifier, and the
// pairing-window bit. Decoding is canonical — a record must re-encode to
// the exact same bytes — so advertisements from any platform are
// byte-identical for the same logical content.

inline constexpr char const* kDeviceDiscoveryServiceType = "_rivet-device._tcp";
inline constexpr std::size_t kDeviceDiscoveryMaximumTXTRecordSize = 128;

struct DeviceAdvertisement {
  std::uint8_t protocol_version{};
  std::string advertisement_id;
  bool pairing_window_open{};

  DeviceAdvertisement(std::string advertisement_id, bool pairing_window_open);
};

// Canonical wire form: `id=…`, `pair=…`, `v=…` in that order, each entry
// length-prefixed with one byte (RFC 6763 TXT).
Bytes encode_discovery_txt(DeviceAdvertisement const& advertisement);

// Throws std::runtime_error on any deviation from the canonical encoding
// and std::length_error above the size bound.
DeviceAdvertisement decode_discovery_txt(Bytes const& txt_record);

// The advertisement identifier: exactly 32 lowercase hex characters.
bool valid_discovery_advertisement_id(std::string const& value);

}  // namespace rivet
