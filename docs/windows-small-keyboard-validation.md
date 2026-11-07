# Windows Small keyboard: validated ARM installer

Validated on 7 November 2026. The GitHub Actions installer enables Windows'
built-in Small touch keyboard for TypeDuck on the tested Windows ARM64 host,
retains the selected Windows language, and moves TypeDuck's candidate popup away
from the floating keyboard when space permits.

## Download and provenance

- [Installer artifact](https://github.com/travertexs/TypeDuck-Windows-arm64/actions/runs/42377489822/artifacts/13577050391)
- [Successful complete workflow](https://github.com/travertexs/TypeDuck-Windows-arm64/actions/runs/42377489822)
- [ARM installer validation evidence](https://github.com/travertexs/TypeDuck-Windows-arm64/actions/runs/42377489822/artifacts/13576338390)
- Product source: `6f377d7ba2df4c5c63a564b8f0252787a75c3b91`.
- Filename: `typeduck-windows-arm64-setup.exe`.
- Installer SHA-256: `2e85fed7ba18fe4121a727457de483ea548274620b1e8275765b57e655ed850d`.

The artifact archive was verified against GitHub's API digest, and the extracted
installer matched its bundled `SHA256SUMS.txt`. All production binaries were
compiled through GitHub Actions. Subsequent documentation-only commits do not
change this installer.

## Installed behavior

The installer offers a bilingual Windows language page with Hong Kong (`zh-HK`)
and Taiwan (`zh-TW`). Fresh installation defaults to Hong Kong; updates remember
the saved choice and migrate this IME if the choice changes. The ARM installer
also offers **Support the Windows Small touch keyboard** and preserves that task
selection on update.

The compatibility helper runs per user at sign-in and watches for a new Windows
input host. It redirects only the exact TypeDuck CLSID/profile pair under 0404
or 0C04 to Windows' existing US QWERTY keyboard definition. TypeDuck's registration
and Cantonese engine are retained. No Windows system file is replaced by this
helper. It does not change Windows security settings or record entered text.

There is no Windows version or binary hash allowlist. The helper discovers and
validates the target instructions at runtime, including the profile field and
COM offsets. Unrecognized or ambiguous code is left alone. This depends on an
undocumented Windows implementation; a future compiler rewrite may require an
updated recognizer.

While candidates are visible, TypeDuck queries `IFrameworkInputPane::Location`
every 250 ms and places the popup outside the keyboard when possible. It accounts
for monitor work areas and negative monitor coordinates. This protects the
candidate/preedit popup; document scrolling and resizing remain the application's
responsibility.

## Desktop acceptance

Host: Windows 11 ARM64 build 29698.1000, TypeDuck registered as zh-TW.

| Check | Evidence/result |
| --- | --- |
| Built-in Small appears with the compiled helper, without debugger attachment | User confirmed and desktop observed |
| Touch typing `nei` offers 你 | User confirmed in a clean diagnostic editor |
| English to TypeDuck switching retains Cantonese candidates | User confirmed in the clean editor |
| Packaged installer installs and activates its own helper | Installed helper hash matched the Actions payload; status reported active in the new Windows input host |
| Updated TSF DLL is installed | Native and Win32 system DLL hashes matched their packaged payloads |
| zh-TW registration preserved | Native COM/profile probe passed; old zh-HK profile absent; both saved registry views zh-TW and pending locale cleared |
| Floating keyboard bounds available | `IFrameworkInputPane::Location` returned nonempty screen rectangles for Small |
| Candidate list follows a keyboard drag | User reported movement; before/after desktop views showed the `nei` list move to the right of Small, clear of the keyboard |
| Relocated candidate remains usable | Clicking the first relocated candidate committed 你 in the diagnostic editor |

An older diagnostic editor used for experimental process-local registration
produced Latin text after switching. It was closed before the clean-editor
acceptance test. That earlier failure is not used as evidence that all switching
paths are fixed, nor is its cause asserted as established.

Local setup requested a restart because an old TSF DLL was still loaded. Both new
system DLLs were already installed and hash-verified, so the normal re-registration
callback was run successfully and acceptance used a fresh editor. Other existing
applications can retain an older loaded DLL until restarted. A later Windows
restart completes pending old-file cleanup; no automatic reboot was performed.

## GitHub Actions validation

All seven jobs in the linked workflow succeeded:

- Win32, x64 and ARM64X frontend builds; applicable native unit suites.
- ARM64 compatibility helper build and native test job: profile isolation,
  relocated code/changed offsets, rejected ambiguous or malformed matches,
  Detours attach/detach and original-instruction restoration, watcher startup,
  single instance and clean shutdown.
- Installer packaging and native ARM installer smoke job.

Installer tests cover fresh HK/TW installations, same-locale updates, HK to TW to
HK migration, selected-profile enablement and old-profile removal in ARM64, x64
and x86 processes, user-file preservation, packaged engine typing, helper payload
and startup registration, deferred registration after a DLL lock, and uninstall
cleanup. Rendered installer screenshots were inspected for the fresh Hong Kong
and remembered Taiwan selections. Candidate-placement tests also passed natively
on the local ARM64 host: floating/docked/hidden keyboards, monitor boundaries,
oversized windows and restoration to the caret anchor.

CI's synthetic foreground input test reports `SKIP SendInput` where the runner
cannot activate its editor. The desktop checks above supply the Small/typing
evidence. CI does not claim to test the Windows Small UI or a complete OS reboot.
The full zh-HK Small desktop sequence and other Windows builds remain untested;
zh-HK registration and mapping identity are covered by automated checks.

## Update and removal

Updates and uninstall stop the watcher and detach its mapping. The hook DLL stays
loaded until the Windows input host exits so existing calls can return safely.
Updates with a previously installed helper request restart. Deselecting the Small
task on update removes its sign-in startup entry. Uninstall removes the helper
and startup registration, scheduling locked helper files for deletion if needed.

See [touch keyboard and language registration](touch-keyboard-and-registration.md)
and [compatibility implementation](../KeyboardCompat/README.md) for details.
