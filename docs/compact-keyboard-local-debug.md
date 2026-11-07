# Compact touch keyboard: local debugging findings

This is the diagnostic record for the earlier preference-only build. The
[7 November compatibility build](windows-small-keyboard-validation.md) subsequently
enabled Windows' built-in Small layout and passed desktop typing and candidate
movement checks on the same host.

On 5 November 2026, the installed TypeDuck build was investigated on a Windows
11 Arm device after the user reported that Small/compact remained unavailable.
**The compact-layout requirement is not satisfied by this build.**

## Environment and binary identity

- Windows build: 29698.1000.
- Registration: zh-TW, LANGID 0x0404, in both machine registry views.
- No pending locale change was present.
- TSF CLSID: `{7D92985A-BC53-47B5-A5CC-6E47F86B9D18}`.
- Profile GUID: `{C6E8F5DF-6504-44F9-B7CF-17A195373A83}`.
- Product source: `0ab6bcecf9f3bd1f9369821dcd1d02548860388c`.
- Installed native TSF DLL SHA-256:
  `62876DDE5AD6C4822AB3BD459824B3B1E6EF6FF9567B7214D60123A3EAE211AC`.
- Installed Win32 TSF DLL SHA-256:
  `9FC74E6E1AFDBD746A27A9D7EE079A28D925E97F3AA621424EE1CB1B4F250159`.

The installed native DLL matched the delivered ARM64X DLL. Notepad was observed
loading that DLL. The registered capability categories included immersive,
system-tray and input-mode-compartment support.

## Interactive result

The keyboard menu was observed offering **Default** and **Split** only with
TypeDuck selected. The user performed the English comparison and reported that
English offered **Small**, while TypeDuck did not. Thus Small was available on
the device, but was unavailable in the reproduced TypeDuck case.

## Native process trace

A disposable native ARM64 Windows Forms editor was used to avoid debugging
Notepad's unsaved documents. It queried its active TSF profile, provided a
process-only TypeDuck activation button, and exposed a separate explicit
interface-test button. It did not log entered text or alter IME registration.

The installed DLL's vtables identified the function addresses without a PDB:

| Method | RVA in the exact native DLL above |
| --- | --- |
| `ITfFunctionProvider::GetFunction` | `0x1A510` |
| `ITfFnGetPreferredTouchKeyboardLayout::GetLayout` | `0x1B95C0` |

Native CDB breakpoints logged only method entries, interface identifiers and
short call stacks, then immediately resumed. An explicit probe before and after
the interactive checks obtained the provider through
`ITfThreadMgr::GetFunctionProvider`, requested the preferred-layout interface,
and successfully received `TKBLT_OPTIMIZED` / `0x0804`.

The trace contained:

- Two explicit preferred-layout requests and two `GetLayout` calls, one for
  each positive-control probe. Both returned successfully.
- One Windows-originated function-provider request on TypeDuck reactivation,
  for `ITfFnShowHelp` (`{5AB1D30C-094D-4C29-8EA5-0BF59BE87BF3}`).
- No Windows-originated request for the preferred-layout interface and no
  Windows-originated `GetLayout` call during the recorded interaction in that
  process, including opening the touch keyboard and reactivating TypeDuck.

The active profile was observed as English and subsequently as TypeDuck zh-TW.
After the final positive control, the diagnostic restored its original
process-only profile selection and closed. The debugger exited successfully.
No installed DLL, global registration or Windows keyboard setting was changed.

## Interpretation and limits

The implemented interface is callable and discoverable in a real native ARM64
TSF host. Its return value is not being requested in the observed failing path.
Changing only that return value, or reinstalling the same package, is therefore
not an evidence-supported fix for this reproduction.

This trace covers one host process and one Windows build, not every process in
Windows. It does not identify every internal eligibility rule or eliminate
cross-process caching. It also does not establish behavior for zh-HK, other
Windows releases, or the unsigned build versus a signed build. The earlier
registration and architecture tests remain useful, but they cannot establish
Small-layout availability.

Microsoft documents `0x0804` for Simplified Chinese, whereas the optimized
Traditional Chinese layout is Bopomofo. The documented interface offers a
fixed list of language-specific layouts and no separate API to force the
Windows Small mode. The current cross-language preference remains a
compatibility experiment, not a verified compact-layout implementation.

A similar Traditional Chinese preferred-layout query failure was reproduced
by Microsoft support in 2024. The sample-repository issue was later closed with
a referral to Windows developer support, not with a code fix. That report is
supporting context rather than proof that all third-party IMEs are permanently
unable to use compact mode.

Further implementation must establish a supported way for the modern Windows
keyboard to accept TypeDuck's preference and pass an actual Small-menu and
touch-typing test. No such fix was established by this debugging session.
Providing TypeDuck's own compact keyboard would be a separate feature with its
own focus, accessibility and input-delivery requirements.

## References

- [Microsoft preferred touch-layout API](https://learn.microsoft.com/en-us/windows/win32/api/ctffunc/nf-ctffunc-itffngetpreferredtouchkeyboardlayout-getlayout)
- [Microsoft IME touch-keyboard requirements](https://learn.microsoft.com/en-us/windows/apps/develop/input/input-method-editor-requirements#ime-and-touch-keyboard)
- [Microsoft Q&A reproduction](https://learn.microsoft.com/en-us/answers/questions/1856921/cannot-change-windows-10-11-touch-keyboard-to-trad)
- [Sample issue and support referral](https://github.com/microsoft/Windows-classic-samples/issues/358)
