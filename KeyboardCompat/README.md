# Built-in Small keyboard compatibility

Windows 11 ARM64 build 29698.1000 selects a restricted touch-keyboard definition
for the TypeDuck zh-TW profile. A live trace identified the exact TypeDuck CLSID
and profile GUID, then enumerated wide, split and handwriting modes without
narrow. Redirecting that one lookup to the existing US QWERTY definition made
Windows' built-in Small layout appear. The local interactive test confirmed
TypeDuck still offered and committed 你 after touch-keyboard input `nei`, with
the original TypeDuck profile active under LANGID 0x0404.

This integration implements the demonstrated mapping in a separate native ARM64
helper and hook DLL. The compiled GitHub Actions artifact was also verified on
the user's computer: Small was selectable, touch typing `nei` offered 你, and a
fresh diagnostic editor continued working after English/TypeDuck switching.
An older editor used for experimental process-local registration lost typing;
that result is kept separate from the clean-profile acceptance test.

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
- Microsoft Detours is pinned to commit
  `1dbd4ea281d73d478aa8d09a8b83fbd265f715f7` (including the ARM64 fixes)
  and built statically from source.
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
are `TypeDuckKeyboardCompat.exe --apply`, `--status`, `--watch`, and `--stop`. Removal restores
the original code through a Detours transaction. A keyboard definition already
cached by Windows can remain until Windows next resolves that profile.

## Installation and lifecycle

The ARM installer includes a bilingual Small-keyboard task. It preserves task
selection on updates and registers `--watch` in the installing user's Run key.
The watcher handles a newly started Windows input host and exits on `--stop`.
Updates and uninstall stop the watcher and detach the mapping. Updates request
a restart because Windows can retain the detached DLL until its input host exits.
Inno Setup replaces/deletes locked helper files at restart. Windows files are
never replaced. Deselecting the task during an update removes startup activation.

Candidate placement uses `IFrameworkInputPane::Location`, verified locally to
return the Small keyboard's screen rectangle. Candidates avoid that rectangle
and the input anchor when space permits, and check for keyboard movement every
250 ms while visible. This does not resize or scroll another application's editor.
The packaged installer passed native ARM install/update/uninstall validation.
On 7 November 2026, the installed build was tested on the user's desktop: Small
was visible, dragging it over the candidate list moved the list clear of the
keyboard, and clicking the relocated first candidate committed 你. See the
[build and interactive validation record](../docs/windows-small-keyboard-validation.md)
for the exact artifact, tested scope and remaining compatibility limits.
