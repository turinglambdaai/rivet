#include "rivet/device_session_host.hpp"

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <optional>
#include <stdexcept>
#include <utility>

namespace rivet {
namespace {

constexpr std::array<std::uint8_t, 4> kSessionMagic{'R', 'V', 'D', '1'};

void read_exact_or_throw(Transport& transport, std::uint8_t* destination,
                         std::size_t size) {
  if (!transport.read_exact(destination, size)) {
    throw std::runtime_error("Rivet device session stream ended mid-record");
  }
}

}  // namespace

DeviceSessionHost::DeviceSessionHost(Transport& transport,
                                     ServerFactory make_server,
                                     PairingCodeHandler pairing_code_handler,
                                     ApplicationHandler application_handler,
                                     Clock now, double post_tls_timeout)
    : transport_(transport),
      make_server_(std::move(make_server)),
      pairing_code_handler_(std::move(pairing_code_handler)),
      application_handler_(std::move(application_handler)),
      now_(std::move(now)),
      post_tls_timeout_(post_tls_timeout) {
  if (!make_server_ || !now_ || !(post_tls_timeout_ > 0.0)) {
    throw std::runtime_error("invalid Rivet device session host configuration");
  }
}

DeviceSessionHost::~DeviceSessionHost() = default;

SessionMessage DeviceSessionHost::receive_message() {
  std::uint8_t header[8];
  read_exact_or_throw(transport_, header, sizeof(header));
  if (!std::equal(kSessionMagic.begin(), kSessionMagic.end(), header)) {
    throw std::runtime_error("invalid Rivet device session magic");
  }
  if (header[4] != kSessionVersion) {
    throw std::runtime_error("unsupported Rivet device session version");
  }
  std::size_t payload_length =
      static_cast<std::size_t>(header[6]) |
      (static_cast<std::size_t>(header[7]) << 8);
  if (payload_length > kSessionMaximumPayloadSize) {
    throw std::length_error(
        "Rivet device session record exceeds its size limit");
  }
  Bytes payload(payload_length);
  if (payload_length > 0) {
    read_exact_or_throw(transport_, payload.data(), payload.size());
  }
  Bytes record(header, header + sizeof(header));
  record.insert(record.end(), payload.begin(), payload.end());
  return decode_session_record(record);
}

void DeviceSessionHost::write_locked(SessionMessage const& message) {
  // The caller holds mutex_.
  Bytes record = encode_session_record(message);
  transport_.write_all(record.data(), record.size());
  transport_.flush();
}

void DeviceSessionHost::execute(
    std::vector<SessionServerAction> const& actions, bool& saw_acceptance,
    bool& saw_close) {
  // Called with mutex_ held so decision-thread writes and run-thread writes
  // serialize on the transport.
  for (auto const& action : actions) {
    if (auto const* send =
            std::get_if<SessionServerAction::Send>(&action.action)) {
      write_locked(send->message);
    } else if (auto const* code =
                   std::get_if<SessionServerAction::ShowPairingCode>(
                       &action.action)) {
      pairing_expires_at_ = code->expires_at;
      if (pairing_code_handler_) {
        pairing_code_handler_(code->attempt_id, code->verification_code,
                              code->expires_at);
      }
    } else if (auto const* accepted =
                   std::get_if<SessionServerAction::Accepted>(&action.action)) {
      acceptance_ = accepted->acceptance;
      saw_acceptance = true;
    } else if (std::holds_alternative<SessionServerAction::Close>(action.action)) {
      // The state machine closed the flow (a Reject, an expiry, or an
      // explicit close); the run ends after draining the remaining actions.
      saw_close = true;
    }
  }
}

void DeviceSessionHost::finish() {
  // The caller holds mutex_.
  if (finished_) {
    return;
  }
  finished_ = true;
  phase_ = Phase::Closed;
  if (server_) {
    // disconnect() is coordinator-facing bookkeeping only.
    server_->disconnect(now_());
  }
}

void DeviceSessionHost::run() {
  std::unique_lock<std::mutex> lock(mutex_);
  try {
    double started_at = now_();
    server_ = make_server_(started_at);
    double next_deadline = started_at + post_tls_timeout_;
    bool timed_out = false;

    while (true) {
      if (cancelled_ || phase_ == Phase::Closed) {
        break;
      }
      // Reads happen under the host mutex so decision-thread actions cannot
      // interleave writes; closing the transport unblocks a pending read.
      SessionMessage message = receive_message();
      double received_at = now_();
      if (cancelled_ || phase_ == Phase::Closed) {
        break;
      }
      if (received_at >= next_deadline) {
        auto actions = server_->expire(received_at);
        bool saw_acceptance = false;
        bool saw_close = false;
        execute(actions, saw_acceptance, saw_close);
        timed_out = true;
        break;
      }
      next_deadline = received_at + post_tls_timeout_;

      auto actions = server_->receive(message, received_at);
      bool saw_acceptance = false;
      bool saw_close = false;
      execute(actions, saw_acceptance, saw_close);
      if (saw_acceptance || saw_close) {
        break;
      }

      bool is_pair_decision =
          std::holds_alternative<SessionPairDecision>(message);
      if (is_pair_decision && actions.empty()) {
        // The device confirmed the code; wait for the desktop user. A
        // decision, a cancel, a shutdown, or the pairing window clock
        // resumes this wait; acceptance completes the flow without another
        // read.
        auto wake = [this] {
          return cancelled_ || finished_ || acceptance_.has_value() ||
                 phase_ == Phase::Closed;
        };
        if (pairing_expires_at_) {
          double remaining = *pairing_expires_at_ - now_();
          if (remaining > 0) {
            decision_cv_.wait_for(
                lock, std::chrono::duration<double>(remaining), wake);
          }
        } else {
          decision_cv_.wait(lock, wake);
        }
        if (cancelled_ || phase_ == Phase::Closed) {
          break;
        }
        if (!acceptance_) {
          // The pairing window elapsed with no desktop decision; the state
          // machine answers with its own expiry semantics.
          auto expire_actions = server_->expire(now_());
          bool expired_acceptance = false;
          bool expired_close = false;
          execute(expire_actions, expired_acceptance, expired_close);
          timed_out = true;
          break;
        }
        break;
      }
    }

    auto acceptance = acceptance_;
    finish();
    lock.unlock();
    if (timed_out) {
      throw DeviceSessionHostError("Rivet device session preface timed out");
    }
    if (!acceptance) {
      return;
    }
    application_handler_(*acceptance, transport_);
  } catch (...) {
    finish();
    throw;
  }
}

std::vector<SessionServerAction> DeviceSessionHost::confirm_pairing_on_desktop(
    std::vector<std::string> const& granted_scope_names) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!server_ || phase_ == Phase::Closed || finished_) {
    throw std::runtime_error("Rivet device session host is closed");
  }
  auto actions = server_->confirm_pairing_on_desktop(granted_scope_names, now_());
  for (auto const& action : actions) {
    if (auto const* send =
            std::get_if<SessionServerAction::Send>(&action.action)) {
      write_locked(send->message);
    } else if (auto const* accepted =
                   std::get_if<SessionServerAction::Accepted>(&action.action)) {
      acceptance_ = accepted->acceptance;
    } else if (std::holds_alternative<SessionServerAction::Close>(action.action)) {
      finish();
    }
  }
  decision_cv_.notify_all();
  return actions;
}

std::vector<SessionServerAction> DeviceSessionHost::reject_pairing_on_desktop() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!server_ || phase_ == Phase::Closed || finished_) {
    throw std::runtime_error("Rivet device session host is closed");
  }
  auto actions = server_->reject_pairing_on_desktop(now_());
  for (auto const& action : actions) {
    if (auto const* send =
            std::get_if<SessionServerAction::Send>(&action.action)) {
      write_locked(send->message);
    } else if (std::holds_alternative<SessionServerAction::Close>(action.action)) {
      finish();
    }
  }
  decision_cv_.notify_all();
  return actions;
}

void DeviceSessionHost::cancel() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    cancelled_ = true;
  }
  decision_cv_.notify_all();
}

}  // namespace rivet
