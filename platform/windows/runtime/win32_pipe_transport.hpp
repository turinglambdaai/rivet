#pragma once

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include "rivet/protocol.hpp"

namespace rivet::windows {

class Win32PipeTransport final : public Transport {
 public:
  Win32PipeTransport(HANDLE read_handle, HANDLE write_handle);
  ~Win32PipeTransport() override;

  Win32PipeTransport(Win32PipeTransport const&) = delete;
  Win32PipeTransport& operator=(Win32PipeTransport const&) = delete;

  Win32PipeTransport(Win32PipeTransport&& other) noexcept;
  Win32PipeTransport& operator=(Win32PipeTransport&& other) noexcept;

  bool read_exact(std::uint8_t* destination, std::size_t size) override;
  void write_all(std::uint8_t const* source, std::size_t size) override;
  void flush() override;

  HANDLE release_read_handle() noexcept;
  HANDLE release_write_handle() noexcept;

 private:
  void close() noexcept;

  HANDLE read_handle_{INVALID_HANDLE_VALUE};
  HANDLE write_handle_{INVALID_HANDLE_VALUE};
};

}  // namespace rivet::windows
