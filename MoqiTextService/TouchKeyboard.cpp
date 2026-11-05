#include "MoqiTextService.h"
#include "TypeDuckProfile.h"
#include "TouchKeyboard.h"

namespace Moqi {
namespace {
bool IsInactivePagePacket(TextService* service, ITfContext* context,
                          UINT message, WPARAM key, LPARAM flags) {
  if (key != VK_PACKET) return false;
  Ime::KeyEvent event(message, key, flags);
  return TouchKeyboard::IsPageKey(event.keyCode(), event.charCode()) &&
         (!service->isKeyboardOpened() || service->isKeyboardDisabled(context));
}
}

// libIME2 bypasses its virtual key handlers when the IME is closed/disabled.
// Still swallow the touch keyboard's private commands in that state.
STDMETHODIMP TextService::OnTestKeyDown(ITfContext* context, WPARAM key, LPARAM flags, BOOL* eaten) {
  if (!eaten) return E_POINTER;
  if (IsInactivePagePacket(this, context, WM_KEYDOWN, key, flags)) { *eaten = TRUE; return S_OK; }
  return Ime::TextService::OnTestKeyDown(context, key, flags, eaten);
}
STDMETHODIMP TextService::OnKeyDown(ITfContext* context, WPARAM key, LPARAM flags, BOOL* eaten) {
  if (!eaten) return E_POINTER;
  if (IsInactivePagePacket(this, context, WM_KEYDOWN, key, flags)) { *eaten = TRUE; return S_OK; }
  return Ime::TextService::OnKeyDown(context, key, flags, eaten);
}
STDMETHODIMP TextService::OnTestKeyUp(ITfContext* context, WPARAM key, LPARAM flags, BOOL* eaten) {
  if (!eaten) return E_POINTER;
  if (IsInactivePagePacket(this, context, WM_KEYUP, key, flags)) { *eaten = TRUE; return S_OK; }
  return Ime::TextService::OnTestKeyUp(context, key, flags, eaten);
}
STDMETHODIMP TextService::OnKeyUp(ITfContext* context, WPARAM key, LPARAM flags, BOOL* eaten) {
  if (!eaten) return E_POINTER;
  if (IsInactivePagePacket(this, context, WM_KEYUP, key, flags)) { *eaten = TRUE; return S_OK; }
  return Ime::TextService::OnKeyUp(context, key, flags, eaten);
}

STDMETHODIMP TextService::QueryInterface(REFIID iid, void** result) {
  if (!result) return E_POINTER;
  *result = nullptr;
  if (iid == IID_ITfFunctionProvider)
    *result = static_cast<ITfFunctionProvider*>(this);
  else if (iid == __uuidof(ITfFnGetPreferredTouchKeyboardLayout) || iid == IID_ITfFunction)
    *result = static_cast<ITfFnGetPreferredTouchKeyboardLayout*>(this);
  else
    return Ime::TextService::QueryInterface(iid, result);
  AddRef();
  return S_OK;
}

STDMETHODIMP TextService::GetType(GUID* guid) {
  if (!guid) return E_POINTER;
  *guid = TypeDuck::kTextServiceClsid;
  return S_OK;
}

STDMETHODIMP TextService::GetDescription(BSTR* description) {
  return GetDisplayName(description);
}

STDMETHODIMP TextService::GetDisplayName(BSTR* name) {
  if (!name) return E_POINTER;
  *name = SysAllocString(L"TypeDuck touch keyboard / TypeDuck 觸控鍵盤");
  return *name ? S_OK : E_OUTOFMEMORY;
}

STDMETHODIMP TextService::GetFunction(REFGUID guid, REFIID iid, IUnknown** result) {
  if (!result) return E_POINTER;
  *result = nullptr;
  if (guid != GUID_NULL || (iid != __uuidof(ITfFnGetPreferredTouchKeyboardLayout) &&
                            iid != IID_ITfFunction)) return E_NOINTERFACE;
  return QueryInterface(iid, reinterpret_cast<void**>(result));
}

STDMETHODIMP TextService::GetLayout(TKBLayoutType* type, WORD* id) {
  if (!type || !id) return E_POINTER;
  *type = TKBLT_OPTIMIZED;
  // This is Windows' Latin QWERTY optimized Chinese layout, suitable for
  // Jyutping keys. It is a layout preference only: no Pinyin engine or zh-CN
  // language profile is installed. Microsoft documents this ID for CHS;
  // acceptance for zh-HK/zh-TW and the Small layout depend on the Windows build.
  // The documented CHT optimized layout is Bopomofo, unsuitable for Jyutping.
  *id = 0x0804;  // TKBL_OPT_SIMPLIFIED_CHINESE_PINYIN
  return S_OK;
}

void TextService::adviseTouchKeyboard() {
  if (auto source = threadMgr().query<ITfSourceSingle>()) {
    const HRESULT hr = source->AdviseSingleSink(clientId(), IID_ITfFunctionProvider,
                                               static_cast<ITfFunctionProvider*>(this));
    touchKeyboardAdvised_ = SUCCEEDED(hr);
  }
  syncTouchKeyboardMode(isKeyboardOpened());
  if (auto source = threadCompartment(GUID_COMPARTMENT_KEYBOARD_INPUTMODE_CONVERSION).query<ITfSource>())
    source->AdviseSink(IID_ITfCompartmentEventSink,
                      static_cast<ITfCompartmentEventSink*>(this), &touchModeCookie_);
}

void TextService::unadviseTouchKeyboard() {
  if (touchModeCookie_ != TF_INVALID_COOKIE) {
    if (auto source = threadCompartment(GUID_COMPARTMENT_KEYBOARD_INPUTMODE_CONVERSION).query<ITfSource>())
      source->UnadviseSink(touchModeCookie_);
    touchModeCookie_ = TF_INVALID_COOKIE;
  }
  if (touchKeyboardAdvised_) {
    if (auto source = threadMgr().query<ITfSourceSingle>())
      source->UnadviseSingleSink(clientId(), IID_ITfFunctionProvider);
    touchKeyboardAdvised_ = false;
  }
}

void TextService::syncTouchKeyboardMode(bool opened) {
  const DWORD oldMode = threadCompartmentValue(GUID_COMPARTMENT_KEYBOARD_INPUTMODE_CONVERSION);
  const DWORD newMode = opened ? oldMode | TF_CONVERSIONMODE_NATIVE
                              : oldMode & ~TF_CONVERSIONMODE_NATIVE;
  if (newMode != oldMode)
    setThreadCompartmentValue(GUID_COMPARTMENT_KEYBOARD_INPUTMODE_CONVERSION, newMode);
}
}  // namespace Moqi
