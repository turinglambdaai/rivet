#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace rivet {
namespace detail {

using Bytes = std::vector<std::uint8_t>;

// Streaming FIPS 180-4 SHA-256. The device session transcript needs an
// in-runtime digest and HMAC; the portable runtime carries no external
// crypto dependency, so this is the single vetted implementation.
class Sha256 {
 public:
  Sha256();
  void update(std::uint8_t const* data, std::size_t size);
  void finish(std::uint8_t out[32]);

 private:
  void compress(std::uint8_t const* block);

  std::uint32_t state_[8];
  std::uint8_t buffer_[64];
  std::size_t buffered_;
  std::uint64_t total_bytes_;
};

Bytes sha256(std::uint8_t const* data, std::size_t size);
Bytes sha256(Bytes const& data);

// HMAC-SHA256 per RFC 2104.
Bytes hmac_sha256(Bytes const& key, std::uint8_t const* data, std::size_t size);
Bytes hmac_sha256(Bytes const& key, Bytes const& data);

// Compares two byte strings in constant time with respect to their maximum
// length. Length differences alone do not short-circuit the comparison.
bool constant_time_equal(Bytes const& lhs, Bytes const& rhs);

}  // namespace detail
}  // namespace rivet
