#pragma once

#include <windows.h>
#include <string>

// Shared by setup and the TSF DLL. The profile GUID is independent of LANGID:
// both registrations use the same Cantonese backend and user dictionary.
namespace TypeDuckRegistration {
inline constexpr wchar_t kKey[] = L"Software\\TypeDuckIME";
inline constexpr wchar_t kLocaleValue[] = L"RegistrationLocale";
inline constexpr wchar_t kPendingLocaleValue[] = L"PendingRegistrationLocale";
inline constexpr wchar_t kLocaleEnvironment[] = L"TYPEDUCK_IME_LOCALE";
inline constexpr wchar_t kClsid[] = L"{7D92985A-BC53-47B5-A5CC-6E47F86B9D18}";
inline constexpr wchar_t kProfile[] = L"{C6E8F5DF-6504-44F9-B7CF-17A195373A83}";

inline const wchar_t* NormalizeLocale(const std::wstring& value) {
  if (_wcsicmp(value.c_str(), L"zh-TW") == 0) return L"zh-TW";
  if (_wcsicmp(value.c_str(), L"zh-HK") == 0) return L"zh-HK";
  return nullptr;
}

inline std::wstring ReadLocale(const wchar_t* valueName = kLocaleValue) {
  for (REGSAM view : {KEY_WOW64_64KEY, KEY_WOW64_32KEY}) {
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, kKey, 0, KEY_QUERY_VALUE | view, &key) != ERROR_SUCCESS)
      continue;
    wchar_t value[16] = {};
    DWORD bytes = sizeof(value);
    const LSTATUS status = RegGetValueW(key, nullptr, valueName, RRF_RT_REG_SZ,
                                       nullptr, value, &bytes);
    RegCloseKey(key);
    if (status == ERROR_SUCCESS) {
      if (const auto locale = NormalizeLocale(value)) return locale;
    }
  }
  return {};
}

inline const wchar_t* SelectedLocale() {
  wchar_t value[16] = {};
  const DWORD length = GetEnvironmentVariableW(kLocaleEnvironment, value, ARRAYSIZE(value));
  if (length > 0 && length < ARRAYSIZE(value)) {
    if (const auto locale = NormalizeLocale(value)) return locale;
  }
  const auto saved = ReadLocale();
  return saved == L"zh-TW" ? L"zh-TW" : L"zh-HK";
}
}  // namespace TypeDuckRegistration
