#pragma once

#include <cstdint>
#include <functional>
#include <iostream>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <string_view>

namespace rivet {

// Dependency-light, provider-neutral lifecycle diagnostics shared by the
// embedded desktop runtimes. Applications can forward these records to their
// own structured logger or crash reporter without coupling Rivet to it.
struct DiagnosticRecord {
  std::string layer;
  std::string event;
  std::string status;
  std::string last_protocol_event{"none"};
  std::optional<std::uint64_t> request_id;
  std::string message;
};

using DiagnosticSink = std::function<void(DiagnosticRecord const&)>;

inline std::string diagnostic_json_escape(std::string_view value) {
  std::ostringstream out;
  static constexpr char hex[] = "0123456789abcdef";
  for (unsigned char byte : value) {
    switch (byte) {
      case '"': out << "\\\""; break;
      case '\\': out << "\\\\"; break;
      case '\b': out << "\\b"; break;
      case '\f': out << "\\f"; break;
      case '\n': out << "\\n"; break;
      case '\r': out << "\\r"; break;
      case '\t': out << "\\t"; break;
      default:
        if (byte < 0x20) {
          out << "\\u00" << hex[(byte >> 4) & 0x0f] << hex[byte & 0x0f];
        } else {
          out << static_cast<char>(byte);
        }
    }
  }
  return out.str();
}

inline std::string diagnostic_json_line(DiagnosticRecord const& record) {
  std::ostringstream out;
  out << "{\"schema\":\"rivet.diagnostic.v1\",\"layer\":\""
      << diagnostic_json_escape(record.layer) << "\",\"event\":\""
      << diagnostic_json_escape(record.event) << "\",\"status\":\""
      << diagnostic_json_escape(record.status)
      << "\",\"last_protocol_event\":\""
      << diagnostic_json_escape(record.last_protocol_event) << '"';
  if (record.request_id.has_value()) {
    out << ",\"request_id\":" << *record.request_id;
  }
  if (!record.message.empty()) {
    out << ",\"message\":\"" << diagnostic_json_escape(record.message) << '"';
  }
  out << '}';
  return out.str();
}

inline void write_diagnostic_to_stderr(DiagnosticRecord const& record) {
  // A process can own several runtime threads. Serialize whole JSONL records
  // so concurrent failures cannot corrupt the diagnostic stream.
  static std::mutex output_mutex;
  std::lock_guard lock(output_mutex);
  std::cerr << diagnostic_json_line(record) << '\n';
}

inline DiagnosticSink default_diagnostic_sink() {
  // A desktop GUI process may not own a console. On Windows, writing to stderr
  // can cause a console window to appear beside the application. Preserve the
  // explicit stderr helper, but require products to opt into any log sink.
  return {};
}

}  // namespace rivet
