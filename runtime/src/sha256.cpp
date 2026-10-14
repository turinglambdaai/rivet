#include "rivet/detail/sha256.hpp"

#include <algorithm>
#include <cstring>
#include <stdexcept>

namespace rivet {
namespace detail {
namespace {

constexpr std::uint32_t kRoundConstants[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu,
    0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u, 0xd807aa98u, 0x12835b01u,
    0x243185beu, 0x550c7dc3u, 0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u,
    0xc19bf174u, 0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
    0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau, 0x983e5152u,
    0xa831c66du, 0xb00327c8u, 0xbf597fc7u, 0xc6e00bf3u, 0xd5a79147u,
    0x06ca6351u, 0x14292967u, 0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu,
    0x53380d13u, 0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u, 0xd192e819u,
    0xd6990624u, 0xf40e3585u, 0x106aa070u, 0x19a4c116u, 0x1e376c08u,
    0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu,
    0x682e6ff3u, 0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u,
};

std::uint32_t rotate_right(std::uint32_t value, unsigned count) {
  return (value >> count) | (value << (32 - count));
}

std::uint32_t load_be32(std::uint8_t const* source) {
  return (static_cast<std::uint32_t>(source[0]) << 24) |
         (static_cast<std::uint32_t>(source[1]) << 16) |
         (static_cast<std::uint32_t>(source[2]) << 8) |
         static_cast<std::uint32_t>(source[3]);
}

void store_be32(std::uint8_t* destination, std::uint32_t value) {
  destination[0] = static_cast<std::uint8_t>(value >> 24);
  destination[1] = static_cast<std::uint8_t>(value >> 16);
  destination[2] = static_cast<std::uint8_t>(value >> 8);
  destination[3] = static_cast<std::uint8_t>(value);
}

}  // namespace

Sha256::Sha256()
    : state_{0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
             0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u},
      buffered_(0),
      total_bytes_(0) {}

void Sha256::compress(std::uint8_t const* block) {
  std::uint32_t w[64];
  for (std::size_t i = 0; i < 16; ++i) {
    w[i] = load_be32(block + i * 4);
  }
  for (std::size_t i = 16; i < 64; ++i) {
    std::uint32_t s0 =
        rotate_right(w[i - 15], 7) ^ rotate_right(w[i - 15], 18) ^ (w[i - 15] >> 3);
    std::uint32_t s1 =
        rotate_right(w[i - 2], 17) ^ rotate_right(w[i - 2], 19) ^ (w[i - 2] >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }

  std::uint32_t a = state_[0];
  std::uint32_t b = state_[1];
  std::uint32_t c = state_[2];
  std::uint32_t d = state_[3];
  std::uint32_t e = state_[4];
  std::uint32_t f = state_[5];
  std::uint32_t g = state_[6];
  std::uint32_t h = state_[7];

  for (std::size_t i = 0; i < 64; ++i) {
    std::uint32_t s1 = rotate_right(e, 6) ^ rotate_right(e, 11) ^ rotate_right(e, 25);
    std::uint32_t ch = (e & f) ^ (~e & g);
    std::uint32_t t1 = h + s1 + ch + kRoundConstants[i] + w[i];
    std::uint32_t s0 = rotate_right(a, 2) ^ rotate_right(a, 13) ^ rotate_right(a, 22);
    std::uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
    std::uint32_t t2 = s0 + maj;
    h = g;
    g = f;
    f = e;
    e = d + t1;
    d = c;
    c = b;
    b = a;
    a = t1 + t2;
  }

  state_[0] += a;
  state_[1] += b;
  state_[2] += c;
  state_[3] += d;
  state_[4] += e;
  state_[5] += f;
  state_[6] += g;
  state_[7] += h;
}

void Sha256::update(std::uint8_t const* data, std::size_t size) {
  total_bytes_ += size;
  if (buffered_ > 0) {
    std::size_t take = std::min(size, 64 - buffered_);
    std::memcpy(buffer_ + buffered_, data, take);
    buffered_ += take;
    data += take;
    size -= take;
    if (buffered_ == 64) {
      compress(buffer_);
      buffered_ = 0;
    }
  }
  while (size >= 64) {
    compress(data);
    data += 64;
    size -= 64;
  }
  if (size > 0) {
    std::memcpy(buffer_, data, size);
    buffered_ = size;
  }
}

void Sha256::finish(std::uint8_t out[32]) {
  std::uint64_t bit_length = total_bytes_ * 8;
  std::uint8_t padding = 0x80;
  update(&padding, 1);
  std::uint8_t zero = 0;
  while (buffered_ != 56) {
    update(&zero, 1);
  }
  std::uint8_t length_block[8];
  for (std::size_t i = 0; i < 8; ++i) {
    length_block[i] = static_cast<std::uint8_t>(bit_length >> (56 - i * 8));
  }
  // Feed the length block without letting update() count it again.
  std::memcpy(buffer_ + 56, length_block, 8);
  compress(buffer_);
  buffered_ = 0;
  for (std::size_t i = 0; i < 8; ++i) {
    store_be32(out + i * 4, state_[i]);
  }
}

Bytes sha256(std::uint8_t const* data, std::size_t size) {
  Sha256 hash;
  hash.update(data, size);
  Bytes digest(32);
  hash.finish(digest.data());
  return digest;
}

Bytes sha256(Bytes const& data) { return sha256(data.data(), data.size()); }

Bytes hmac_sha256(Bytes const& key, std::uint8_t const* data, std::size_t size) {
  std::uint8_t block[64];
  std::fill(block, block + sizeof(block), 0);
  if (key.size() > sizeof(block)) {
    Bytes hashed = sha256(key);
    std::memcpy(block, hashed.data(), hashed.size());
  } else {
    std::memcpy(block, key.data(), key.size());
  }

  std::uint8_t inner[64];
  std::uint8_t outer[64];
  for (std::size_t i = 0; i < sizeof(block); ++i) {
    inner[i] = static_cast<std::uint8_t>(block[i] ^ 0x36);
    outer[i] = static_cast<std::uint8_t>(block[i] ^ 0x5c);
  }

  Sha256 inner_hash;
  inner_hash.update(inner, sizeof(inner));
  inner_hash.update(data, size);
  Bytes inner_digest(32);
  inner_hash.finish(inner_digest.data());

  Sha256 outer_hash;
  outer_hash.update(outer, sizeof(outer));
  outer_hash.update(inner_digest.data(), inner_digest.size());
  Bytes mac(32);
  outer_hash.finish(mac.data());
  return mac;
}

Bytes hmac_sha256(Bytes const& key, Bytes const& data) {
  return hmac_sha256(key, data.data(), data.size());
}

bool constant_time_equal(Bytes const& lhs, Bytes const& rhs) {
  std::size_t count = std::max(lhs.size(), rhs.size());
  std::uint8_t difference = static_cast<std::uint8_t>(lhs.size() ^ rhs.size());
  for (std::size_t i = 0; i < count; ++i) {
    std::uint8_t left = i < lhs.size() ? lhs[i] : 0;
    std::uint8_t right = i < rhs.size() ? rhs[i] : 0;
    difference |= static_cast<std::uint8_t>(left ^ right);
  }
  return difference == 0;
}

}  // namespace detail
}  // namespace rivet
