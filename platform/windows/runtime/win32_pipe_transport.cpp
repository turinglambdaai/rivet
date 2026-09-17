#include "win32_pipe_transport.hpp"

#include <algorithm>
#include <limits>
#include <stdexcept>
#include <string>
#include <utility>

namespace rivet::windows {
namespace {

std::runtime_error win32_error(char const* operation) {
  auto const code = ::GetLastError();
  return std::runtime_error(std::string(operation) + " failed with Win32 error " +
                            std::to_string(code));
}

}  // namespace

Win32PipeTransport::Win32PipeTransport(HANDLE read_handle, HANDLE write_handle)
    : read_handle_(read_handle), write_handle_(write_handle) {}

Win32PipeTransport::~Win32PipeTransport() { close(); }

Win32PipeTransport::Win32PipeTransport(Win32PipeTransport&& other) noexcept
    : read_handle_(other.release_read_handle()),
      write_handle_(other.release_write_handle()) {}

Win32PipeTransport& Win32PipeTransport::operator=(Win32PipeTransport&& other) noexcept {
  if (this != &other) {
    close();
    read_handle_ = other.release_read_handle();
    write_handle_ = other.release_write_handle();
  }
  return *this;
}

bool Win32PipeTransport::read_exact(std::uint8_t* destination, std::size_t size) {
  std::size_t offset = 0;
  while (offset < size) {
    DWORD read = 0;
    auto const remaining = size - offset;
    auto const chunk = static_cast<DWORD>(
        std::min<std::size_t>(remaining, std::numeric_limits<DWORD>::max()));

    if (!::ReadFile(read_handle_, destination + offset, chunk, &read, nullptr)) {
      auto const code = ::GetLastError();
      if ((code == ERROR_BROKEN_PIPE || code == ERROR_HANDLE_EOF) && offset == 0) {
        return false;
      }
      throw win32_error("ReadFile");
    }
    if (read == 0) {
      if (offset == 0) {
        return false;
      }
      throw std::runtime_error("unexpected EOF in Win32 pipe");
    }
    offset += read;
  }
  return true;
}

void Win32PipeTransport::write_all(std::uint8_t const* source, std::size_t size) {
  std::size_t offset = 0;
  while (offset < size) {
    DWORD written = 0;
    auto const remaining = size - offset;
    auto const chunk = static_cast<DWORD>(
        std::min<std::size_t>(remaining, std::numeric_limits<DWORD>::max()));

    if (!::WriteFile(write_handle_, source + offset, chunk, &written, nullptr)) {
      throw win32_error("WriteFile");
    }
    if (written == 0) {
      throw std::runtime_error("WriteFile wrote zero bytes");
    }
    offset += written;
  }
}

void Win32PipeTransport::flush() {
  // Anonymous pipes do not require FlushFileBuffers for request ordering;
  // WriteFile is synchronous here. Keeping this method a no-op also avoids a
  // deadlock if the peer is not actively draining the pipe.
}

HANDLE Win32PipeTransport::release_read_handle() noexcept {
  auto const result = read_handle_;
  read_handle_ = INVALID_HANDLE_VALUE;
  return result;
}

HANDLE Win32PipeTransport::release_write_handle() noexcept {
  auto const result = write_handle_;
  write_handle_ = INVALID_HANDLE_VALUE;
  return result;
}

void Win32PipeTransport::close() noexcept {
  if (read_handle_ != INVALID_HANDLE_VALUE && read_handle_ != nullptr) {
    ::CloseHandle(read_handle_);
    read_handle_ = INVALID_HANDLE_VALUE;
  }
  if (write_handle_ != INVALID_HANDLE_VALUE && write_handle_ != nullptr) {
    ::CloseHandle(write_handle_);
    write_handle_ = INVALID_HANDLE_VALUE;
  }
}

}  // namespace rivet::windows
