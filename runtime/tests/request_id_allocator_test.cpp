#include "rivet/detail/request_id_allocator.hpp"

#include <cassert>
#include <cstdint>
#include <limits>
#include <unordered_set>

namespace {

std::uint64_t allocate(
    rivet::detail::RequestIdAllocator& allocator,
    std::unordered_set<std::uint64_t> const& occupied) {
  return allocator.allocate(
      occupied.size(),
      [&](std::uint64_t id) { return occupied.find(id) != occupied.end(); });
}

}  // namespace

int main() {
  {
    rivet::detail::RequestIdAllocator allocator;
    std::unordered_set<std::uint64_t> occupied;
    assert(allocate(allocator, occupied) == 1);
    assert(allocate(allocator, occupied) == 2);
  }

  {
    // Zero is reserved for protocol lifecycle frames and is never allocated,
    // even if a test seed starts there.
    rivet::detail::RequestIdAllocator allocator(0);
    std::unordered_set<std::uint64_t> occupied;
    assert(allocate(allocator, occupied) == 1);
  }

  {
    // UInt64 wraparound skips zero and resumes at one.
    rivet::detail::RequestIdAllocator allocator(
        std::numeric_limits<std::uint64_t>::max());
    std::unordered_set<std::uint64_t> occupied;
    assert(allocate(allocator, occupied) ==
           std::numeric_limits<std::uint64_t>::max());
    assert(allocate(allocator, occupied) == 1);
  }

  {
    // A wrapped allocator must skip ids that are still pending.
    rivet::detail::RequestIdAllocator allocator(
        std::numeric_limits<std::uint64_t>::max());
    std::unordered_set<std::uint64_t> occupied{
        std::numeric_limits<std::uint64_t>::max(), 1, 2};
    assert(allocate(allocator, occupied) == 3);
  }

  {
    // Collision scanning is not limited to the wrap boundary.
    rivet::detail::RequestIdAllocator allocator(41);
    std::unordered_set<std::uint64_t> occupied{41, 42, 44};
    assert(allocate(allocator, occupied) == 43);
  }

  {
    // Cancellation before Request transmission is latched. Marking Request as
    // sent claims the single Cancel transmission opportunity.
    rivet::detail::RequestCancellationGate gate;
    assert(!gate.request_cancel());
    assert(gate.mark_request_sent());
    assert(!gate.request_cancel());
    assert(!gate.mark_request_sent());
  }

  {
    // Once Request is on the wire, the first cancellation can send immediately
    // and repeated cancellations cannot emit duplicates.
    rivet::detail::RequestCancellationGate gate;
    assert(!gate.mark_request_sent());
    assert(gate.request_cancel());
    assert(!gate.request_cancel());
  }
}
