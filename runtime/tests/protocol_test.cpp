#include "rivet/protocol.hpp"

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <limits>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

class MemoryTransport final : public rivet::Transport {
 public:
  MemoryTransport() = default;
  explicit MemoryTransport(std::vector<std::uint8_t> bytes)
      : bytes_(std::move(bytes)) {}

  bool read_exact(std::uint8_t* destination, std::size_t size) override {
    if (read_offset_ == bytes_.size()) {
      return false;
    }
    if (size > bytes_.size() - read_offset_) {
      throw std::runtime_error("partial read");
    }
    std::memcpy(destination, bytes_.data() + read_offset_, size);
    read_offset_ += size;
    return true;
  }

  void write_all(std::uint8_t const* source, std::size_t size) override {
    bytes_.insert(bytes_.end(), source, source + size);
  }

  void flush() override {}

  std::vector<std::uint8_t> const& bytes() const noexcept { return bytes_; }

 private:
  std::vector<std::uint8_t> bytes_;
  std::size_t read_offset_{};
};

struct GoldenRecord {
  std::string kind;
  std::string name;
  rivet::Bytes bytes;
};

std::uint8_t hex_nibble(char value) {
  if (value >= '0' && value <= '9') return static_cast<std::uint8_t>(value - '0');
  if (value >= 'a' && value <= 'f') return static_cast<std::uint8_t>(10 + value - 'a');
  if (value >= 'A' && value <= 'F') return static_cast<std::uint8_t>(10 + value - 'A');
  throw std::runtime_error("invalid hex digit in protocol fixture");
}

rivet::Bytes hex_to_bytes(std::string const& text) {
  if ((text.size() % 2) != 0) throw std::runtime_error("odd-length fixture hex");
  rivet::Bytes result;
  result.reserve(text.size() / 2);
  for (std::size_t i = 0; i < text.size(); i += 2) {
    result.push_back(static_cast<std::uint8_t>((hex_nibble(text[i]) << 4) |
                                               hex_nibble(text[i + 1])));
  }
  return result;
}

std::vector<GoldenRecord> load_golden_records() {
  std::ifstream input("protocol-golden.txt");
  if (!input) throw std::runtime_error("cannot open protocol-golden.txt");

  std::vector<GoldenRecord> records;
  std::string line;
  while (std::getline(input, line)) {
    if (line.empty() || line[0] == '#') continue;
    auto const first = line.find('|');
    auto const second = line.find('|', first == std::string::npos ? first : first + 1);
    if (first == std::string::npos || second == std::string::npos ||
        line.find('|', second + 1) != std::string::npos) {
      throw std::runtime_error("invalid protocol fixture line");
    }
    records.push_back(GoldenRecord{
        line.substr(0, first),
        line.substr(first + 1, second - first - 1),
        hex_to_bytes(line.substr(second + 1)),
    });
  }
  return records;
}

rivet::Value golden_value(std::string const& name) {
  if (name == "null") return rivet::Value{};
  if (name == "false") return rivet::Value(false);
  if (name == "true") return rivet::Value(true);
  if (name == "int64-min") return rivet::Value(std::numeric_limits<std::int64_t>::min());
  if (name == "int64-neg2") return rivet::Value(std::int64_t{-2});
  if (name == "int64-42") return rivet::Value(std::int64_t{42});
  if (name == "int64-max") return rivet::Value(std::numeric_limits<std::int64_t>::max());
  if (name == "string-empty") return rivet::Value("");
  if (name == "string-hello") return rivet::Value("hello");
  if (name == "string-nul") return rivet::Value(std::string("a\0b", 3));
  if (name == "string-unicode") return rivet::Value(std::string("\xe4\xbd\xa0\xe5\xa5\xbd Rivet"));
  if (name == "string-emoji") return rivet::Value(std::string("\xf0\x9f\x99\x82"));
  if (name == "bytes-empty") return rivet::Value(rivet::Bytes{});
  if (name == "bytes-binary") return rivet::Value(rivet::Bytes{0x00, 0xff, 0x7f});
  if (name == "list-empty") return rivet::Value(rivet::Value::List{});
  if (name == "list-nested") {
    rivet::Value::List values;
    values.emplace_back("nested");
    values.emplace_back(std::int64_t{7});
    values.emplace_back(true);
    return rivet::Value(std::move(values));
  }
  throw std::runtime_error("unknown value fixture");
}

bool throws_value_decode(rivet::Bytes const& bytes) {
  try {
    (void)rivet::decode_value(bytes);
    return false;
  } catch (std::exception const&) {
    return true;
  }
}

bool throws_frame_decode(rivet::Bytes bytes) {
  try {
    MemoryTransport transport(std::move(bytes));
    (void)rivet::read_frame(transport);
    return false;
  } catch (std::exception const&) {
    return true;
  }
}

}  // namespace

int main() {
  auto const records = load_golden_records();
  for (auto const& record : records) {
    if (record.kind == "value") {
      auto expected = golden_value(record.name);
      assert(rivet::encode_value(expected) == record.bytes);
      auto decoded = rivet::decode_value(record.bytes);
      assert(rivet::encode_value(decoded) == record.bytes);
    } else if (record.kind == "frame") {
      assert(record.name == "request-99");
      MemoryTransport input(record.bytes);
      auto decoded = rivet::read_frame(input);
      assert(decoded.has_value());
      assert(decoded->type == rivet::MessageType::Request);
      assert(decoded->id == 99);
      auto payload = rivet::decode_value(decoded->payload);
      assert(rivet::encode_value(payload) == rivet::encode_value(
          rivet::Value(rivet::Value::List{rivet::Value("increment"), rivet::Value(std::int64_t{41})})));
      MemoryTransport output;
      rivet::write_frame(output, *decoded);
      assert(output.bytes() == record.bytes);
    } else if (record.kind == "invalid-value") {
      assert(throws_value_decode(record.bytes));
    } else if (record.kind == "invalid-frame") {
      assert(throws_frame_decode(record.bytes));
    } else {
      assert(false && "unknown protocol fixture kind");
    }
  }

  rivet::Value too_deep;
  for (std::size_t i = 0; i <= rivet::kMaxValueDepth; ++i) {
    rivet::Value::List layer;
    layer.push_back(std::move(too_deep));
    too_deep = rivet::Value(std::move(layer));
  }
  bool rejected_deep_encode = false;
  try {
    (void)rivet::encode_value(too_deep);
  } catch (std::length_error const&) {
    rejected_deep_encode = true;
  }
  assert(rejected_deep_encode);

  rivet::Bytes too_deep_bytes;
  for (std::size_t i = 0; i <= rivet::kMaxValueDepth; ++i) {
    too_deep_bytes.insert(too_deep_bytes.end(), {0x06, 0x01, 0x00, 0x00, 0x00});
  }
  too_deep_bytes.push_back(0x00);
  assert(throws_value_decode(too_deep_bytes));

  std::vector<std::uint8_t> oversized_header{
      'R', 'V', 'T', '1',
      rivet::kProtocolVersion,
      static_cast<std::uint8_t>(rivet::MessageType::Request),
      0, 0, 0, 0, 0, 0, 0, 0,
      0x01, 0x00, 0x00, 0x04  // 64 MiB + 1
  };
  assert(throws_frame_decode(std::move(oversized_header)));

  bool rejected_invalid_utf8_encode = false;
  try {
    (void)rivet::encode_value(rivet::Value(std::string("\xff", 1)));
  } catch (std::runtime_error const&) {
    rejected_invalid_utf8_encode = true;
  }
  assert(rejected_invalid_utf8_encode);

  return 0;
}
