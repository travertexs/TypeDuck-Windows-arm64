#include <windows.h>
#include <msctf.h>
#include <cstdio>

int wmain() {
  HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(hr)) return 1;
  CLSID clsid = {};
  hr = CLSIDFromString(L"{7D92985A-BC53-47B5-A5CC-6E47F86B9D18}", &clsid);
  ITfTextInputProcessor* service = nullptr;
  if (SUCCEEDED(hr)) {
    hr = CoCreateInstance(clsid, nullptr, CLSCTX_INPROC_SERVER,
                          IID_ITfTextInputProcessor,
                          reinterpret_cast<void**>(&service));
  }
  if (service) service->Release();
  std::printf("TypeDuck COM activation: 0x%08lx\n", hr);
  CoUninitialize();
  return SUCCEEDED(hr) ? 0 : 2;
}
