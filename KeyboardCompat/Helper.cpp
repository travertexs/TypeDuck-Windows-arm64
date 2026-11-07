#include "Compat.h"
#include <tlhelp32.h>
#include <iostream>
#include <filesystem>

using namespace typeduck::compat;
struct Handle {
  HANDLE value{};
  explicit Handle(HANDLE h = nullptr) : value(h) {}
  ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
  Handle(const Handle&) = delete;
};

static std::vector<MODULEENTRY32W> Modules(DWORD pid) {
  std::vector<MODULEENTRY32W> result;
  Handle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid));
  if (snapshot.value == INVALID_HANDLE_VALUE) return result;
  MODULEENTRY32W entry{sizeof(entry)};
  if (Module32FirstW(snapshot.value, &entry)) do { result.push_back(entry); } while (Module32NextW(snapshot.value, &entry));
  return result;
}

static std::vector<BYTE> UserSid(HANDLE process) {
  HANDLE raw{};
  if (!OpenProcessToken(process, TOKEN_QUERY, &raw)) return {};
  Handle token(raw);
  DWORD size{};
  GetTokenInformation(token.value, TokenUser, nullptr, 0, &size);
  std::vector<BYTE> info(size);
  if (!size || !GetTokenInformation(token.value, TokenUser, info.data(), size, &size)) return {};
  auto sid = reinterpret_cast<TOKEN_USER*>(info.data())->User.Sid;
  std::vector<BYTE> result(GetLengthSid(sid));
  if (!CopySid(static_cast<DWORD>(result.size()), result.data(), sid)) return {};
  return result;
}

static bool SameUserAndSession(HANDLE process, DWORD pid) {
  DWORD ours{}, theirs{};
  if (!ProcessIdToSessionId(GetCurrentProcessId(), &ours) || !ProcessIdToSessionId(pid, &theirs) || ours != theirs) return false;
  auto ownSid = UserSid(GetCurrentProcess()), targetSid = UserSid(process);
  return !ownSid.empty() && !targetSid.empty() && EqualSid(ownSid.data(), targetSid.data());
}

static DWORD RemoteCall(HANDLE process, uintptr_t address, void* argument, DWORD& returned) {
  Handle thread(CreateRemoteThread(process, nullptr, 0, reinterpret_cast<LPTHREAD_START_ROUTINE>(address), argument, 0, nullptr));
  if (!thread.value) return GetLastError();
  DWORD wait = WaitForSingleObject(thread.value, 15000);
  if (wait != WAIT_OBJECT_0) return wait == WAIT_TIMEOUT ? ERROR_TIMEOUT : GetLastError();
  return GetExitCodeThread(thread.value, &returned) ? NO_ERROR : GetLastError();
}

static uintptr_t RemoteLoadLibraryAddress(const std::vector<MODULEENTRY32W>& modules) {
  FARPROC load = GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "LoadLibraryW");
  HMODULE owner{};
  if (!load || !GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                                   reinterpret_cast<LPCWSTR>(load), &owner)) return 0;
  wchar_t path[32768]{};
  if (!GetModuleFileNameW(owner, path, static_cast<DWORD>(std::size(path)))) return 0;
  for (const auto& module : modules) {
    if (_wcsicmp(module.szExePath, path) == 0)
      return reinterpret_cast<uintptr_t>(module.modBaseAddr) + reinterpret_cast<uintptr_t>(load) - reinterpret_cast<uintptr_t>(owner);
  }
  return 0;
}

