#pragma once
#include <windows.h>
#include <bcrypt.h>
#include <array>
#include <string>
#include <string_view>
#include <vector>

namespace typeduck::compat {
inline constexpr wchar_t kHookName[] = L"TypeDuckKeyboardCompatHook.dll";

inline bool IsTypeDuckTip(std::wstring_view tip) {
  constexpr std::wstring_view suffix = L":{7D92985A-BC53-47B5-A5CC-6E47F86B9D18}{C6E8F5DF-6504-44F9-B7CF-17A195373A83}";
  if (tip.size() != 4 + suffix.size()) return false;
  const auto locale = tip.substr(0, 4);
  if (CompareStringOrdinal(locale.data(), 4, L"0404", 4, TRUE) != CSTR_EQUAL &&
      CompareStringOrdinal(locale.data(), 4, L"0C04", 4, TRUE) != CSTR_EQUAL) return false;
  return CompareStringOrdinal(tip.data() + 4, static_cast<int>(suffix.size()),
                              suffix.data(), static_cast<int>(suffix.size()), TRUE) == CSTR_EQUAL;
}

inline bool IsWindowsInputHostPath(const std::wstring& path) {
  wchar_t windows[MAX_PATH]{};
  if (!GetWindowsDirectoryW(windows, MAX_PATH)) return false;
  const std::wstring expected = std::wstring(windows) + L"\\SystemApps\\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\\TextInputHost.exe";
  return CompareStringOrdinal(path.c_str(), -1, expected.c_str(), -1, TRUE) == CSTR_EQUAL;
}
}  // namespace typeduck::compat
