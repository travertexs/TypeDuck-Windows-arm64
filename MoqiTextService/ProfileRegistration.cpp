#include "TypeDuckProfile.h"
#include "../TypeDuckRegistration.h"
#include <msctf.h>

namespace Moqi::TypeDuck {
// The selected profile has already been registered and enabled before this is
// called. Never unregister the whole TIP during an update: its identity and
// backend remain unchanged, and removing it first can lose user enablement.
HRESULT removeOtherLanguageProfile() {
  Ime::ComPtr<ITfInputProcessorProfileMgr> manager;
  HRESULT hr = CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr,
                               CLSCTX_INPROC_SERVER, IID_ITfInputProcessorProfileMgr,
                               reinterpret_cast<void**>(&manager));
  if (FAILED(hr)) return hr;
  const LANGID oldLanguage = _wcsicmp(localeName(), L"zh-TW") == 0 ? 0x0c04 : 0x0404;
  TF_INPUTPROCESSORPROFILE profile = {};
  hr = manager->GetProfile(TF_PROFILETYPE_INPUTPROCESSOR, oldLanguage,
                          kTextServiceClsid, kProfileGuid, nullptr, &profile);
  if (SUCCEEDED(hr)) {
    hr = manager->UnregisterProfile(kTextServiceClsid, oldLanguage, kProfileGuid, 0);
    if (FAILED(hr)) return hr;
  } else if (hr != E_FAIL && hr != HRESULT_FROM_WIN32(ERROR_NOT_FOUND)) {
    return hr;
  }

#ifndef _WIN64
  // libIME2 writes a Settings entry into each loaded user hive when registering.
  // Remove only the old TypeDuck value, including if it was grouped under a
  // different Chinese locale. Keep other IMEs, language keys and preferences.
  const std::wstring oldValue = (oldLanguage == 0x0404 ? L"0404:" : L"0c04:") +
      std::wstring(TypeDuckRegistration::kClsid) + TypeDuckRegistration::kProfile;
  for (DWORD index = 0;; ++index) {
    wchar_t sid[256] = {};
    DWORD length = ARRAYSIZE(sid);
    const LSTATUS status = RegEnumKeyExW(HKEY_USERS, index, sid, &length,
                                        nullptr, nullptr, nullptr, nullptr);
    if (status == ERROR_NO_MORE_ITEMS) break;
    if (status != ERROR_SUCCESS) return HRESULT_FROM_WIN32(status);
    const std::wstring root = std::wstring(sid) + L"\\Control Panel\\International\\User Profile";
    HKEY user = nullptr;
    if (RegOpenKeyExW(HKEY_USERS, root.c_str(), 0, KEY_ENUMERATE_SUB_KEYS, &user) != ERROR_SUCCESS)
      continue;
    for (DWORD localeIndex = 0;; ++localeIndex) {
      wchar_t locale[128] = {};
      DWORD localeLength = ARRAYSIZE(locale);
      const LSTATUS next = RegEnumKeyExW(user, localeIndex, locale, &localeLength,
                                        nullptr, nullptr, nullptr, nullptr);
      if (next == ERROR_NO_MORE_ITEMS) break;
      if (next != ERROR_SUCCESS) break;
      HKEY key = nullptr;
      if (RegOpenKeyExW(user, locale, 0, KEY_SET_VALUE, &key) == ERROR_SUCCESS) {
        RegDeleteValueW(key, oldValue.c_str());
        RegCloseKey(key);
      }
    }
    RegCloseKey(user);
  }
#endif
  return S_OK;
}
}  // namespace Moqi::TypeDuck
