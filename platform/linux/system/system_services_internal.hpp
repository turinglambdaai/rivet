#pragma once

#include <cstddef>
#include <string>

#include <gio/gio.h>

namespace rivet::system::detail {

std::string error_message(char const* what, GError* error);
std::string xdg_config_home();
std::string xdg_state_home();
std::string sanitize_file_name(std::string const& value);
GDBusConnection* session_bus();
void write_all(int fd, void const* data, std::size_t size);

}  // namespace rivet::system::detail
