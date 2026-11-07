#include "Compat.h"
#include <detours.h>
#include <iostream>
#include <cstring>

static volatile int parts[] = {1, 2, 3, 5};
static __declspec(noinline) int Original(int value) { return value + parts[0] + parts[1] + parts[2] + parts[3]; }
static int (*original)(int) = Original;
static __declspec(noinline) int Redirect(int value) { return original(value) + 7; }
static int failures = 0;
static void Check(bool success, const char* name) { std::cout << (success ? "PASS " : "FAIL ") << name << '\n'; failures += !success; }

int main() {
  using namespace typeduck::compat;
  const std::wstring tw = L"0404:{7D92985A-BC53-47B5-A5CC-6E47F86B9D18}{C6E8F5DF-6504-44F9-B7CF-17A195373A83}";
  Check(IsTypeDuckTip(tw), "Taiwan exact TypeDuck profile");
  Check(IsTypeDuckTip(L"0c04" + tw.substr(4)), "Hong Kong profile case insensitive");
  Check(!IsTypeDuckTip(L"0409" + tw.substr(4)), "Other language stays unchanged");
  std::wstring other = tw; other[10] = L'0';
  Check(!IsTypeDuckTip(other), "Other IME CLSID stays unchanged");
  other = tw; other[70] = L'0';
  Check(!IsTypeDuckTip(other), "Other profile GUID stays unchanged");
  Check(!IsTypeDuckTip(tw + L"x") && !IsTypeDuckTip(tw.substr(0, 40)) && !IsTypeDuckTip(L""), "Malformed profile stays unchanged");
  Check(!IsWindowsInputHostPath(L"C:\\Temp\\TextInputHost.exe"), "Untrusted executable location rejected");
  Check(Sha256File(L"Z:\\nonexistent-typeduck-compat-test").empty(), "Missing binary cannot match allowlist");
  std::array<BYTE, 16> before{};
  std::memcpy(before.data(), reinterpret_cast<void*>(Original), before.size());
  LONG status = DetourTransactionBegin();
  if (!status) status = DetourUpdateThread(GetCurrentThread());
  if (!status) status = DetourAttach(reinterpret_cast<PVOID*>(&original), Redirect);
  if (!status) status = DetourTransactionCommit(); else DetourTransactionAbort();
  Check(status == NO_ERROR, "Native ARM64 attach transaction");
  int (*volatile invoke)(int) = Original;
  Check(invoke(5) == 23, "Redirect preserves original call and return");
  status = DetourTransactionBegin();
  if (!status) status = DetourUpdateThread(GetCurrentThread());
  if (!status) status = DetourDetach(reinterpret_cast<PVOID*>(&original), Redirect);
  if (!status) status = DetourTransactionCommit(); else DetourTransactionAbort();
  Check(status == NO_ERROR && invoke(5) == 16, "Detach restores behavior");
  Check(std::memcmp(before.data(), reinterpret_cast<void*>(Original), before.size()) == 0, "Detach restores original instructions");
  return failures ? 1 : 0;
}