static DWORD ControlHost(DWORD pid, ULONG_PTR command, const std::wstring& hookPath, DWORD& state) {
  Handle process(OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ | PROCESS_VM_WRITE | PROCESS_VM_OPERATION |
                              PROCESS_CREATE_THREAD | SYNCHRONIZE, FALSE, pid));
  if (!process.value) return GetLastError();
  wchar_t path[32768]{}; DWORD size = static_cast<DWORD>(std::size(path));
  if (!QueryFullProcessImageNameW(process.value, 0, path, &size) || !IsWindowsInputHostPath(path) ||
      !SameUserAndSession(process.value, pid)) return ERROR_ACCESS_DENIED;
  auto modules = Modules(pid);
  uintptr_t hookBase{};
  bool supported = false;
  for (const auto& module : modules) {
    if (_wcsicmp(module.szModule, L"TextInput.dll") == 0) supported = true;
    if (_wcsicmp(module.szModule, kHookName) == 0) {
      if (_wcsicmp(module.szExePath, hookPath.c_str()) != 0) return ERROR_ALREADY_EXISTS;
      hookBase = reinterpret_cast<uintptr_t>(module.modBaseAddr);
    }
  }
  // The hook resolves compatible code at runtime; no Windows version is checked.
  if (!supported) return ERROR_NOT_SUPPORTED;
  if (!hookBase) {
    if (command != 0) { state = 0; return NO_ERROR; }
    const uintptr_t loader = RemoteLoadLibraryAddress(modules);
    if (!loader) return ERROR_PROC_NOT_FOUND;
    const SIZE_T bytes = (hookPath.size() + 1) * sizeof(wchar_t);
    void* remotePath = VirtualAllocEx(process.value, nullptr, bytes, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (!remotePath) return GetLastError();
    SIZE_T written{};
    DWORD result = NO_ERROR, loaded{};
    if (!WriteProcessMemory(process.value, remotePath, hookPath.c_str(), bytes, &written)) result = GetLastError();
    else if (written != bytes) result = ERROR_PARTIAL_COPY;
    else result = RemoteCall(process.value, loader, remotePath, loaded);
    // A timed-out loader might still read its argument; retain that allocation until host exit.
    if (result != ERROR_TIMEOUT) VirtualFreeEx(process.value, remotePath, 0, MEM_RELEASE);
    if (result) return result;
    modules = Modules(pid);
    for (const auto& module : modules)
      if (_wcsicmp(module.szExePath, hookPath.c_str()) == 0) hookBase = reinterpret_cast<uintptr_t>(module.modBaseAddr);
    if (!hookBase) return ERROR_DLL_INIT_FAILED;
  }
  HMODULE local = LoadLibraryExW(hookPath.c_str(), nullptr, DONT_RESOLVE_DLL_REFERENCES);
  if (!local) return GetLastError();
  FARPROC control = GetProcAddress(local, "TypeDuckKeyboardCompatControl");
  uintptr_t offset = control ? reinterpret_cast<uintptr_t>(control) - reinterpret_cast<uintptr_t>(local) : 0;
  FreeLibrary(local);
  if (!offset) return ERROR_PROC_NOT_FOUND;
  DWORD returned{};
  DWORD result = RemoteCall(process.value, hookBase + offset, reinterpret_cast<void*>(command), returned);
  if (result) return result;
  if (command == 2) state = returned;
  else if (returned) return returned;
  else if (command == 0) {
    result = RemoteCall(process.value, hookBase + offset, reinterpret_cast<void*>(2), state);
    if (result) return result;
    if (!(state & 1)) return ERROR_DLL_INIT_FAILED;
  }
  return NO_ERROR;
}

static std::vector<DWORD> InputHosts() {
  std::vector<DWORD> result;
  Handle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0));
  PROCESSENTRY32W entry{sizeof(entry)};
  if (snapshot.value != INVALID_HANDLE_VALUE && Process32FirstW(snapshot.value, &entry)) do {
    if (_wcsicmp(entry.szExeFile, L"TextInputHost.exe") == 0) result.push_back(entry.th32ProcessID);
  } while (Process32NextW(snapshot.value, &entry));
  return result;
}

int wmain(int argc, wchar_t** argv) {
  if (argc != 2 || (wcscmp(argv[1], L"--apply") && wcscmp(argv[1], L"--status") && wcscmp(argv[1], L"--stop"))) {
    std::wcerr << L"用法 / Usage: TypeDuckKeyboardCompat --apply | --status | --stop\n";
    return ERROR_INVALID_PARAMETER;
  }
  wchar_t self[32768]{};
  if (!GetModuleFileNameW(nullptr, self, static_cast<DWORD>(std::size(self)))) return GetLastError();
  const auto hook = (std::filesystem::path(self).parent_path() / kHookName).wstring();
  const ULONG_PTR command = !wcscmp(argv[1], L"--status") ? 2 : (!wcscmp(argv[1], L"--stop") ? 1 : 0);
  const auto hosts = InputHosts();
  if (hosts.empty()) { std::cout << "{\"error\":1168,\"message\":\"Windows input host is not running\"}\n"; return ERROR_NOT_FOUND; }
  DWORD last = ERROR_NOT_FOUND;
  for (DWORD pid : hosts) {
    DWORD state{};
    last = ControlHost(pid, command, hook, state);
    std::cout << "{\"pid\":" << pid << ",\"error\":" << last << ",\"active\":" << ((state & 1) ? "true" : "false")
              << ",\"redirectedLookups\":" << (state >> 1) << "}\n";
    if (!last) return 0;
  }
  return static_cast<int>(last);
}
