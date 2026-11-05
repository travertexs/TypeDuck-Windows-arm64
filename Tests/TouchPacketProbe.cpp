#include <windows.h>
#include <msctf.h>
#include <cstdio>
#include <initializer_list>
#include "../libIME2/src/KeyEvent.h"
#include "../MoqiTextService/TouchKeyboard.h"

namespace {
struct State {
  ITfKeyEventSink* sink;
  wchar_t expected = 0;
  int received = 0;
  bool failed = false;
};

LRESULT CALLBACK WindowProcedure(HWND window, UINT message, WPARAM key, LPARAM flags) {
  if (message == WM_NCCREATE) {
    const auto create = reinterpret_cast<CREATESTRUCTW*>(flags);
    SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  }
  auto state = reinterpret_cast<State*>(GetWindowLongPtrW(window, GWLP_USERDATA));
  if (state && (message == WM_KEYDOWN || message == WM_KEYUP) && key == VK_PACKET) {
    Ime::KeyEvent event(message, key, flags);
    ++state->received;
    if (event.charCode() != state->expected) {
      std::printf("FAIL Unicode packet decode: expected %04x, got %04x\n", state->expected, event.charCode());
      state->failed = true;
    }
    if (Moqi::TouchKeyboard::IsPageKey(event.keyCode(), event.charCode())) {
      BOOL testEaten = FALSE, keyEaten = FALSE;
      const HRESULT test = message == WM_KEYDOWN
          ? state->sink->OnTestKeyDown(nullptr, key, flags, &testEaten)
          : state->sink->OnTestKeyUp(nullptr, key, flags, &testEaten);
      const HRESULT actual = message == WM_KEYDOWN
          ? state->sink->OnKeyDown(nullptr, key, flags, &keyEaten)
          : state->sink->OnKeyUp(nullptr, key, flags, &keyEaten);
      if (FAILED(test) || FAILED(actual) || !testEaten || !keyEaten) {
        std::puts("FAIL private touch paging packet was not consumed with the IME closed");
        state->failed = true;
      }
    }
    return 0;
  }
  return DefWindowProcW(window, message, key, flags);
}
}

// Explicitly enabled by the disposable CI runner; never sends user text.
int ProbeTouchPackets(ITfKeyEventSink* sink) {
  State state{sink};
  WNDCLASSW wc = {};
  wc.lpfnWndProc = WindowProcedure;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = L"TypeDuckSyntheticTouchPacketProbe";
  if (!RegisterClassW(&wc)) return 4;
  HWND window = CreateWindowW(wc.lpszClassName, L"TypeDuck synthetic touch input test",
      WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 480, 180,
      nullptr, nullptr, wc.hInstance, &state);
  if (!window) return 4;
  ShowWindow(window, SW_SHOWNORMAL);
  SetForegroundWindow(window);
  SetFocus(window);
  if (GetForegroundWindow() != window) state.failed = true;
  for (wchar_t character : {L'n', L'e', L'i', L'5', L' ', wchar_t(0xf003), wchar_t(0xf004)}) {
    if (state.failed) break;
    state.expected = character;
    state.received = 0;
    INPUT packets[2] = {};
    for (auto& packet : packets) {
      packet.type = INPUT_KEYBOARD;
      packet.ki.wScan = character;
      packet.ki.dwFlags = KEYEVENTF_UNICODE;
    }
    packets[1].ki.dwFlags |= KEYEVENTF_KEYUP;
    if (SendInput(2, packets, sizeof(INPUT)) != 2) { state.failed = true; break; }
    const auto deadline = GetTickCount64() + 3000;
    while (state.received < 2 && GetTickCount64() < deadline) {
      MSG msg;
      while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) DispatchMessageW(&msg);
      if (state.received < 2) MsgWaitForMultipleObjects(0, nullptr, FALSE, 50, QS_ALLINPUT);
    }
    if (state.received != 2) state.failed = true;
  }
  DestroyWindow(window);
  UnregisterClassW(wc.lpszClassName, wc.hInstance);
  std::puts(state.failed ? "FAIL synthetic touch packet test" :
      "PASS real SendInput Unicode decoding and closed-IME private paging consumption (both key edges)");
  return state.failed ? 4 : 0;
}
