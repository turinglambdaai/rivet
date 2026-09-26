#include "rivet/protocol.hpp"

#include <array>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <utility>

namespace {

constexpr std::size_t kCorpusCount = 512;
constexpr std::uint64_t kCorpusSeed = 0x72697665742d7631ULL;
constexpr std::uint64_t kCorpusFinalState = 0xa6bf907b781d9548ULL;
constexpr std::uint64_t kCorpusFingerprint = 0x2c89b9f6a1b6232cULL;
constexpr std::uint64_t kLcgMultiplier = 6364136223846793005ULL;
constexpr std::uint64_t kLcgIncrement = 1442695040888963407ULL;
constexpr std::uint64_t kFnvOffset = 14695981039346656037ULL;
constexpr std::uint64_t kFnvPrime = 1099511628211ULL;

class CorpusRng {
 public:
  explicit CorpusRng(std::uint64_t seed) : state_(seed) {}

  std::uint64_t next() {
    // Unsigned overflow is defined modulo 2^64 and intentionally matches the
    // Racket and Swift corpus generators.
    state_ = state_ * kLcgMultiplier + kLcgIncrement;
    return state_;
  }

  std::uint64_t state() const noexcept { return state_; }

 private:
  std::uint64_t state_;
};

class MemoryTransport final : public rivet::Transport {
 public:
  explicit MemoryTransport(rivet::Bytes bytes) : bytes_(std::move(bytes)) {}

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

  void write_all(std::uint8_t const*, std::size_t) override {
    throw std::runtime_error("unexpected write in decode-only property test");
  }

  void flush() override {}

 private:
  rivet::Bytes bytes_;
  std::size_t read_offset_{};
};

rivet::Value random_value(CorpusRng& rng, std::size_t depth) {
  auto const variant_count = depth >= 4 ? std::uint64_t{5} : std::uint64_t{6};
  switch (rng.next() % variant_count) {
    case 0:
      return rivet::Value{};
    case 1:
      return rivet::Value((rng.next() & 1ULL) != 0);
    case 2: {
      auto const bits = rng.next();
      std::int64_t value = 0;
      static_assert(sizeof(bits) == sizeof(value));
      std::memcpy(&value, &bits, sizeof(value));
      return rivet::Value(value);
    }
    case 3: {
      static const std::array<std::string, 5> tokens{
          std::string("a"),
          std::string("\0", 1),
          std::string("\xe4\xbd\xa0", 3),
          std::string("\xf0\x9f\x99\x82", 4),
          std::string("Rivet"),
      };
      auto const count = static_cast<std::size_t>(rng.next() % 8ULL);
      std::string value;
      for (std::size_t i = 0; i < count; ++i) {
        value += tokens[static_cast<std::size_t>(rng.next() % tokens.size())];
      }
      return rivet::Value(std::move(value));
    }
    case 4: {
      auto const count = static_cast<std::size_t>(rng.next() % 24ULL);
      rivet::Bytes bytes;
      bytes.reserve(count);
      for (std::size_t i = 0; i < count; ++i) {
        bytes.push_back(static_cast<std::uint8_t>(rng.next() & 0xffULL));
      }
      return rivet::Value(std::move(bytes));
    }
    case 5: {
      auto const count = static_cast<std::size_t>(rng.next() % 4ULL);
      rivet::Value::List values;
      values.reserve(count);
      for (std::size_t i = 0; i < count; ++i) {
        values.push_back(random_value(rng, depth + 1));
      }
      return rivet::Value(std::move(values));
    }
    default:
      assert(false && "unreachable deterministic corpus variant");
      return rivet::Value{};
  }
}

bool rejects_value(rivet::Bytes const& bytes) {
  try {
    (void)rivet::decode_value(bytes);
    return false;
  } catch (std::exception const&) {
    return true;
  }
}

bool rejects_frame(rivet::Bytes bytes) {
  try {
    MemoryTransport transport(std::move(bytes));
    (void)rivet::read_frame(transport);
    return false;
  } catch (std::exception const&) {
    return true;
  }
}

rivet::Bytes minimal_frame(std::uint8_t version, std::uint8_t type) {
  rivet::Bytes bytes{'R', 'V', 'T', '1', version, type};
  bytes.resize(18, 0);
  return bytes;
}

std::uint64_t fingerprint_byte(std::uint64_t hash, std::uint8_t byte) {
  hash ^= static_cast<std::uint64_t>(byte);
  hash *= kFnvPrime;
  return hash;
}

std::uint64_t fingerprint_value(std::uint64_t hash, rivet::Bytes const& encoded) {
  auto const length = static_cast<std::uint64_t>(encoded.size());
  for (int i = 0; i < 8; ++i) {
    hash = fingerprint_byte(
        hash,
        static_cast<std::uint8_t>((length >> (8 * i)) & 0xffULL));
  }
  for (auto const byte : encoded) {
    hash = fingerprint_byte(hash, byte);
  }
  return hash;
}

}  // namespace

