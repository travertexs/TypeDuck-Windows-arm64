# Built-in Small keyboard compatibility prototype

Windows 11 ARM64 build 29698.1000 selects a restricted touch-keyboard definition
for the TypeDuck zh-TW profile. A live trace identified the exact TypeDuck CLSID
and profile GUID, then enumerated wide, split and handwriting modes without
narrow. Redirecting that one lookup to the existing US QWERTY definition made
Windows' built-in Small layout appear. The local interactive test confirmed
TypeDuck still offered and committed 你 after touch-keyboard input `nei`, with
the original TypeDuck profile active under LANGID 0x0404.

This prototype implements the demonstrated mapping in a separate native ARM64
helper and hook DLL. It is not yet part of the installer. End-to-end validation
of this compiled helper, startup integration and keyboard occlusion remains
required before release.

## Scope

- Only the TypeDuck CLSID/profile pair under 0404 or 0C04 is redirected.
- The installed IME registration and Windows language selection stay intact.
- The target must be the current user's Windows TextInputHost in the same session.
- There is no Windows version or binary hash restriction. An ARM64 instruction
  scan finds the keyboard-selection function in the loaded Windows module and
  decodes its profile field and COM method offsets. Relocation and those offset
  changes are covered by native tests. Missing or ambiguous code matches report
  an error instead of patching an unrelated function.
- The hook uses the keyboard set's existing COM getter for KLID 0409. The returned
  keyboard reference follows the original function's ownership contract.
- Microsoft Detours is pinned to v4.0.1 commit
  `e4bfd6b03e50de46b47abfbd1e46b384f0c5f833` and built statically from source.
- No Windows files or security settings are changed. The module remains loaded
  after removal so existing stack frames can return safely.
- No entered text, candidates or clipboard content is collected. Status contains
  only process ID, error code, activation state and a lookup counter.

The internal Windows ABI is undocumented. The runtime scan tolerates address and
field changes; a compiler rewrite can require an updated instruction recognizer.
Compatibility across every Windows update has not been established. Windows
process protections may reject loading or patching; the
helper reports the error and does not weaken those protections.

## Build and test

Use the fork's `Build compact keyboard compatibility prototype` GitHub Actions
workflow. It cross-compiles ARM64 on windows-2022 and runs the native policy and
Detours attach/detach tests on windows-11-arm. CI cannot establish the visible
Small layout result on a user's desktop.

After obtaining a verified workflow artifact, the developer diagnostic commands
are `TypeDuckKeyboardCompat.exe --apply`, `--status`, and `--stop`. Removal restores
the original code through a Detours transaction. A keyboard definition already
cached by Windows can remain until Windows next resolves that profile.
