#include "rivet/discovery_advertisement.hpp"

#include <algorithm>
#include <cstring>
#include <map>
#include <stdexcept>
#include <utility>

#include "rivet/detail/utf8.hpp"

namespace rivet {
namespace {

bool is_lowercase_hex(char character) {
  return (character >= '0' && character <= '9') ||
         (character >= 'a' && character <= 'f');
}

void append_entry(Bytes& out, std::string const& key, std::string const& value) {
  std::string entry = key + "=" + value;
  if (entry.size() > 255) {
    throw std::length_error("Rivet device discovery TXT entry is too large");
  }
  out.push_back(static_cast<std::uint8_t>(entry.size()));
  out.insert(out.end(), entry.begin(), entry.end());
}

}  // namespace

bool valid_discovery_advertisement_id(std::string const& value) {
  return value.size() == 32 &&
         std::all_of(value.begin(), value.end(), is_lowercase_hex);
}

DeviceAdvertisement::DeviceAdvertisement(std::string advertisement_id,
                                         bool pairing_window_open)
    : protocol_version(kSessionVersion),
      advertisement_id(std::move(advertisement_id)),
      pairing_window_open(pairing_window_open) {
  if (!valid_discovery_advertisement_id(this->advertisement_id)) {
    throw std::runtime_error("invalid Rivet device advertisement identifier");
  }
}

Bytes encode_discovery_txt(DeviceAdvertisement const& advertisement) {
  if (!valid_discovery_advertisement_id(advertisement.advertisement_id)) {
    throw std::runtime_error("invalid Rivet device advertisement identifier");
  }
  Bytes record;
  append_entry(record, "id", advertisement.advertisement_id);
  append_entry(record, "pair", advertisement.pairing_window_open ? "1" : "0");
  append_entry(record, "v", std::to_string(advertisement.protocol_version));
  if (record.size() > kDeviceDiscoveryMaximumTXTRecordSize) {
    throw std::length_error("Rivet device discovery TXT record is too large");
  }
  return record;
}

DeviceAdvertisement decode_discovery_txt(Bytes const& txt_record) {
  if (txt_record.empty()) {
    throw std::runtime_error("invalid Rivet device discovery TXT record");
  }
  if (txt_record.size() > kDeviceDiscoveryMaximumTXTRecordSize) {
    throw std::length_error("Rivet device discovery TXT record is too large");
  }

  std::map<std::string, std::string> fields;
  std::size_t offset = 0;
  while (offset < txt_record.size()) {
    std::size_t length = txt_record[offset];
    ++offset;
    if (length == 0 || offset + length > txt_record.size()) {
      throw std::runtime_error("invalid Rivet device discovery TXT record");
    }
    auto const* entry_bytes = txt_record.data() + offset;
    if (!detail::valid_utf8(entry_bytes, length)) {
      throw std::runtime_error("invalid Rivet device discovery TXT record");
    }
    std::string entry(reinterpret_cast<char const*>(entry_bytes), length);
    std::size_t separator = entry.find('=');
    if (separator == std::string::npos || separator == 0) {
      throw std::runtime_error("invalid Rivet device discovery TXT record");
    }
    std::string key = entry.substr(0, separator);
    std::string value = entry.substr(separator + 1);
    if (!fields.emplace(std::move(key), std::move(value)).second) {
      throw std::runtime_error("invalid Rivet device discovery TXT record");
    }
    offset += length;
  }

  if (fields.size() != 3) {
    throw std::runtime_error("invalid Rivet device discovery TXT record");
  }
  auto version_field = fields.find("v");
  auto id_field = fields.find("id");
  auto pair_field = fields.find("pair");
  if (version_field == fields.end() || id_field == fields.end() ||
      pair_field == fields.end() ||
      (pair_field->second != "0" && pair_field->second != "1")) {
    throw std::runtime_error("invalid Rivet device discovery TXT record");
  }
  std::string const& version_text = version_field->second;
  if (version_text.empty() || version_text.size() > 3 ||
      !std::all_of(version_text.begin(), version_text.end(), ::isdigit)) {
    throw std::runtime_error("invalid Rivet device discovery TXT record");
  }
  unsigned long parsed_version = std::stoul(version_text);
  if (parsed_version > 255) {
    throw std::runtime_error("invalid Rivet device discovery TXT record");
  }
  if (parsed_version != kSessionVersion) {
    throw std::runtime_error(
        "unsupported Rivet device discovery advertisement version");
  }

  DeviceAdvertisement advertisement(id_field->second, pair_field->second == "1");
  // Canonical: the record must re-encode to the exact same bytes, so
  // duplicate-shaped but reordered or padded variants never become candidates.
  if (encode_discovery_txt(advertisement) != txt_record) {
    throw std::runtime_error("invalid Rivet device discovery TXT record");
  }
  return advertisement;
}

}  // namespace rivet