int main() {
  CorpusRng rng(kCorpusSeed);
  std::uint64_t fingerprint = kFnvOffset;

  for (std::size_t case_index = 0; case_index < kCorpusCount; ++case_index) {
    auto const value = random_value(rng, 0);
    auto const encoded = rivet::encode_value(value);
    auto const decoded = rivet::decode_value(encoded);

    // Canonical encoding must survive a full decode/encode round trip.
    assert(rivet::encode_value(decoded) == encoded);

    // Every strict prefix is truncated, including the empty prefix.
    for (std::size_t prefix_size = 0; prefix_size < encoded.size(); ++prefix_size) {
      auto const end = encoded.begin() + static_cast<std::ptrdiff_t>(prefix_size);
      assert(rejects_value(rivet::Bytes(encoded.begin(), end)));
    }

    // A standalone canonical value must reject trailing bytes.
    auto with_trailing = encoded;
    with_trailing.push_back(0x00);
    assert(rejects_value(with_trailing));

    fingerprint = fingerprint_value(fingerprint, encoded);
  }

  assert(rng.state() == kCorpusFinalState);
  assert(fingerprint == kCorpusFingerprint);

  // Exhaust every invalid one-byte value tag, not just selected fixtures.
  for (unsigned raw = 7; raw <= 0xff; ++raw) {
    assert(rejects_value(rivet::Bytes{static_cast<std::uint8_t>(raw)}));
  }

  // Exhaust the message-type byte domain. Values 1..7 are the complete RVT1
  // v1 set; every other byte must fail before payload processing.
  for (unsigned raw = 0; raw <= 0xff; ++raw) {
    auto const type = static_cast<std::uint8_t>(raw);
    auto bytes = minimal_frame(rivet::kProtocolVersion, type);
    if (raw >= static_cast<unsigned>(rivet::MessageType::Hello) &&
        raw <= static_cast<unsigned>(rivet::MessageType::Shutdown)) {
      MemoryTransport transport(std::move(bytes));
      auto frame = rivet::read_frame(transport);
      assert(frame.has_value());
      assert(static_cast<std::uint8_t>(frame->type) == type);
    } else {
      assert(rejects_frame(std::move(bytes)));
    }
  }

  // Protocol version is also a full byte on the wire. Version 1 is accepted;
  // every other possible byte must be rejected deterministically.
  for (unsigned raw = 0; raw <= 0xff; ++raw) {
    auto const version = static_cast<std::uint8_t>(raw);
    auto bytes = minimal_frame(
        version,
        static_cast<std::uint8_t>(rivet::MessageType::Request));
    if (version == rivet::kProtocolVersion) {
      MemoryTransport transport(std::move(bytes));
      assert(rivet::read_frame(transport).has_value());
    } else {
      assert(rejects_frame(std::move(bytes)));
    }
  }

  return 0;
}
