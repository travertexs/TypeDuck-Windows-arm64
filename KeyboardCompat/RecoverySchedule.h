#pragma once
#include <windows.h>
#include <algorithm>
#include <cstdint>

namespace typeduck::compat {
// One schedule per process lifetime; callers discard it when that host exits.
struct RecoverySchedule {
  uint64_t nextCheck = 0;
  uint32_t retryDelay = 2000;
  bool timedOut = false;

  bool Due(uint64_t now) const { return !timedOut && now >= nextCheck; }

  void Complete(uint64_t now, DWORD error) {
    // A timed-out remote thread may still be running. Do not queue more work
    // in that process; a replacement Windows input host gets a fresh schedule.
    timedOut = error == ERROR_TIMEOUT;
    nextCheck = now + (error ? retryDelay : 10000);
    retryDelay = error ? std::min<uint32_t>(retryDelay * 2, 60000) : 2000;
  }
};
}
