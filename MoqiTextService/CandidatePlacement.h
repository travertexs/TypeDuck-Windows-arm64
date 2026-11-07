#pragma once
#include <windows.h>
#include <algorithm>
#include <array>
#include <cstdint>
#include <limits>
#include <tuple>

namespace Moqi::CandidatePlacement {
inline std::int64_t Overlap(const RECT& a, const RECT& b) {
  return static_cast<std::int64_t>((std::max)(0L, (std::min)(a.right, b.right) - (std::max)(a.left, b.left))) *
      (std::max)(0L, (std::min)(a.bottom, b.bottom) - (std::max)(a.top, b.top));
}

// Keep the caret's usual below/above placement when it is clear. If obstructed,
// evaluate all four sides of the keyboard, including negative monitor origins.
inline POINT Place(const RECT& anchor, SIZE size, const RECT& work, const RECT& keyboard) {
  size.cx = (std::max)(1L, size.cx); size.cy = (std::max)(1L, size.cy);
  const auto bound = [&](POINT point) {
    point.x = std::clamp(point.x, work.left, (std::max)(work.left, work.right - size.cx));
    point.y = std::clamp(point.y, work.top, (std::max)(work.top, work.bottom - size.cy));
    return point;
  };
  POINT preferred{anchor.left, anchor.bottom};
  if (preferred.y + size.cy > work.bottom) preferred.y = anchor.top - size.cy;
  preferred = bound(preferred);
  const RECT normal{preferred.x, preferred.y, preferred.x + size.cx, preferred.y + size.cy};
  if (!Overlap(normal, keyboard)) return preferred;
  const LONG gap = 8;
  const std::array<LONG, 5> xs{preferred.x, keyboard.left - size.cx - gap, keyboard.right + gap, work.left, work.right - size.cx};
  const std::array<LONG, 6> ys{preferred.y, keyboard.top - size.cy - gap, keyboard.bottom + gap, anchor.top - size.cy, work.top, work.bottom - size.cy};
  auto bestScore = std::make_tuple((std::numeric_limits<std::int64_t>::max)(), (std::numeric_limits<std::int64_t>::max)(), (std::numeric_limits<std::int64_t>::max)());
  POINT best = preferred;
  for (LONG x : xs) for (LONG y : ys) {
    const POINT pos = bound({x, y});
    const RECT box{pos.x, pos.y, pos.x + size.cx, pos.y + size.cy};
    const std::int64_t dx = static_cast<std::int64_t>(pos.x) - preferred.x;
    const std::int64_t dy = static_cast<std::int64_t>(pos.y) - preferred.y;
    const auto score = std::make_tuple(Overlap(box, keyboard), Overlap(box, anchor), dx * dx + dy * dy);
    if (score < bestScore) { bestScore = score; best = pos; }
  }
  return best;
}

class PhysicalCoordinates {
  using SetContext = DPI_AWARENESS_CONTEXT(WINAPI*)(DPI_AWARENESS_CONTEXT);
  SetContext set_{};
  DPI_AWARENESS_CONTEXT previous_{};
public:
  PhysicalCoordinates() {
    set_ = reinterpret_cast<SetContext>(GetProcAddress(GetModuleHandleW(L"user32.dll"), "SetThreadDpiAwarenessContext"));
    if (set_) previous_ = set_(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  }
  ~PhysicalCoordinates() { if (set_ && previous_) set_(previous_); }
};
}  // namespace Moqi::CandidatePlacement
