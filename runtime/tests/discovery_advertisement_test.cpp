#include "rivet/discovery_advertisement.hpp"

#include <cassert>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

using namespace rivet;

Bytes txt(std::string const& entries) {
  // Encode a hand-written record by splitting unescaped '\n' markers.
  Bytes record;
  std::string entry;
  auto flush = [&] {
    assert(entry.size() <= 255);
    record.push_back(static_cast<std::uint8_t>(entry.size()));
    record.insert(record.end(), entry.begin(), entry.end());
    entry.clear();
  };
  for (char c : entries) {
    if (c == '\n') {
      flush();
    } else {
      entry.push_back(c);
    }
  }
  flush();
  return record;
}

constexpr char const* kID = "0f1e2d3c4b5a69788796a5b4c3d2e1f0";

void test_round_trip_and_canonicality() {
  DeviceAdvertisement advertisement(kID, true);
  Bytes record = encode_discovery_txt(advertisement);
  assert(record == txt("id=" + std::string(kID) + "\npair=1\nv=1"));
  assert(record.size() == 1 + 35 + 1 + 6 + 1 + 3);

  DeviceAdvertisement decoded = decode_discovery_txt(record);
  assert(decoded.protocol_version == 1);
  assert(decoded.advertisement_id == kID);
  assert(decoded.pairing_window_open);

  // The closed-window form differs only in the pair byte.
  Bytes closed = encode_discovery_txt(DeviceAdvertisement(kID, false));
  assert(decode_discovery_txt(closed).pairing_window_open == false);
  std::cout << "discovery_advertisement round trip: ok\n";
}

void test_decode_rejects_everything_noncanonical() {
  bool threw = false;
  auto expect_throw = [&](Bytes const& record) {
    try {
      (void)decode_discovery_txt(record);
    } catch (std::length_error const&) {
      return true;
    } catch (std::runtime_error const&) {
      return true;
    }
    return false;
  };

  threw = expect_throw(Bytes{});
  assert(threw);
  threw = expect_throw(Bytes(kDeviceDiscoveryMaximumTXTRecordSize + 1, 0x01));
  assert(threw);

  // Reordered entries decode as values but fail the canonical byte check.
  threw = expect_throw(txt("pair=1\nv=1\nid=" + std::string(kID)));
  assert(threw);

  // Missing, duplicate, and unknown keys.
  threw = expect_throw(txt("pair=1\nv=1"));
  assert(threw);
  threw = expect_throw(txt("id=" + std::string(kID) + "\npair=1\nv=1\nid=" +
                           std::string(kID)));
  assert(threw);
  threw = expect_throw(txt("id=" + std::string(kID) + "\npair=1\nv=1\nx=1"));
  assert(threw);

  // Wrong protocol version: well-formed values, unsupported number.
  threw = expect_throw(txt("id=" + std::string(kID) + "\npair=1\nv=2"));
  assert(threw);

  // Pair values other than the exact digits.
  threw = expect_throw(txt("id=" + std::string(kID) + "\npair=true\nv=1"));
  assert(threw);

  // Uppercase identifiers are not valid ephemeral IDs.
  std::string upper = kID;
  upper[0] = 'A';
  threw = expect_throw(txt("id=" + upper + "\npair=1\nv=1"));
  assert(threw);

  // Zero-length entries and truncated length prefixes.
  threw = expect_throw(Bytes{0x00, 0x02, 'v', '=', '1'});
  assert(threw);
  threw = expect_throw(Bytes{0x05, 'v', '=', '1'});
  assert(threw);

  // A key-less entry and an entry whose '=' opens the string.
  threw = expect_throw(txt("id=" + std::string(kID) + "\npair=1\nnovalue"));
  assert(threw);
  threw = expect_throw(txt("=1\npair=1\nv=1"));
  assert(threw);

  // Invalid UTF-8 in an identifier.
  threw = expect_throw(txt("id=" + std::string(kID).substr(0, 31) + "\xff" +
                           "\npair=1\nv=1"));
  assert(threw);

  // Advertisements with malformed identifiers never construct.
  threw = false;
  try {
    DeviceAdvertisement bad("short", true);
    (void)bad;
  } catch (std::runtime_error const&) {
    threw = true;
  }
  assert(threw);
  std::cout << "discovery_advertisement rejects: ok\n";
}

}  // namespace

int main() {
  try {
    test_round_trip_and_canonicality();
    test_decode_rejects_everything_noncanonical();
  } catch (std::exception const& error) {
    std::cerr << "discovery advertisement test failed: " << error.what() << "\n";
    return 1;
  }
  return 0;
}
