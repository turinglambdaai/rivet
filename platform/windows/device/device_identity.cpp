#include "device_identity.hpp"

#include <windows.h>
#include <ncrypt.h>
#include <wincrypt.h>

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

constexpr DWORD kFriendlyNameProperty = CERT_FRIENDLY_NAME_PROP_ID;
constexpr DWORD kKeyProvInfoProperty = CERT_KEY_PROV_INFO_PROP_ID;

std::wstring key_container_name(std::wstring const& friendly_name) {
  return L"Rivet Device Identity (" + friendly_name + L")";
}

struct StoreHandle {
  HCERTSTORE store = nullptr;
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

struct LocalBuffer {
  BYTE* data = nullptr;
  ~LocalBuffer() {
    if (data) LocalFree(data);
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
  status = NCryptFinalizeOperation(key.key);
  if (status != ERROR_SUCCESS) {
    throw_ncrypt_status("finalizing the persisted identity key", status);
  }

  DWORD subject_size = 0;
  if (!CertStrToNameW(X509_ASN_ENCODING, L"CN=Rivet Device",
                      CERT_X500_NAME_STR, nullptr, nullptr, &subject_size,
                      nullptr)) {
    throw_last_error("encoding the identity subject name");
  }
  LocalBuffer subject;
  subject.data = static_cast<BYTE*>(LocalAlloc(LMEM_FIXED, subject_size));
  if (!subject.data) {
    throw std::bad_alloc();
  }
  if (!CertStrToNameW(X509_ASN_ENCODING, L"CN=Rivet Device",
                      CERT_X500_NAME_STR, nullptr, subject.data(),
                      &subject_size, nullptr)) {
    throw_last_error("encoding the identity subject name");
  }
  CERT_NAME_BLOB subject_blob;
  subject_blob.cbData = subject_size;
  subject_blob.pbData = subject.data;

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
  CERT_CREATE_SELF_SIGN_CERT_PARAM self_sign{};
  self_sign.pSubjectIssuerBlob = &subject_blob;
  self_sign.pSignatureAlgorithm = &signature;
  self_sign.pNotBefore = &now;
  self_sign.pNotAfter = &expires;
  self_sign.pKeyProvInfo = &prov_info;
  self_sign.cExtension = 0;
  self_sign.rgExtension = &extensions.rgExtension[0];
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
  return x509_spki_sha256(std::vector<std::uint8_t>(
      context_->pbCertEncoded,
      context_->pbCertEncoded + context_->cbCertEncoded));
}

DeviceIdentity::DeviceIdentity(const CERT_CONTEXT* context)
    : context_(context) {}

void DeviceIdentity::ContextDeleter::operator()(CERT_CONTEXT const* context)
    const noexcept {
  CertFreeCertificateContext(const_cast<CERT_CONTEXT*>(context));
}

}  // namespace rivet::windows
