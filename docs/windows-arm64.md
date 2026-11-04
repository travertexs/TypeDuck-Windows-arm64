# Windows 11 on Arm build

The `Windows ARM64` GitHub Actions workflow builds a combined ARM64X text-service
DLL from ARM64 and ARM64EC compiler outputs. Windows selects the appropriate
code when native ARM64 or emulated x64 applications load the shared COM server.
The existing Win32 DLL supports x86 applications. The installer chooses the
ARM64X DLL on Arm and the ordinary x64 DLL on Intel/AMD systems.

The launcher, settings and setup helper remain Win32; the Go runtime and bundled
Rime DLL remain x64 and run under Windows 11 emulation. This is an Arm-compatible
package, not a fully native port of every process. Windows 10 on Arm is outside
the supported scope of this build because the runtime requires x64 emulation.

Use the `windows-arm64` branch. Its push trigger builds all components; the
workflow also supports `workflow_dispatch` when present on the default branch.
Download `TypeDuck-Windows-ARM64-installer` from the successful workflow run.
It contains `typeduck-windows-arm64-setup.exe` and `SHA256SUMS.txt`.
These fork builds are unsigned and are not an official TypeDuck release.

The workflow pins the backend and schema commits. C++ dependencies use the
upstream submodule pins and versioned downloads. Build logs retain the resolved
dependency revisions. No release is published automatically by this workflow.

Validation includes the existing C++ tests, backend Go tests, native ARM64 C++
tests, silent installation and same-version upgrade on a Windows ARM runner,
COM activation from ARM64, x64 and x86 processes, and uninstallation. A green
build does not cover interactive candidate selection, every host application,
locked-DLL reboot replacement, or desktop login/logout behavior. Those need
an interactive device test before treating this as a production release.

Implementation references:

- https://learn.microsoft.com/windows/arm/arm64x-pe
- https://learn.microsoft.com/windows/arm/arm64x-build
