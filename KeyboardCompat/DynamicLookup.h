#pragma once
#include "InstructionShapes.h"
#include <span>
#include <optional>
#include <cstring>

namespace typeduck::compat {
struct LookupLocation {
  size_t rva{};
  size_t profileTipOffset{};
  size_t getByKlidSlot{};
  size_t clearOverrideSlot{};
};

inline std::uint32_t ShapeMask(std::uint32_t instruction) {
  if ((instruction & 0xFC000000u) == 0x94000000u) return 0xFC000000u; // BL
  if ((instruction & 0x9F000000u) == 0x90000000u) return 0x9F00001Fu; // ADRP
  // Profile field loads, COM method loads and the CFG import load.
  const auto load = instruction & 0xFFC003FFu;
  if (load == 0xF9400360u || load == 0xF9400361u || load == 0xB9400361u ||
      load == 0xF9400108u || load == 0xF9400210u) return 0xFFC003FFu;
  return 0xFFFFFFFFu;
}

template<size_t N> inline bool MatchesShape(std::span<const std::uint32_t> code,
                                           const std::array<std::uint32_t, N>& shape) {
  if (code.size() < N) return false;
  for (size_t i = 0; i < N; ++i) {
    const auto mask = ShapeMask(shape[i]);
    if ((code[i] & mask) != (shape[i] & mask)) return false;
  }
  return true;
}

inline size_t LoadOffset(std::uint32_t instruction) { return ((instruction >> 10) & 0xFFF) * 8; }

// All inputs are bounded image spans; no build numbers, hashes, fixed image RVAs,
// symbol downloads or registry overrides take part in target selection.
inline std::optional<LookupLocation> FindLookup(std::span<const std::uint32_t> image,
                                               std::span<const std::pair<size_t, size_t>> executableRanges) {
  auto isCode = [&](size_t rva, size_t bytes) {
    if (rva % 4 || bytes > image.size_bytes() || rva > image.size_bytes() - bytes) return false;
    for (auto [start, end] : executableRanges)
      if (rva >= start && rva <= end && bytes <= end - rva) return true;
    return false;
  };
  std::optional<LookupLocation> found;
  for (auto [start, end] : executableRanges) {
    if (start % 4 || end > image.size_bytes() || start > end) return {};
    for (size_t rva = start; rva + sizeof(kLookupShape) <= end; rva += 4) {
      auto code = image.subspan(rva / 4);
      if (code[0] != kLookupShape[0] || !MatchesShape(code, kLookupShape)) continue;
      const size_t tip = LoadOffset(code[0x9C / 4]);
      if (tip < 8 || tip > 0x400 || tip != LoadOffset(code[0xAC / 4])) continue;
      const auto branch = code[0xF0 / 4];
      const auto displacement = static_cast<std::int32_t>((branch & 0x03FFFFFFu) << 6) >> 4;
      const auto target = static_cast<std::int64_t>(rva + 0xF0) + displacement;
      if (target < 0 || !isCode(static_cast<size_t>(target), sizeof(kGetterShape))) continue;
      const auto getter = image.subspan(static_cast<size_t>(target) / 4);
      if (!MatchesShape(getter, kGetterShape)) continue;
      const size_t getSlot = LoadOffset(getter[0x28 / 4]) / sizeof(void*);
      const size_t clearSlot = LoadOffset(code[0x170 / 4]) / sizeof(void*);
      if (getSlot < 6 || getSlot > 64 || clearSlot < 6 || clearSlot > 64) continue;
      // More than one structurally matching implementation is ambiguous.
      if (found) return {};
      found = LookupLocation{rva, tip, getSlot, clearSlot};
    }
  }
  return found;
}

inline std::optional<LookupLocation> LocateInModule(HMODULE module) {
  if (!module) return {};
  const auto base = reinterpret_cast<const BYTE*>(module);
  const auto dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
  if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew < sizeof(*dos) || dos->e_lfanew > 0x100000) return {};
  const auto nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
  if (nt->Signature != IMAGE_NT_SIGNATURE || nt->FileHeader.Machine != IMAGE_FILE_MACHINE_ARM64 ||
      nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC) return {};
  const size_t size = nt->OptionalHeader.SizeOfImage;
  const auto sections = IMAGE_FIRST_SECTION(nt);
  std::vector<std::pair<size_t, size_t>> ranges;
  for (WORD i = 0; i < nt->FileHeader.NumberOfSections; ++i) {
    if (!(sections[i].Characteristics & IMAGE_SCN_MEM_EXECUTE)) continue;
    const size_t start = sections[i].VirtualAddress, bytes = sections[i].Misc.VirtualSize;
    if (start > size || bytes > size - start) return {};
    ranges.emplace_back(start, start + bytes);
  }
  return FindLookup({reinterpret_cast<const std::uint32_t*>(base), size / 4}, ranges);
}
}  // namespace typeduck::compat
