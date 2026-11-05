# Touch keyboard and Windows language registration

The installer has a **Windows language** page on installation and update:

- Chinese (Hong Kong), `zh-HK`, LANGID `0x0c04` (the default for new installations).
- Chinese (Taiwan), `zh-TW`, LANGID `0x0404`.

Both choices use Cantonese Jyutping, the same backend profile GUID, settings and
user dictionary. They change the language used to register TypeDuck with Windows.
Updates preselect the existing choice. Selecting the other language registers
and enables the new profile before removing the old TypeDuck language profile.
Other IMEs and Windows language preferences are not removed.

For unattended installation, use `/IMELOCALE=zh-TW` or `/IMELOCALE=zh-HK` along
with the usual Inno Setup switches. Omitting the option preserves the saved
choice; an unsupported value stops setup before installation. The helper accepts
`--locale zh-TW` or `--locale zh-HK` for installation and re-registration.

The helper passes the selected locale to each registration process and saves
`HKLM\Software\TypeDuckIME\RegistrationLocale` in both registry views only after
both architectures register successfully. If registration fails, it attempts to
restore the previous locale and reports failure. Locked DLL updates retain the
active locale, save `PendingRegistrationLocale`, and schedule re-registration
with the explicit new locale after restart. Run setup again to retry a failure.

## Touch keyboard integration

TypeDuck exposes `ITfFunctionProvider` and
`ITfFnGetPreferredTouchKeyboardLayout`, advises the provider through
`ITfSourceSingle` on activation, and removes it on deactivation. It requests
`TKBLT_OPTIMIZED` with the Latin QWERTY Chinese layout ID `0x0804`. This only
requests a keyboard layout; it does not install a Pinyin engine or a zh-CN
language profile. The documented optimized Traditional Chinese layout is
Bopomofo, which is unsuitable for Jyutping input.

**Compatibility limit:** Microsoft documents `0x0804` for Simplified Chinese,
not for zh-HK/zh-TW. Windows may ignore this preference for these profiles.
The Windows **Small**, **Default** and **Split** keyboard modes are controlled by
Windows; this interface cannot guarantee that Small is offered. Do not label a
successful build or interface probe as proof that the compact keyboard works.

Unicode `VK_PACKET` input is decoded using the documented zero scan code. ASCII
letter/digit packets retain the corresponding physical-key meaning for the
backend. Private-use paging packets U+F003/U+F004 are consumed on both key edges;
only key-down changes a candidate page. They never become application text.
The open/close and native conversion-mode compartments are synchronized so that
the touch keyboard's Chinese/English mode button tracks TypeDuck's mode.

## Validation

The ARM workflow tests COM activation, function discovery through the thread
manager, COM identity, pointer checks, deactivation/reactivation, actual TSF
language profile registration and enablement in native ARM64, emulated x64 and
x86 processes. Installer checks cover locale defaults, same-locale updates and
HK to TW to HK migration. Engine checks use the packaged runtime in both locales.
`Windows-ARM64-validation` contains the resulting logs.

The installer page is rendered on the runner, including fresh-install Hong Kong
and saved Taiwan selections. Its owner-drawn radio items may not expose UI
Automation selection patterns, so the saved screenshots must also be inspected.
The opt-in `TypeDuckLoadProbe.exe zh-TW --touch-packets` test sends synthetic
Unicode input only to its own foreground window. If the runner cannot activate
that window, it records `SKIP SendInput` and continues the non-interactive TSF
checks. A skipped input test is not evidence that touch typing or Small works.

Interactive acceptance still requires opening a text field, selecting TypeDuck,
opening the Windows touch keyboard and inspecting its layout menu separately
under zh-HK and zh-TW. Verify Latin keys, tone digits, candidate selection and
paging, and the Chinese/English toggle. The locked-DLL test checks staging,
restart status, the saved pending locale and the re-registration callback. It
uses the same DLL build on each side and invokes the callback after releasing
the lock; it does not reboot the hosted runner or prove boot-time file replacement.

References:

- [Microsoft IME requirements](https://learn.microsoft.com/en-us/windows/apps/develop/input/input-method-editor-requirements#ime-and-touch-keyboard)
- [Touch keyboard layout identifiers and limitations](https://learn.microsoft.com/en-us/windows/win32/api/ctffunc/nf-ctffunc-itffngetpreferredtouchkeyboardlayout-getlayout)
- [Reported Traditional Chinese layout query issue](https://github.com/microsoft/Windows-classic-samples/issues/358)
