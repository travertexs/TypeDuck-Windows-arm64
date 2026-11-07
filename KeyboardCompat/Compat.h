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

inline std::wstring Sha256File(const std::wstring& path) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE,
                            nullptr, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
  if (file == INVALID_HANDLE_VALUE) return {};
  BCRYPT_ALG_HANDLE algorithm{};
  BCRYPT_HASH_HANDLE hash{};
  std::wstring result;
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) >= 0) {
    DWORD objectSize{}, used{};
    if (BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH, reinterpret_cast<PUCHAR>(&objectSize),
                          sizeof(objectSize), &used, 0) >= 0) {
      std::vector<UCHAR> object(objectSize);
      if (BCryptCreateHash(algorithm, &hash, object.data(), objectSize, nullptr, 0, 0) >= 0) {
        std::array<UCHAR, 65536> buffer{};
        DWORD count{};
        bool good = true;
        for (;;) {
          if (!ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()), &count, nullptr)) { good = false; break; }
          if (!count) break;
          if (BCryptHashData(hash, buffer.data(), count, 0) < 0) { good = false; break; }
        }
        std::array<UCHAR, 32> digest{};
        if (good && BCryptFinishHash(hash, digest.data(), static_cast<ULONG>(digest.size()), 0) >= 0) {
          constexpr wchar_t hex[] = L"0123456789ABCDEF";
          for (UCHAR byte : digest) { result += hex[byte >> 4]; result += hex[byte & 15]; }
        }
        BCryptDestroyHash(hash);
      }
    }
    BCryptCloseAlgorithmProvider(algorithm, 0);
  }
  CloseHandle(file);
  return result;
}

inline bool IsWindowsInputHostPath(const std::wstring& path) {
  wchar_t windows[MAX_PATH]{};
  if (!GetWindowsDirectoryW(windows, MAX_PATH)) return false;
  const std::wstring expected = std::wstring(windows) + L"\\SystemApps\\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\\TextInputHost.exe";
  return CompareStringOrdinal(path.c_str(), -1, expected.c_str(), -1, TRUE) == CSTR_EQUAL;
}
}  // namespace typeduck::compat
