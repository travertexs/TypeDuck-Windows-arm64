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

Use the `windows-arm64` branch. Changes to product or build files trigger the
full build; documentation and validation-only changes do not. The workflow
also supports `workflow_dispatch` (select `windows-arm64` as the ref).
Download `TypeDuck-Windows-ARM64-installer` from the successful workflow run.
It contains `typeduck-windows-arm64-setup.exe` and `SHA256SUMS.txt`.
These fork builds are unsigned and are not an official TypeDuck release.

`Validate Windows ARM64 installer` can retest an existing build without compiling
again. Supply its numeric Actions run ID and full source commit SHA. The workflow
checks that provenance before downloading its installer and frontend test tools.

The workflow pins the backend and schema commits. C++ dependencies use the
upstream submodule pins and versioned downloads. Build logs retain the resolved
dependency revisions. No release is published automatically by this workflow.

Validation includes the existing C++ tests, backend protocol tests, native ARM64 C++
tests, silent installation and same-version upgrade on a Windows ARM runner,
COM activation from ARM64, x64 and x86 processes, synthetic Jyutping composition,
candidates and commit output from the installed runtime, and uninstallation. A green
build does not cover interactive candidate selection, every host application,
locked-DLL reboot replacement, or desktop login/logout behavior. Those need
an interactive device test before treating this as a production release.

The unmodified pinned backend fails its full `go test ./...` baseline. Failures
include removed legacy features, top-row/numpad fallback expectations, and tests
depending on a developer's local installation. The workflow retains this full
suite as a non-blocking diagnostic artifact and reports its failure in the job
summary. It does not claim the backend suite is green. Backend protocol tests
and the installed-runtime typing probe remain blocking checks. This port does
not repair those pre-existing backend discrepancies.

Other existing source guards are also inconsistent with the pinned upstream
snapshot: the candidate-data guard expects parser-limit text absent from the
unchanged parser; the pruning guard expects the removed `appearance_themes.json`;
and the release guard expects a schema-download layout absent from the unchanged
release/nightly workflows. The protocol and settings-persistence source guards
pass. These source-guard results are separate from the compiled C++ tests and
the installed-runtime checks above.

Implementation references:

- https://learn.microsoft.com/windows/arm/arm64x-pe
- https://learn.microsoft.com/windows/arm/arm64x-build
