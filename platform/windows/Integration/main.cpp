#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <cstdint>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <string>

#include "backend.hpp"

namespace {

std::filesystem::path executable_path() {
  std::wstring buffer(32768, L'\0');
  auto const length = ::GetModuleFileNameW(
      nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
  if (length == 0 || length == buffer.size()) {
    throw std::runtime_error("GetModuleFileNameW failed");
  }
  buffer.resize(length);
  return std::filesystem::path(buffer);
}

std::string utf8(std::filesystem::path const& path) {
  auto const wide = path.wstring();
  auto const size = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(), static_cast<int>(wide.size()),
      nullptr, 0, nullptr, nullptr);
  if (size <= 0) {
    throw std::runtime_error("WideCharToMultiByte failed");
  }
  std::string result(static_cast<std::size_t>(size), '\0');
  if (::WideCharToMultiByte(
          CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(),
          static_cast<int>(wide.size()), result.data(), size, nullptr,
          nullptr) != size) {
    throw std::runtime_error("WideCharToMultiByte failed");
  }
  return result;
}

std::int64_t expect_int(rivet::Value const& value, char const* operation) {
  auto const* result = std::get_if<std::int64_t>(&value.data);
  if (result == nullptr) {
    throw std::runtime_error(std::string(operation) + " returned non-Int64");
  }
  return *result;
}

}  // namespace

int main() {
  try {
    auto const exe = executable_path();
    auto const root = exe.parent_path();
    auto const runtime = root / L"runtime";

    rivet::windows::RacketRuntimeConfig config;
    config.executable_path = utf8(exe);
    config.petite_boot = utf8(runtime / L"petite.boot");
    config.scheme_boot = utf8(runtime / L"scheme.boot");
    config.racket_boot = utf8(runtime / L"racket.boot");
    config.backend_bundle = utf8(root / L"res" / L"core.zo");
    config.module_name = "backend";
    config.entry_symbol = "start";
    config.dll_dir = root.wstring();

    rivet::windows::Backend backend(std::move(config));
    backend.start();

    auto increment = backend.call(
        "increment", rivet::Value::List{rivet::Value(std::int64_t{41})});
    if (expect_int(increment.get(), "increment") != 42) {
      throw std::runtime_error("increment(41) did not return 42");
    }

    auto initial = backend.get_state("counter");
    if (expect_int(initial.get(), "get_state") != 10) {
      throw std::runtime_error("initial counter state is not 10");
    }

    auto updated = backend.set_state("counter", rivet::Value(std::int64_t{11}));
    if (expect_int(updated.get(), "set_state") != 11) {
      throw std::runtime_error("set_state(counter, 11) did not return 11");
    }

    auto confirmed = backend.get_state("counter");
    if (expect_int(confirmed.get(), "get_state") != 11) {
      throw std::runtime_error("counter state did not persist as 11");
    }

    backend.stop();
    std::cout << "Rivet embedded Windows round-trip passed\n";
    return 0;
  } catch (std::exception const& error) {
    std::cerr << "Rivet integration failure: " << error.what() << "\n";
    return 1;
  }
}
