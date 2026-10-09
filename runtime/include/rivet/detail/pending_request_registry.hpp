#pragma once

#include <cstddef>
#include <cstdint>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <utility>

#include "rivet/detail/request_id_allocator.hpp"

namespace rivet::detail {

// Owns the platform-independent lifecycle state for native requests. Platform
// backends remain responsible for transport serialization and completion
// delivery; this registry only coordinates ids, capacity, and cancellation.
template <typename Payload>
class PendingRequestRegistry final {
 public:
  explicit PendingRequestRegistry(std::size_t max_pending,
                                  std::uint64_t next_id = 1)
      : max_pending_(max_pending), request_ids_(next_id) {
    if (max_pending_ == 0) {
      throw std::invalid_argument(
          "Rivet native pending request limit must be positive");
    }
  }

  PendingRequestRegistry(PendingRequestRegistry const&) = delete;
  PendingRequestRegistry& operator=(PendingRequestRegistry const&) = delete;

  std::uint64_t insert(Payload payload) {
    std::lock_guard lock(mutex_);
    if (pending_.size() >= max_pending_) {
      throw std::runtime_error("too many native pending requests (limit " +
                               std::to_string(max_pending_) + ")");
    }

    auto const id = request_ids_.allocate(
        pending_.size(), [this](std::uint64_t candidate) {
          return pending_.find(candidate) != pending_.end();
        });
    auto const [it, inserted] =
        pending_.emplace(id, Entry{std::move(payload), {}});
    (void)it;
    if (!inserted) {
      throw std::logic_error("Rivet request id collision");
    }
    return id;
  }

  bool request_cancel(std::uint64_t id) {
    std::lock_guard lock(mutex_);
    auto const it = pending_.find(id);
    return it != pending_.end() && it->second.cancellation.request_cancel();
  }

  // Runs the transport action before releasing the registry lock. This keeps
  // request ownership and Cancel serialization linearized against take().
  template <typename SendCancel>
  bool request_cancel(std::uint64_t id, SendCancel&& send_cancel) {
    std::lock_guard lock(mutex_);
    auto const it = pending_.find(id);
    if (it == pending_.end() ||
        !it->second.cancellation.request_cancel()) {
      return false;
    }
    std::forward<SendCancel>(send_cancel)();
    return true;
  }

  bool mark_request_sent(std::uint64_t id) {
    std::lock_guard lock(mutex_);
    auto const it = pending_.find(id);
    return it != pending_.end() &&
           it->second.cancellation.mark_request_sent();
  }

  std::optional<Payload> take(std::uint64_t id) {
    std::lock_guard lock(mutex_);
    auto const it = pending_.find(id);
    if (it == pending_.end()) {
      return std::nullopt;
    }
    auto payload = std::move(it->second.payload);
    pending_.erase(it);
    return payload;
  }

  template <typename Consumer>
  void drain(Consumer&& consume) {
    decltype(pending_) pending;
    {
      std::lock_guard lock(mutex_);
      pending.swap(pending_);
    }
    for (auto& [id, entry] : pending) {
      (void)id;
      consume(std::move(entry.payload));
    }
  }

  std::size_t size() const {
    std::lock_guard lock(mutex_);
    return pending_.size();
  }

 private:
  struct Entry {
    Payload payload;
    RequestCancellationGate cancellation;
  };

  std::size_t const max_pending_;
  mutable std::mutex mutex_;
  std::unordered_map<std::uint64_t, Entry> pending_;
  RequestIdAllocator request_ids_;
};

}  // namespace rivet::detail
