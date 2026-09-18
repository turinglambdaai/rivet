// Generated from the default Rivet scaffold backend.
// raco rivet build replaces this file from the application's actual schema.
#pragma once

#include <cstdint>
#include <future>
#include <stdexcept>
#include <string>
#include <utility>

#include "backend.hpp"

namespace rivet_app {

class API {
 public:
  explicit API(rivet::windows::Backend& backend) : backend_(backend) {}

  std::future<std::string> greet(std::string name) {
    auto raw = backend_.call("greet", rivet::Value::List{rivet::Value(std::move(name))});
    return std::async(std::launch::deferred,
                      [raw = std::move(raw)]() mutable -> std::string {
                        auto value = raw.get();
                        if (auto text = std::get_if<std::string>(&value.data)) {
                          return *text;
                        }
                        throw std::runtime_error("Rivet result type mismatch: String");
                      });
  }

  std::future<std::int64_t> increment(std::int64_t value) {
    auto raw = backend_.call("increment", rivet::Value::List{rivet::Value(value)});
    return std::async(std::launch::deferred,
                      [raw = std::move(raw)]() mutable -> std::int64_t {
                        auto result = raw.get();
                        if (auto number = std::get_if<std::int64_t>(&result.data)) {
                          return *number;
                        }
                        throw std::runtime_error("Rivet result type mismatch: Int64");
                      });
  }

 private:
  rivet::windows::Backend& backend_;
};

}  // namespace rivet_app
