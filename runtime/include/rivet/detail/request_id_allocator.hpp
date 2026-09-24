#pragma once

#include <cstddef>
#include <cstdint>
#include <limits>
#include <stdexcept>

namespace rivet::detail {

// Allocates non-zero RVT1 request ids while allowing callers to reject ids
// that are still in use. The allocator itself is deliberately not synchronized:
// allocation and insertion into the caller's pending table must happen under
// the same lock so a returned id cannot be claimed by another request first.
class RequestIdAllocator final {
 public:
  explicit RequestIdAllocator(std::uint64_t next = 1) noexcept
      : next_(next == 0 ? 1 : next) {}

  template <typename IsInUse>
  std::uint64_t allocate(std::size_t occupied_count, IsInUse&& is_in_use) {
    // Among N + 1 distinct non-zero candidates, at least one must be free when
    // only N ids are occupied. Bounding the scan this way also makes wraparound
    // deterministic without ever iterating the full UInt64 domain.
    for (std::size_t attempt = 0;; ++attempt) {
      auto const candidate = next_;
      advance();
      if (!is_in_use(candidate)) {
        return candidate;
      }
      if (attempt == occupied_count) {
        throw std::logic_error("Rivet request id allocator invariant violated");
      }
    }
  }

 private:
  void advance() noexcept {
    next_ = next_ == std::numeric_limits<std::uint64_t>::max() ? 1 : next_ + 1;
  }

  std::uint64_t next_;
};

}  // namespace rivet::detail
