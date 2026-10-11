#include "system_services.hpp"
#include "system_services_internal.hpp"

#include <stdexcept>

#include <gio/gio.h>
#include <glib.h>

#if defined(RIVET_HAVE_LIBSECRET)
#include <libsecret/secret.h>
#endif

namespace rivet::system {

using detail::error_message;

#if defined(RIVET_HAVE_LIBSECRET)

SecretSchema const* secret_store_schema() {
  // A process-lifetime schema: libsecret keeps borrowed strings inside.
  static SecretSchema* schema = secret_schema_new(
      "org.rivet.SecretStore", SECRET_SCHEMA_NONE, "service",
      SECRET_SCHEMA_ATTRIBUTE_STRING, "account", SECRET_SCHEMA_ATTRIBUTE_STRING,
      static_cast<void*>(nullptr));
  return schema;
}

GHashTable* secret_store_attributes(std::string const& service,
                                    std::string const& account) {
  GHashTable* attributes =
      g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free);
  g_hash_table_insert(attributes, g_strdup("service"),
                      g_strdup(service.c_str()));
  g_hash_table_insert(attributes, g_strdup("account"),
                      g_strdup(account.c_str()));
  return attributes;
}

void SecretStore::Set(std::string const& service, std::string const& account,
                      std::vector<std::uint8_t> const& secret) {
  GHashTable* attributes = secret_store_attributes(service, account);
  SecretValue* value = secret_value_new(
      reinterpret_cast<gchar const*>(secret.data()),
      static_cast<gssize>(secret.size()), "application/octet-stream");
  std::string label = "Rivet: " + service + " / " + account;
  GError* error = nullptr;
  gboolean stored = secret_password_storev_binary_sync(
      secret_store_schema(), attributes, SECRET_COLLECTION_DEFAULT,
      label.c_str(), value, nullptr, &error);
  secret_value_unref(value);
  g_hash_table_unref(attributes);
  if (!stored)
    throw std::runtime_error(error_message("secure storage failed", error));
  if (error) g_error_free(error);
}

std::optional<std::vector<std::uint8_t>> SecretStore::Get(
    std::string const& service, std::string const& account) {
  GError* error = nullptr;
  SecretValue* value = secret_password_lookup_binary_sync(
      secret_store_schema(), nullptr, &error, "service", service.c_str(),
      "account", account.c_str(), static_cast<void*>(nullptr));
  if (error) {
    if (value) secret_value_unref(value);
    throw std::runtime_error(
        error_message("secure storage lookup failed", error));
  }
  if (!value) return std::nullopt;
  gsize size = 0;
  gconstpointer data = secret_value_get(value, &size);
  std::vector<std::uint8_t> secret(
      static_cast<std::uint8_t const*>(data),
      static_cast<std::uint8_t const*>(data) + size);
  secret_value_unref(value);
  return secret;
}

void SecretStore::Remove(std::string const& service, std::string const& account) {
  GError* error = nullptr;
  gboolean cleared = secret_password_clear_sync(
      secret_store_schema(), nullptr, &error, "service", service.c_str(),
      "account", account.c_str(), static_cast<void*>(nullptr));
  if (!cleared)
    throw std::runtime_error(
        error_message("secure storage removal failed", error));
  if (error) g_error_free(error);
}

#else

void SecretStore::Set(std::string const&, std::string const&,
                      std::vector<std::uint8_t> const&) {
  throw std::runtime_error(
      "secure storage is unavailable: Rivet was built without libsecret");
}

std::optional<std::vector<std::uint8_t>> SecretStore::Get(std::string const&,
                                                          std::string const&) {
  throw std::runtime_error(
      "secure storage is unavailable: Rivet was built without libsecret");
}

void SecretStore::Remove(std::string const&, std::string const&) {
  throw std::runtime_error(
      "secure storage is unavailable: Rivet was built without libsecret");
}

#endif



}  // namespace rivet::system
