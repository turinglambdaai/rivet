#include "rivet/detail/pending_request_registry.hpp"

#include <cassert>
#include <cstdint>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>

namespace {

using Registry = rivet::detail::PendingRequestRegistry<std::unique_ptr<int>>;

template <typename Action>
std::string exception_message(Action&& action) {
  try {
    action();
  } catch (std::exception const& exception) {
    return exception.what();
  }
  return {};
}

}  // namespace

int main() {
  assert(exception_message([] { Registry registry(0); }) ==
         "Rivet native pending request limit must be positive");

  {
    Registry registry(2);
    auto const first = registry.insert(std::make_unique<int>(10));
    auto const second = registry.insert(std::make_unique<int>(20));
    assert(first == 1);
    assert(second == 2);
    assert(registry.size() == 2);
    assert(exception_message([&] {
             (void)registry.insert(std::make_unique<int>(30));
           }) == "too many native pending requests (limit 2)");

    auto payload = registry.take(first);
    assert(payload.has_value());
    assert(**payload == 10);
    assert(!registry.take(first).has_value());
    assert(registry.insert(std::make_unique<int>(30)) == 3);
  }

  {
    Registry registry(1);
    auto const id = registry.insert(std::make_unique<int>(1));
    assert(!registry.request_cancel(id));
    assert(registry.mark_request_sent(id));
    assert(!registry.request_cancel(id));
    assert(!registry.mark_request_sent(id));
  }

  {
    Registry registry(1);
    auto const id = registry.insert(std::make_unique<int>(1));
    assert(!registry.mark_request_sent(id));
    int sends = 0;
    assert(registry.request_cancel(id, [&] { ++sends; }));
    assert(!registry.request_cancel(id, [&] { ++sends; }));
    assert(sends == 1);
    assert(!registry.request_cancel(id + 1));
    assert(!registry.mark_request_sent(id + 1));
  }

  {
    Registry registry(3);
    (void)registry.insert(std::make_unique<int>(10));
    (void)registry.insert(std::make_unique<int>(20));
    int count = 0;
    int total = 0;
    registry.drain([&](std::unique_ptr<int> payload) {
      ++count;
      total += *payload;
    });
    assert(count == 2);
    assert(total == 30);
    assert(registry.size() == 0);
    registry.drain([&](std::unique_ptr<int>) { assert(false); });
  }

  {
    Registry registry(3, std::numeric_limits<std::uint64_t>::max());
    auto const last = registry.insert(std::make_unique<int>(1));
    auto const wrapped = registry.insert(std::make_unique<int>(2));
    assert(last == std::numeric_limits<std::uint64_t>::max());
    assert(wrapped == 1);
  }
}
