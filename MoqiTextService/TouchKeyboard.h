#pragma once
#include <windows.h>

namespace Moqi::TouchKeyboard {
inline constexpr UINT kNextPage = 0xf003;
inline constexpr UINT kPreviousPage = 0xf004;

inline bool IsPageKey(UINT virtualKey, UINT character) {
  return virtualKey == VK_PACKET &&
         (character == kNextPage || character == kPreviousPage);
}

// VK_PACKET carries Unicode rather than a physical key. Preserve that character
// for the engine; supply the corresponding virtual key only for ASCII typing.
inline UINT EngineKeyCode(UINT virtualKey, UINT character) {
  if (virtualKey != VK_PACKET) return virtualKey;
  if (character >= L'a' && character <= L'z') return character - L'a' + L'A';
  if ((character >= L'A' && character <= L'Z') ||
      (character >= L'0' && character <= L'9')) return character;
  switch (character) {
    case L' ': return VK_SPACE;
    case L'\r': return VK_RETURN;
    case L'\b': return VK_BACK;
    case L'\t': return VK_TAB;
    default: return virtualKey;
  }
}
}  // namespace Moqi::TouchKeyboard
