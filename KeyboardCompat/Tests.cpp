#include "Compat.h"
#include "DynamicLookup.h"
#include <detours.h>
#include <iostream>
#include <cstring>

static volatile int parts[] = {1, 2, 3, 5};
static __declspec(noinline) int Original(int value) { return value + parts[0] + parts[1] + parts[2] + parts[3]; }
static int (*original)(int) = Original;
static __declspec(noinline) int Redirect(int value) { return original(value) + 7; }
static int failures = 0;
static void Check(bool success, const char* name) { std::cout << (success ? "PASS " : "FAIL ") << name << '\n'; failures += !success; }

static void CheckRuntimeDiscovery() {
  using namespace typeduck::compat;
  std::vector<std::uint32_t> image(0x1000 / 4);
  std::array<std::pair<size_t, size_t>, 1> codeRange{{{0x100, 0x1000}}};
  auto put = [&](size_t function, size_t getter, size_t field, size_t getSlot, size_t clearSlot) {
    std::copy(kLookupShape.begin(), kLookupShape.end(), image.begin() + function / 4);
    std::copy(kGetterShape.begin(), kGetterShape.end(), image.begin() + getter / 4);
    for (size_t offset : {0x9Cu, 0xACu})
      image[(function + offset) / 4] = (image[(function + offset) / 4] & 0xFFC003FFu) | static_cast<UINT32>((field / 8) << 10);
    image[(function + 0xF0) / 4] = 0x94000000u | (static_cast<UINT32>((static_cast<int>(getter) - static_cast<int>(function + 0xF0)) / 4) & 0x03FFFFFFu);
    image[(getter + 0x28) / 4] = 0xF9400108u | static_cast<UINT32>(getSlot << 10);
    image[(function + 0x170) / 4] = 0xF9400108u | static_cast<UINT32>(clearSlot << 10);
  };
  put(0x100, 0x600, 0x98, 14, 11);
  auto found = FindLookup(image, codeRange);
  Check(found && found->rva == 0x100 && found->profileTipOffset == 0x98 && found->getByKlidSlot == 14,
        "Runtime code discovery without a Windows version or hash");
  std::fill(image.begin(), image.end(), 0u);
  put(0x700, 0x100, 0xB0, 16, 13);
  found = FindLookup(image, codeRange);
  Check(found && found->rva == 0x700 && found->profileTipOffset == 0xB0 && found->getByKlidSlot == 16 && found->clearOverrideSlot == 13,
        "Relocated function, backward call, changed profile and COM offsets");
  image[(0x700 + 0xAC) / 4] += 1u << 10;
  Check(!FindLookup(image, codeRange), "Inconsistent profile accesses rejected");
  put(0x700, 0x100, 0xB0, 16, 13);
  image[(0x100 + 0x28) / 4] = 0;
  Check(!FindLookup(image, codeRange), "Unrelated call target rejected");
  put(0x700, 0x100, 0xB0, 16, 13);
  put(0x300, 0x500, 0x98, 14, 11);
  Check(!FindLookup(image, codeRange), "Ambiguous matching functions rejected");
  codeRange[0].second = 0x2000;
  Check(!FindLookup(image, codeRange), "Out of bounds executable section rejected");
}

int main() {
  CheckRuntimeDiscovery();
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
