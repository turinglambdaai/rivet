#include "device_identity.hpp"

#include <windows.h>
#include <ncrypt.h>
#include <wincrypt.h>

#include <array>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "rivet/x509.hpp"

#pragma comment(lib, "crypt32")
#pragma comment(lib, "ncrypt")

namespace rivet::windows {
namespace {

// Pin the macros this file passes to wincrypt so a missing or redefined
// value fails here with a clear message instead of as a shifted argument
// count inside the CertStrToNameW calls below.
static_assert(X509_ASN_ENCODING == 0x00000001, "unexpected X509_ASN_ENCODING");
static_assert(CERT_X500_NAME_STR == 3, "unexpected CERT_X500_NAME_STR");

constexpr DWORD kFriendlyNameProperty = CERT_FRIENDLY_NAME_PROP_ID;
constexpr DWORD kKeyProvInfoProperty = CERT_KEY_PROV_INFO_PROP_ID;

std::wstring key_container_name(std::wstring const& friendly_name) {
  return L"Rivet Device Identity (" + friendly_name + L")";
}

struct StoreHandle {
  HCERTSTORE store = nullptr;
  operator HCERTSTORE() const noexcept { return store; }
  ~StoreHandle() {
    if (store) CertCloseStore(store, 0);
  }
};

struct ProviderHandle {
  NCRYPT_PROV_HANDLE provider = 0;
  ~ProviderHandle() {
    if (provider) NCryptFreeObject(provider);
  }
};

struct KeyHandle {
  NCRYPT_KEY_HANDLE key = 0;
  ~KeyHandle() {
    if (key) NCryptFreeObject(key);
  }
};

void throw_last_error(char const* what) {
  throw std::runtime_error(std::string(what) + " failed (error " +
                           std::to_string(GetLastError()) + ")");
}

void throw_ncrypt_status(char const* what, unsigned long status) {
  throw std::runtime_error(std::string(what) + " failed (status 0x" +
                           std::to_string(status) + ")");
}

bool has_friendly_name(PCCERT_CONTEXT context, std::wstring const& name) {
  DWORD size = 0;
  if (!CertGetCertificateContextProperty(context, kFriendlyNameProperty,
                                         nullptr, &size) ||
      size == 0) {
    return false;
  }
  std::vector<BYTE> buffer(size);
  if (!CertGetCertificateContextProperty(context, kFriendlyNameProperty,
                                         buffer.data(), &size)) {
    return false;
  }
  auto const* value = reinterpret_cast<wchar_t const*>(buffer.data());
  std::size_t characters = size / sizeof(wchar_t);
  // The property is NUL-terminated; tolerate a missing terminator only when
  // the stored name matches exactly.
  if (characters > 0 && buffer[size - 1] == 0) {
    --characters;
  }
  return name.size() == characters &&
         std::equal(name.begin(), name.end(), value);
}

bool has_private_key(PCCERT_CONTEXT context) {
  DWORD size = 0;
  return CertGetCertificateContextProperty(context, kKeyProvInfoProperty,
                                           nullptr, &size) &&
         size > 0;
}

PCCERT_CONTEXT find_identity(HCERTSTORE store, std::wstring const& name) {
  PCCERT_CONTEXT context = nullptr;
  while ((context = CertEnumCertificatesInStore(store, context)) != nullptr) {
    if (has_private_key(context) && has_friendly_name(context, name)) {
      return context;
    }
  }
  return nullptr;
}

void bind_friendly_name(const CERT_CONTEXT* context,
                        std::wstring const& friendly_name) {
  CRYPT_DATA_BLOB blob;
  blob.cbData = static_cast<DWORD>((friendly_name.size() + 1) * sizeof(wchar_t));
  blob.pbData = reinterpret_cast<BYTE*>(const_cast<wchar_t*>(
      friendly_name.c_str()));
  if (!CertSetCertificateContextProperty(context, kFriendlyNameProperty, 0,
                                         &blob)) {
    throw_last_error("naming the identity certificate");
  }
}

const CERT_CONTEXT* create_identity(std::wstring const& friendly_name) {
  std::wstring container = key_container_name(friendly_name);

  ProviderHandle provider;
  SECURITY_STATUS status = NCryptOpenStorageProvider(
      &provider.provider, const_cast<LPWSTR>(MS_KEY_STORAGE_PROVIDER), 0);
  if (status != ERROR_SUCCESS) {
    throw_ncrypt_status("opening the key storage provider", status);
  }
  KeyHandle key;
  status = NCryptCreatePersistedKey(
      provider.provider, &key.key,
      const_cast<LPWSTR>(BCRYPT_ECDSA_P256_ALGORITHM), container.data(), 0,
      NCRYPT_OVERWRITE_KEY_FLAG);
  if (status != ERROR_SUCCESS) {
    throw_ncrypt_status("creating the persisted identity key", status);
  }
  status = NCryptFinalizeKey(key.key, 0);
  if (status != ERROR_SUCCESS) {
    throw_ncrypt_status("finalizing the persisted identity key", status);
  }

  // CN="Rivet Device" as a canonical DER RDN sequence: SEQUENCE(23)
  // { SET(21) { SEQ(19) { OID 2.5.4.3 commonName, UTF8String "Rivet
  // Device" } } }. Hand-assembled because CertStrToNameW argument counts
  // shifted under the current SDK and the name is a fixed internal value.
  static BYTE const kSubjectDER[] = {
      0x30, 0x17, 0x31, 0x15, 0x30, 0x13, 0x06, 0x03, 0x55, 0x04,
      0x03, 0x0c, 0x0c, 0x52, 0x69, 0x76, 0x65, 0x74, 0x20, 0x44,
      0x65, 0x76, 0x69, 0x63, 0x65};
  CERT_NAME_BLOB subject_blob;
  subject_blob.cbData = static_cast<DWORD>(sizeof(kSubjectDER));
  subject_blob.pbData = const_cast<BYTE*>(kSubjectDER);

  CRYPT_KEY_PROV_INFO prov_info{};
  prov_info.pwszContainerName = container.data();
  prov_info.pwszProvName = const_cast<LPWSTR>(MS_KEY_STORAGE_PROVIDER);
  prov_info.dwKeySpec = CERT_NCRYPT_KEY_SPEC;

  CRYPT_ALGORITHM_IDENTIFIER signature{};
  signature.pszObjId = const_cast<LPSTR>(szOID_ECDSA_SHA256);

  SYSTEMTIME now;
  GetSystemTime(&now);
  SYSTEMTIME expires = now;
  expires.wYear += 10;

  CERT_EXTENSIONS extensions{};
  const CERT_CONTEXT* context = CertCreateSelfSignCertificate(
      key.key, &subject_blob, 0, &prov_info, &signature, &now, &expires,
      &extensions);
  if (!context) {
    throw_last_error("creating the self-signed identity certificate");
  }
  try {
    bind_friendly_name(context, friendly_name);
  } catch (...) {
    CertFreeCertificateContext(context);
    throw;
  }
  return context;
}

}  // namespace

DeviceIdentity DeviceIdentity::load_or_create(std::wstring const& friendly_name) {
  StoreHandle store;
  store.store = CertOpenSystemStoreW(0, L"MY");
  if (!store.store) {
    throw_last_error("opening the personal certificate store");
  }
  if (PCCERT_CONTEXT existing = find_identity(store.store, friendly_name)) {
    return DeviceIdentity(existing);
  }
  const CERT_CONTEXT* created = create_identity(friendly_name);
  // Adding the certificate to the store lets reconnects and diagnostics
  // enumerate it later; TLS itself takes the context directly, so store
  // failures (a read-only profile) must not break identity creation.
  if (!CertAddCertificateContextToStore(store.store, created,
                                        CERT_STORE_ADD_REPLACE_EXISTING,
                                        nullptr)) {
    SetLastError(0);
  }
  return DeviceIdentity(created);
}

void DeviceIdentity::delete_identity(std::wstring const& friendly_name) {
  StoreHandle store;
  store.store = CertOpenSystemStoreW(0, L"MY");
  if (!store.store) {
    throw_last_error("opening the personal certificate store");
  }
  PCCERT_CONTEXT context = nullptr;
  while ((context = CertEnumCertificatesInStore(store, context)) != nullptr) {
    if (!has_friendly_name(context, friendly_name)) {
      continue;
    }
    // Remove the bound CNG key first so a half-deleted state cannot
    // resurface as a working identity.
    DWORD size = 0;
    if (CertGetCertificateContextProperty(context, kKeyProvInfoProperty,
                                          nullptr, &size) &&
        size > 0) {
      std::vector<BYTE> buffer(size);
      if (CertGetCertificateContextProperty(context, kKeyProvInfoProperty,
                                            buffer.data(), &size)) {
        auto const* prov_info =
            reinterpret_cast<CRYPT_KEY_PROV_INFO const*>(buffer.data());
        ProviderHandle provider;
        if (NCryptOpenStorageProvider(&provider.provider,
                                      prov_info->pwszProvName, 0) ==
            ERROR_SUCCESS) {
          KeyHandle key;
          if (NCryptOpenKey(provider.provider, &key.key,
                            prov_info->pwszContainerName,
                            prov_info->dwKeySpec, 0) == ERROR_SUCCESS) {
            NCryptDeleteKey(key.key, 0);
          }
        }
      }
    }
    CertDeleteCertificateFromStore(context);
    // Deletion frees `context`; restart the enumeration.
    context = nullptr;
  }
}

std::vector<std::uint8_t> DeviceIdentity::spki_sha256() const {
  std::array<std::uint8_t, 32> digest = x509_spki_sha256(
      std::vector<std::uint8_t>(context_->pbCertEncoded,
                                context_->pbCertEncoded + context_->cbCertEncoded));
  return std::vector<std::uint8_t>(digest.begin(), digest.end());
}

DeviceIdentity::DeviceIdentity(const CERT_CONTEXT* context)
    : context_(context) {}

void DeviceIdentity::ContextDeleter::operator()(CERT_CONTEXT const* context)
    const noexcept {
  CertFreeCertificateContext(const_cast<CERT_CONTEXT*>(context));
}

}  // namespace rivet::windows
