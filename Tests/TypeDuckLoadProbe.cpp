#include <windows.h>
#include <msctf.h>
#include <ctffunc.h>
#include <wrl/client.h>
#include <cstdio>
#include "../TypeDuckRegistration.h"

using Microsoft::WRL::ComPtr;
int ProbeTouchPackets(ITfKeyEventSink* sink);
#define CHECK_HR(call) do { HRESULT result = (call); if (FAILED(result)) { \
  std::printf("FAIL %s: 0x%08lx (line %d)\n", #call, result, __LINE__); return 2; } } while (0)
#define CHECK(condition) do { if (!(condition)) { \
  std::printf("FAIL %s (line %d)\n", #condition, __LINE__); return 3; } } while (0)

bool RegistryMatchesLocale(const wchar_t* locale) {
  if (TypeDuckRegistration::ReadLocale() != locale) return false;
  const std::wstring root = L"SOFTWARE\\Microsoft\\CTF\\TIP\\" +
      std::wstring(TypeDuckRegistration::kClsid) + L"\\LanguageProfile\\";
  const bool taiwan = _wcsicmp(locale, L"zh-TW") == 0;
  const auto selected = root + (taiwan ? L"0x00000404\\" : L"0x00000c04\\") + TypeDuckRegistration::kProfile;
  const auto old = root + (taiwan ? L"0x00000c04\\" : L"0x00000404\\") + TypeDuckRegistration::kProfile;
#ifdef _WIN64
  const REGSAM view = KEY_WOW64_64KEY;
#else
  const REGSAM view = KEY_WOW64_32KEY;
#endif
  HKEY key = nullptr;
  const auto selectedStatus = RegOpenKeyExW(HKEY_LOCAL_MACHINE, selected.c_str(), 0, KEY_READ | view, &key);
  if (key) RegCloseKey(key);
  key = nullptr;
  const auto oldStatus = RegOpenKeyExW(HKEY_LOCAL_MACHINE, old.c_str(), 0, KEY_READ | view, &key);
  if (key) RegCloseKey(key);
  return selectedStatus == ERROR_SUCCESS && oldStatus == ERROR_FILE_NOT_FOUND;
}

int Probe(const wchar_t* locale, bool testPackets) {
  CLSID clsid = {}, profileId = {};
  CHECK_HR(CLSIDFromString(TypeDuckRegistration::kClsid, &clsid));
  CHECK_HR(CLSIDFromString(TypeDuckRegistration::kProfile, &profileId));
  ComPtr<ITfTextInputProcessor> service;
  CHECK_HR(CoCreateInstance(clsid, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&service)));
  std::puts("PASS COM activation");

  ComPtr<ITfFunctionProvider> provider;
  CHECK_HR(service.As(&provider));
  GUID type = {};
  CHECK_HR(provider->GetType(&type));
  CHECK(type == clsid);
  CHECK(provider->GetType(nullptr) == E_POINTER);
  ComPtr<IUnknown> function;
  CHECK_HR(provider->GetFunction(GUID_NULL, __uuidof(ITfFnGetPreferredTouchKeyboardLayout), &function));
  ComPtr<ITfFnGetPreferredTouchKeyboardLayout> layout;
  CHECK_HR(function.As(&layout));
  ComPtr<IUnknown> serviceIdentity, layoutIdentity;
  CHECK_HR(service.As(&serviceIdentity));
  CHECK_HR(layout.As(&layoutIdentity));
  CHECK(serviceIdentity.Get() == layoutIdentity.Get());
  TKBLayoutType layoutType = TKBLT_UNDEFINED;
  WORD layoutId = 0;
  CHECK_HR(layout->GetLayout(&layoutType, &layoutId));
  CHECK(layoutType == TKBLT_OPTIMIZED && layoutId == 0x0804);
  CHECK(layout->GetLayout(nullptr, &layoutId) == E_POINTER);
  CHECK(layout->GetLayout(&layoutType, nullptr) == E_POINTER);
  BSTR name = nullptr;
  CHECK_HR(layout->GetDisplayName(&name));
  CHECK(name && SysStringLen(name) > 0);
  SysFreeString(name);
  IUnknown* unknown = reinterpret_cast<IUnknown*>(1);
  CHECK(provider->GetFunction(clsid, IID_IUnknown, &unknown) == E_NOINTERFACE);
  CHECK(unknown == nullptr);
  std::puts("PASS touch layout, function discovery, COM identity and pointer contracts");

  ComPtr<ITfThreadMgr> thread;
  CHECK_HR(CoCreateInstance(CLSID_TF_ThreadMgr, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&thread)));
  TfClientId client = TF_CLIENTID_NULL;
  CHECK_HR(thread->Activate(&client));
  CHECK(locale && TypeDuckRegistration::NormalizeLocale(locale));
  const LANGID selected = _wcsicmp(locale, L"zh-TW") == 0 ? 0x0404 : 0x0c04;
  const LANGID old = selected == 0x0404 ? 0x0c04 : 0x0404;
  ComPtr<ITfInputProcessorProfileMgr> profiles;
  CHECK_HR(CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER,
                            IID_PPV_ARGS(&profiles)));
  ComPtr<ITfInputProcessorProfiles> languages;
  CHECK_HR(profiles.As(&languages));
  // Refresh this test thread's input-language context after a registration
  // migration before asking TSF for its cached language profile.
  HRESULT languageResult = E_FAIL;
  const auto languageDeadline = GetTickCount64() + 5000;
  int refreshAttempts = 0;
  do {
    languageResult = languages->ChangeCurrentLanguage(selected);
    if (SUCCEEDED(languageResult)) break;
    MSG message;
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) DispatchMessageW(&message);
    Sleep(50);
    ++refreshAttempts;
  } while (languageResult == E_FAIL && GetTickCount64() < languageDeadline);
  if (FAILED(languageResult) && RegistryMatchesLocale(locale)) {
    std::puts("RETRY fresh process: TSF language cache has not incorporated the verified registration");
    return 75;
  }
  CHECK_HR(languageResult);
  if (refreshAttempts) std::printf("TSF migration notification settled after %d refresh attempts\n", refreshAttempts);
  TF_INPUTPROCESSORPROFILE profile = {}, oldProfile = {};
  HRESULT selectedResult = E_FAIL, oldResult = S_OK;
  const auto profileDeadline = GetTickCount64() + 5000;
  do {
    selectedResult = profiles->GetProfile(TF_PROFILETYPE_INPUTPROCESSOR, selected, clsid, profileId, nullptr, &profile);
    oldResult = profiles->GetProfile(TF_PROFILETYPE_INPUTPROCESSOR, old, clsid, profileId, nullptr, &oldProfile);
    if (SUCCEEDED(selectedResult) && FAILED(oldResult)) break;
    MSG message;
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) DispatchMessageW(&message);
    Sleep(50);
  } while (GetTickCount64() < profileDeadline);
  std::printf("TSF profile results: selected=0x%08lx (language 0x%04x), old=0x%08lx (language 0x%04x)\n",
              selectedResult, profile.langid, oldResult, oldProfile.langid);
  if ((FAILED(selectedResult) || SUCCEEDED(oldResult)) && RegistryMatchesLocale(locale)) {
    std::puts("RETRY fresh process: TSF profile snapshot is stale; exact selected registry profile verified");
    return 75;
  }
  CHECK_HR(selectedResult);
  CHECK(FAILED(oldResult));
  BOOL enabled = FALSE;
  CHECK_HR(languages->IsEnabledLanguageProfile(clsid, selected, profileId, &enabled));
  CHECK(enabled);
  std::printf("PASS selected language 0x%04x enabled; old language 0x%04x absent\n", selected, old);

  // Let TSF activate the registered TIP. Calling Activate() on an unrelated
  // CoCreateInstance object does not add it to TSF's active provider list.
  ComPtr<ITfDocumentMgr> document;
  ComPtr<ITfContext> context;
  TfEditCookie cookie = TF_INVALID_COOKIE;
  CHECK_HR(thread->CreateDocumentMgr(&document));
  CHECK_HR(document->CreateContext(client, 0, nullptr, &context, &cookie));
  CHECK_HR(document->Push(context.Get()));
  CHECK_HR(thread->SetFocus(document.Get()));
  CHECK_HR(profiles->ActivateProfile(TF_PROFILETYPE_INPUTPROCESSOR, selected,
                                    clsid, profileId, nullptr, TF_IPPMF_FORPROCESS));
  ComPtr<ITfFunctionProvider> discovered;
  CHECK_HR(thread->GetFunctionProvider(clsid, &discovered));
  CHECK_HR(discovered->GetFunction(GUID_NULL, __uuidof(ITfFnGetPreferredTouchKeyboardLayout), &unknown));
  unknown->Release();
  ComPtr<ITfCompartmentMgr> compartments;
  CHECK_HR(thread.As(&compartments));
  ComPtr<ITfCompartment> openClose, conversion;
  CHECK_HR(compartments->GetCompartment(GUID_COMPARTMENT_KEYBOARD_OPENCLOSE, &openClose));
  CHECK_HR(compartments->GetCompartment(GUID_COMPARTMENT_KEYBOARD_INPUTMODE_CONVERSION, &conversion));
  VARIANT value = {}, actual = {};
  value.vt = VT_I4;
  value.lVal = 0;
  CHECK_HR(openClose->SetValue(client, &value));
  CHECK_HR(conversion->GetValue(&actual));
  CHECK(actual.vt == VT_I4 && (actual.lVal & TF_CONVERSIONMODE_NATIVE) == 0);
  VariantClear(&actual);
  value.lVal = TF_CONVERSIONMODE_NATIVE;
  CHECK_HR(conversion->SetValue(client, &value));
  CHECK_HR(openClose->GetValue(&actual));
  CHECK(actual.vt == VT_I4 && actual.lVal != 0);
  VariantClear(&actual);
  std::puts("PASS bidirectional touch keyboard conversion-mode synchronization");
  if (testPackets) {
    value.lVal = 0;
    CHECK_HR(openClose->SetValue(client, &value));
    ComPtr<ITfKeyEventSink> sink;
    CHECK_HR(discovered.As(&sink));
    const int packetResult = ProbeTouchPackets(sink.Get());
    CHECK(packetResult == 0 || packetResult == 77);
  }
  discovered.Reset();
  CHECK_HR(profiles->DeactivateProfile(TF_PROFILETYPE_INPUTPROCESSOR, selected,
                                      clsid, profileId, nullptr, TF_IPPMF_FORPROCESS));
  CHECK(FAILED(thread->GetFunctionProvider(clsid, &discovered)));
  CHECK_HR(profiles->ActivateProfile(TF_PROFILETYPE_INPUTPROCESSOR, selected,
                                    clsid, profileId, nullptr, TF_IPPMF_FORPROCESS));
  CHECK_HR(thread->GetFunctionProvider(clsid, &discovered));
  discovered.Reset();
  CHECK_HR(profiles->DeactivateProfile(TF_PROFILETYPE_INPUTPROCESSOR, selected,
                                      clsid, profileId, nullptr, TF_IPPMF_FORPROCESS));
  CHECK_HR(thread->SetFocus(nullptr));
  CHECK_HR(document->Pop(TF_POPF_ALL));
  CHECK_HR(thread->Deactivate());
  std::puts("PASS TSF function-provider advice, deactivation and reactivation");

  return 0;
}

int wmain(int argc, wchar_t** argv) {
  const HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(hr)) return 1;
  const int result = Probe(argc > 1 ? argv[1] : nullptr,
                           argc > 2 && wcscmp(argv[2], L"--touch-packets") == 0);
  CoUninitialize();
  return result;
}
