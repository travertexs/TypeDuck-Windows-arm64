# Validated touch-keyboard and language-registration build

Validated on 5 November 2026 using GitHub Actions under `travertexs`.

The installer adds a bilingual Windows language page with **Chinese (Hong Kong),
zh-HK** and **Chinese (Taiwan), zh-TW**. Fresh installations default to Hong Kong.
Updates remember the saved choice; selecting the other option migrates the
TypeDuck registration while retaining Cantonese typing and user data. Running
the installer again lets the user change this choice later.

Touch-keyboard function-provider integration, the optimized Latin QWERTY layout
preference, Unicode packet handling and Chinese/English mode synchronization are
implemented. **Windows' Small/compact keyboard availability has not been proven.**
Microsoft documents the requested layout ID `0x0804` for Simplified Chinese;
Windows may ignore it for zh-HK or zh-TW. This API cannot force Small mode.

## Artifact and provenance

- [Installer artifact](https://github.com/travertexs/TypeDuck-Windows-arm64/actions/runs/42073051574/artifacts/13437489271)
- [Build and package jobs](https://github.com/travertexs/TypeDuck-Windows-arm64/actions/runs/42073051574)
- [Successful final ARM validation](https://github.com/travertexs/TypeDuck-Windows-arm64/actions/runs/42078392372)
- [Validation evidence artifact](https://github.com/travertexs/TypeDuck-Windows-arm64/actions/runs/42078392372/artifacts/13439533447)
- Product build commit: `0ab6bcecf9f3bd1f9369821dcd1d02548860388c`.
- Validation commit: `cfffdbafc74158269d6eba1444f8e5226b2e5ab9`.

The full build's architecture and packaging jobs succeeded. Its original ARM
smoke job used an earlier test harness and failed. The separate successful
validation above uses corrected probes against the exact unchanged installer;
it records both commits and probe hashes. The entire original build run is not
being described as green.

Installer filename: `typeduck-windows-arm64-setup.exe`.

SHA-256:

```text
971a52a3b98c94f8793013f560ca9f44a619afaf9db259083973e9d198e8b066
```

## Verified behavior

| Check | Result |
| --- | --- |
| ARM64X, x64 and x86 compilation; x64/x86 CTest suites | Passed |
| Native ARM64 unit tests | 28 passed |
| Installer page, fresh Hong Kong selection and remembered Taiwan selection | Rendered screenshots inspected; passed |
| Fresh HK/TW installation, same-locale updates, HK to TW to HK migration | Passed |
| Selected TSF profile enabled and old profile absent, COM activation, function-provider discovery/lifecycle, mode synchronization | Passed in native ARM64, emulated x64 and x86 processes |
| Existing user-file preservation through updates | Passed using an unchanged file/hash sentinel |
| Packaged Cantonese engine in both locales | `nei` committed `你`; `housam` committed `好心` |
| Locked DLL update | Returned restart-required code 3010; retained active HK and saved pending TW with the scheduled task |
| Deferred re-registration callback | Activated TW, removed old HK registration, cleared pending state and removed the completed task |
| Uninstall and fresh TW reinstall | Passed; both COM registry views removed on uninstall |
| Unsupported locale rejection | Installer rejected zh-CN before installation; silent helper returned code 3 |

The first native process after deferred migration retained a stale TSF snapshot.
The test verified the exact registry state and retried in a fresh process, which
passed the full API assertions. The harness allows at most three attempts and
does not accept registry checks alone as an API pass. Applications already open
during a language change may need to be reopened to refresh their cached list.

## Validation limits

- The hosted runner could not foreground the synthetic touch-input window.
  The SendInput test explicitly recorded a skip. Actual touch-key delivery,
  candidate paging and Windows' Small keyboard menu require an interactive
  device test. Successful COM/layout queries do not prove those UI behaviors.
- The locked-DLL test released the locks and invoked the registration callback
  using the same DLL build. It did not reboot the runner, so boot-time file
  replacement and login behavior remain untested.
- This unsigned fork build targets Windows 11 on Arm. The text-service DLL is
  ARM64X; launcher/settings/helper remain x86 and the backend/Rime remain x64
  under Windows emulation.
- The pinned upstream backend still has existing failures in its full test
  suite. The workflow retains that diagnostic separately; required backend
  protocol checks and packaged typing checks passed.

Implementation details and Microsoft references are in
[touch-keyboard-and-registration.md](touch-keyboard-and-registration.md).
