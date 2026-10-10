#include "rivet/detail/backend_completion_registry.hpp"

#include <cassert>
#include <exception>
#include <functional>
#include <optional>
#include <stdexcept>
#include <string>

namespace {

struct Result {
  std::optional<std::string> value;
  std::exception_ptr error;
};

using Completion = std::function<void(Result)>;
using Registry =
    rivet::detail::BackendCompletionRegistry<std::string, Result, Completion>;

std::string error_message(std::exception_ptr error) {
  try {
    std::rethrow_exception(error);
  } catch (std::exception const& exception) {
    return exception.what();
  }
}

}  // namespace

int main() {
  Registry registry(8);

  auto future = registry.insert_future();
  assert(registry.size() == 1);
  registry.resolve(future.id, "future-value");
  assert(future.result.get() == "future-value");
  assert(registry.size() == 0);

  std::optional<Result> callback_result;
  auto const callback_id = registry.insert_completion(
      [&](Result result) { callback_result = std::move(result); });
  registry.resolve(callback_id, "callback-value");
  assert(callback_result.has_value());
  assert(callback_result->value == "callback-value");
  assert(!callback_result->error);

  auto failed = registry.insert_future();
  registry.fail(failed.id,
                std::make_exception_ptr(std::runtime_error("failed")));
  try {
    (void)failed.result.get();
    assert(false && "failed future unexpectedly produced a value");
  } catch (std::runtime_error const& error) {
    assert(std::string(error.what()) == "failed");
  }

  std::optional<Result> failed_callback;
  auto const failed_callback_id = registry.insert_completion(
      [&](Result result) { failed_callback = std::move(result); });
  registry.fail(
      failed_callback_id,
      std::make_exception_ptr(std::runtime_error("callback failed")));
  assert(failed_callback.has_value());
  assert(!failed_callback->value.has_value());
  assert(error_message(failed_callback->error) == "callback failed");

  // Duplicate/unknown completion is harmless, and a throwing application
  // callback cannot escape into the transport reader.
  registry.resolve(failed_callback_id, "late");
  auto const throwing_id = registry.insert_completion(
      [](Result) { throw std::runtime_error("application callback"); });
  registry.resolve(throwing_id, "isolated");

  auto cancelled = registry.insert_future();
  bool cancel_sent = false;
  assert(!registry.request_cancel(cancelled.id,
                                  [&] { cancel_sent = true; }));
  assert(!cancel_sent);
  assert(registry.mark_request_sent(cancelled.id));
  assert(registry.request_cancel(cancelled.id,
                                 [&] { cancel_sent = true; }));
  assert(cancel_sent);

  auto drained_future = registry.insert_future();
  bool drained_callback = false;
  (void)registry.insert_completion([&](Result result) {
    drained_callback = error_message(result.error) == "stopped";
  });
  registry.reject_all(
      std::make_exception_ptr(std::runtime_error("stopped")));
  assert(registry.size() == 0);
  assert(drained_callback);
  try {
    (void)drained_future.result.get();
    assert(false && "drained future unexpectedly produced a value");
  } catch (std::runtime_error const& error) {
    assert(std::string(error.what()) == "stopped");
  }
}
