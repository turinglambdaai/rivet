#pragma once

#include <cstddef>
#include <cstdint>

namespace rivet {
namespace detail {

// Strict UTF-8 validation (RFC 3629) (rejects surrogates, overlongs, and the
// 0xC0/0xC1/0xF5+ ranges). Shared by the RVT1 value decoder and the
// discovery TXT record codec.
bool valid_utf8(std::uint8_t const* data, std::size_t size);

}  // namespace detail
}  // namespace rivet
