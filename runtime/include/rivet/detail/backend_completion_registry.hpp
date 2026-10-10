#pragma once

#include <cstddef>
#include <cstdint>
#include <exception>
#include <future>
#include <memory>
#include <optional>
#include <utility>

#include "rivet/detail/pending_request_registry.hpp"

namespace rivet::detail {

// Platform-independent ownership and completion for native backend requests.
// Transports decide when requests are sent and which thread receives replies;
// this class guarantees exactly-once removal and isolates application callback
// failures from the transport loop.
template <typename Value, typename Result, typename CompletionHandler>
class BackendCompletionRegistry final {
 public:
  struct FutureRegistration {
    std::uint64_t id{};
    std::future<Value> result;
  };

  explicit BackendCompletionRegistry(std::size_t max_pending)
      : pending_(max_pending) {}

  BackendCompletionRegistry(BackendCompletionRegistry const&) = delete;
  BackendCompletionRegistry& operator=(BackendCompletionRegistry const&) =
      delete;

  FutureRegistration insert_future() {
    auto promise = std::make_unique<std::promise<Value>>();
    auto future = promise->get_future();
    auto const id =
        pending_.insert(Pending{std::move(promise), CompletionHandler{}});
    return FutureRegistration{id, std::move(future)};
  }

  std::uint64_t insert_completion(CompletionHandler completion) {
    return pending_.insert(Pending{nullptr, std::move(completion)});
  }

  template <typename SendCancel>
  bool request_cancel(std::uint64_t id, SendCancel&& send_cancel) {
    return pending_.request_cancel(id,
                                   std::forward<SendCancel>(send_cancel));
  }

  bool mark_request_sent(std::uint64_t id) {
    return pending_.mark_request_sent(id);
  }

  void resolve(std::uint64_t id, Value value) noexcept {
    auto pending = pending_.take(id);
    if (!pending.has_value()) {
      return;
    }

    if (pending->promise != nullptr) {
      try {
        pending->promise->set_value(std::move(value));
      } catch (...) {
      }
      return;
    }

    if (pending->completion) {
      try {
        pending->completion(Result{std::move(value), nullptr});
      } catch (...) {
        // Application completions are isolated from the transport loop.
      }
    }
  }

  void fail(std::uint64_t id, std::exception_ptr error) noexcept {
    auto pending = pending_.take(id);
    if (!pending.has_value()) {
      return;
    }

    if (pending->promise != nullptr) {
      try {
        pending->promise->set_exception(error);
      } catch (...) {
      }
      return;
    }

    if (pending->completion) {
      try {
        pending->completion(Result{std::nullopt, error});
      } catch (...) {
        // Application completions are isolated from the transport loop.
      }
    }
  }

  void reject_all(std::exception_ptr error) noexcept {
    pending_.drain([&](Pending request) {
      if (request.promise != nullptr) {
        try {
          request.promise->set_exception(error);
        } catch (...) {
        }
      } else if (request.completion) {
        try {
          request.completion(Result{std::nullopt, error});
        } catch (...) {
          // Application completions must not interrupt shutdown.
        }
      }
    });
  }

  std::size_t size() const { return pending_.size(); }

 private:
  struct Pending {
    std::unique_ptr<std::promise<Value>> promise;
    CompletionHandler completion;
  };

  PendingRequestRegistry<Pending> pending_;
};

}  // namespace rivet::detail
