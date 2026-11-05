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
  // Activate() on the thread manager returns the APPLICATION's client ID.
  // Bind this manually created TIP to its own CLSID, as TSF does when loading
  // it, so GetFunctionProvider(CLSID) can find the single-sink registration.
  ComPtr<ITfClientId> clientIds;
  CHECK_HR(thread.As(&clientIds));
  CHECK_HR(clientIds->GetClientId(clsid, &client));
  CHECK_HR(service->Activate(thread.Get(), client));
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
    CHECK_HR(service.As(&sink));
    CHECK(ProbeTouchPackets(sink.Get()) == 0);
  }
  discovered.Reset();
  CHECK_HR(service->Deactivate());
  CHECK(FAILED(thread->GetFunctionProvider(clsid, &discovered)));
  CHECK_HR(service->Activate(thread.Get(), client));
  CHECK_HR(thread->GetFunctionProvider(clsid, &discovered));
  discovered.Reset();
  CHECK_HR(service->Deactivate());
  CHECK_HR(thread->Deactivate());
  std::puts("PASS TSF function-provider advice, deactivation and reactivation");

  if (locale) {
    CHECK(TypeDuckRegistration::NormalizeLocale(locale) != nullptr);
    const LANGID selected = _wcsicmp(locale, L"zh-TW") == 0 ? 0x0404 : 0x0c04;
    const LANGID old = selected == 0x0404 ? 0x0c04 : 0x0404;
    ComPtr<ITfInputProcessorProfileMgr> profiles;
    CHECK_HR(CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&profiles)));
    TF_INPUTPROCESSORPROFILE profile = {};
    CHECK_HR(profiles->GetProfile(TF_PROFILETYPE_INPUTPROCESSOR, selected, clsid, profileId, nullptr, &profile));
    CHECK(FAILED(profiles->GetProfile(TF_PROFILETYPE_INPUTPROCESSOR, old, clsid, profileId, nullptr, &profile)));
    ComPtr<ITfInputProcessorProfiles> enabled;
    CHECK_HR(profiles.As(&enabled));
    BOOL isEnabled = FALSE;
    CHECK_HR(enabled->IsEnabledLanguageProfile(clsid, selected, profileId, &isEnabled));
    CHECK(isEnabled);
    std::printf("PASS selected language 0x%04x enabled; old language 0x%04x absent\n", selected, old);
  }
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
