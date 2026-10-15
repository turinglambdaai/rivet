#include "rivet/detail/utf8.hpp"

namespace rivet {
namespace detail {
namespace {

bool is_continuation(std::uint8_t byte) {
  return (byte & 0xc0u) == 0x80u;
}

}  // namespace

bool valid_utf8(std::uint8_t const* data, std::size_t size) {
  std::size_t i = 0;
  while (i < size) {
    auto const first = data[i];
    if (first <= 0x7f) {
      ++i;
      continue;
    }
    if (first >= 0xc2 && first <= 0xdf) {
      if (i + 1 >= size || !is_continuation(data[i + 1])) return false;
      i += 2;
      continue;
    }
    if (first == 0xe0) {
      if (i + 2 >= size || data[i + 1] < 0xa0 || data[i + 1] > 0xbf ||
          !is_continuation(data[i + 2])) return false;
      i += 3;
      continue;
    }
    if ((first >= 0xe1 && first <= 0xec) || (first >= 0xee && first <= 0xef)) {
      if (i + 2 >= size || !is_continuation(data[i + 1]) ||
          !is_continuation(data[i + 2])) return false;
      i += 3;
      continue;
    }
    if (first == 0xed) {
      if (i + 2 >= size || data[i + 1] < 0x80 || data[i + 1] > 0x9f ||
          !is_continuation(data[i + 2])) return false;
      i += 3;
      continue;
    }
    if (first == 0xf0) {
      if (i + 3 >= size || data[i + 1] < 0x90 || data[i + 1] > 0xbf ||
          !is_continuation(data[i + 2]) || !is_continuation(data[i + 3])) return false;
      i += 4;
      continue;
    }
    if (first >= 0xf1 && first <= 0xf3) {
      if (i + 3 >= size || !is_continuation(data[i + 1]) ||
          !is_continuation(data[i + 2]) || !is_continuation(data[i + 3])) return false;
      i += 4;
      continue;
    }
    if (first == 0xf4) {
      if (i + 3 >= size || data[i + 1] < 0x80 || data[i + 1] > 0x8f ||
          !is_continuation(data[i + 2]) || !is_continuation(data[i + 3])) return false;
      i += 4;
      continue;
    }
    return false;
  }
  return true;
}

}  // namespace detail
}  // namespace rivet
