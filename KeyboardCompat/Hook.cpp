#include "Compat.h"
#include <detours.h>
#include <tlhelp32.h>
#include <winstring.h>
#include <atomic>
#include <cstring>

using namespace typeduck::compat;
using Lookup = void* (*)(void*, void*);
using GetByKlid = HRESULT(STDMETHODCALLTYPE*)(void*, UINT32, void**);
static Lookup originalLookup{};
static std::atomic<bool> enabled{false};
static bool attached = false;  // Protected by controlLock; detach can fail independently of disable.
static std::atomic<DWORD> redirected{0};
static SRWLOCK controlLock = SRWLOCK_INIT;

// This ABI is used only after the complete Windows DLL hash and prologue match.
// The keyboard COM getter returns one owned reference, matching the original lookup.
static bool MatchesProfile(void* profile) {
  __try {
    HSTRING tip = *reinterpret_cast<HSTRING*>(static_cast<BYTE*>(profile) + kProfileTipOffset);
    UINT32 size{};
    const wchar_t* value = WindowsGetStringRawBuffer(tip, &size);
    return value && IsTypeDuckTip({value, size});
  } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

static void* LookupTypeDuck(void* profile, void* keyboardSet) {
  if (enabled.load(std::memory_order_relaxed) && MatchesProfile(profile)) {
    auto table = *reinterpret_cast<void***>(keyboardSet);
    auto get = reinterpret_cast<GetByKlid>(table[kGetKeyboardByKlidSlot]);
    void* keyboard{};
    if (SUCCEEDED(get(keyboardSet, 0x0409, &keyboard)) && keyboard) {
      redirected.fetch_add(1, std::memory_order_relaxed);
      return keyboard;
    }
  }
  return originalLookup(profile, keyboardSet);
}

static LONG ChangeDetour(bool attach) {
  // Gather and open thread handles before Detours suspends any host threads.
  std::vector<HANDLE> threads;
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return GetLastError();
  THREADENTRY32 entry{sizeof(entry)};
  LONG error = NO_ERROR;
  if (Thread32First(snapshot, &entry)) do {
    if (entry.th32OwnerProcessID != GetCurrentProcessId() || entry.th32ThreadID == GetCurrentThreadId()) continue;
    HANDLE thread = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_SET_CONTEXT | THREAD_QUERY_INFORMATION,
                               FALSE, entry.th32ThreadID);
    if (!thread) { if (GetLastError() != ERROR_INVALID_PARAMETER) error = GetLastError(); }
    else threads.push_back(thread);
  } while (Thread32Next(snapshot, &entry));
  CloseHandle(snapshot);
  if (!error) error = DetourTransactionBegin();
  if (!error) {
    for (HANDLE thread : threads) {
      error = DetourUpdateThread(thread);
      if (error) break;
    }
    if (!error) error = attach ? DetourAttach(reinterpret_cast<PVOID*>(&originalLookup), LookupTypeDuck)
                               : DetourDetach(reinterpret_cast<PVOID*>(&originalLookup), LookupTypeDuck);
    if (error) DetourTransactionAbort();
    else error = DetourTransactionCommit();
  }
  for (HANDLE thread : threads) CloseHandle(thread);
  return error;
}

// Explicit initialization runs outside DllMain and the Windows loader lock.
// The module remains loaded after detach so in-flight calls can return safely.
extern "C" __declspec(dllexport) DWORD WINAPI TypeDuckKeyboardCompatControl(void* argument) {
  const ULONG_PTR command = reinterpret_cast<ULONG_PTR>(argument);
  if (command == 2) return (enabled.load() ? 1u : 0u) | (redirected.load() << 1);
  AcquireSRWLockExclusive(&controlLock);
  DWORD result = NO_ERROR;
  if (command == 1) {
    enabled.store(false);
    if (attached) {
      result = ChangeDetour(false);
      if (!result) attached = false;
    }
  } else if (command != 0) result = ERROR_INVALID_PARAMETER;
  else if (!enabled.load()) {
    if (attached) {
      enabled.store(true);
      ReleaseSRWLockExclusive(&controlLock);
      return NO_ERROR;
    }
    wchar_t host[32768]{}, path[32768]{};
    GetModuleFileNameW(nullptr, host, static_cast<DWORD>(std::size(host)));
    HMODULE module = GetModuleHandleW(L"TextInput.dll");
    if (!IsWindowsInputHostPath(host) || !module ||
        !GetModuleFileNameW(module, path, static_cast<DWORD>(std::size(path))) || Sha256File(path) != kTextInputHash) {
      result = ERROR_NOT_SUPPORTED;
    } else {
      BYTE* site = reinterpret_cast<BYTE*>(module) + kLookupRva;
      if (std::memcmp(site, kLookupInstructions.data(), sizeof(kLookupInstructions)) != 0) result = ERROR_REVISION_MISMATCH;
      else {
        originalLookup = reinterpret_cast<Lookup>(site);
        result = ChangeDetour(true);
        if (!result) { attached = true; enabled.store(true); }
      }
    }
  }
  ReleaseSRWLockExclusive(&controlLock);
  return result;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) {
  if (reason == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(instance);
  return TRUE;
}
