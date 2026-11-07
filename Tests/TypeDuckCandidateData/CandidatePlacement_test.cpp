#include <windows.h>
#include <iostream>
#include "MoqiTextService/CandidatePlacement.h"

int main() {
  using namespace Moqi::CandidatePlacement;
  int failures = 0;
  auto check = [&](bool okay, const char* name) { std::cout << (okay ? "PASS " : "FAIL ") << name << '\n'; failures += !okay; };
  const RECT work{0, 0, 1920, 1080};
  const SIZE size{460, 320};
  const RECT anchor{900, 500, 902, 530};
  auto p = Place(anchor, size, work, {});
  check(p.x == 900 && p.y == 530, "Hidden keyboard preserves caret position");
  const RECT floating{850, 450, 1500, 1000};
  p = Place(anchor, size, work, floating);
  RECT box{p.x, p.y, p.x + size.cx, p.y + size.cy};
  check(!Overlap(box, floating) && !Overlap(box, anchor), "Floating keyboard and active text avoided");
  const RECT docked{0, 720, 1920, 1080};
  p = Place({900, 700, 902, 730}, size, work, docked);
  box = {p.x, p.y, p.x + size.cx, p.y + size.cy};
  check(!Overlap(box, docked) && box.top >= work.top, "Docked keyboard places candidates above");
  const RECT otherMonitor{-1920, -200, 0, 880}, otherKeyboard{-1600, 100, -900, 800};
  p = Place({-1500, 250, -1498, 280}, size, otherMonitor, otherKeyboard);
  box = {p.x, p.y, p.x + size.cx, p.y + size.cy};
  check(!Overlap(box, otherKeyboard) && box.left >= otherMonitor.left && box.right <= otherMonitor.right && box.top >= otherMonitor.top && box.bottom <= otherMonitor.bottom,
        "Negative monitor coordinates remain within work area");
  p = Place(anchor, size, work, {-1900, 0, -900, 900});
  check(p.x == 900 && p.y == 530, "Keyboard on another monitor does not move candidates");
  p = Place({0, 0, 1, 1}, {2400, 1400}, work, work);
  check(p.x == 0 && p.y == 0, "Oversized popup has a stable bounded origin");
  p = Place(anchor, size, work, {});
  check(p.x == 900 && p.y == 530, "Closing or moving keyboard restores caret anchor");
  return failures ? 1 : 0;
}
