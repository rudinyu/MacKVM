[繁體中文](WINDOWS_BUILD.zh-TW.md)

# Windows build guide

This guide builds the Windows branch of MacKVM. The current deliverable is a
C#/.NET 8 protocol library, signed pairing state machine, native Win32 status
window and resident tray host, DPAPI-backed identity, dependency-free mDNS
advertisers, authenticated encrypted Connect, strict control/input validation,
Windows SendInput injection, release-all teardown, and an emergency
local-return hotkey. Raw Input capture and the final firewall UX remain later
Windows work.

## Requirements

- Windows 10 version 2004 (build 19041) or later.
- .NET 8 SDK. Confirm it with `dotnet --info`; a runtime-only installation is
  not sufficient.
- PowerShell 5.1 or PowerShell 7.
- Git, if cloning the repository on the Windows build host.

The signed pairing receiver works on the Windows 10 baseline above. W3 secure
Connect additionally requires Windows build `10.0.20142` or later because .NET
8 uses the Windows CNG ChaCha20-Poly1305 implementation for the encrypted
session. On an older build the executable keeps pairing available and reports
that secure Connect is disabled.

This Windows beta is not compatible with the MacKVM 1.00.00 release. The Mac
peer must use a MacKVM build with the signed `disconnectSignalVersion`
capability (introduced in MacKVM 1.100.00/build 75) for pairing and secure
Connect. An older peer is rejected with an explicit upgrade-required error
instead of silently downgrading to an unauthenticated EOF close.

The supported native publish targets are Windows x64 (`win-x64`, also called
`x86_64`) and Windows ARM64 (`win-arm64`). 32-bit `i686` is not supported.

## Get the source

Use the Windows development branch rather than the stable macOS branch:

```powershell
git clone https://github.com/rudinyu/MacKVM.git
Set-Location MacKVM
git switch feature/windows-w0-scaffold
```

If the branch has not been pushed yet, copy the working tree to the Windows
host or use the branch name that contains the Windows scaffold.

## Publish one architecture

Run the script from the repository root. It publishes a self-contained,
single-file executable and verifies the PE machine type before returning
success:

```powershell
.\scripts\build-windows.ps1 -Architecture x64
.\scripts\build-windows.ps1 -Architecture arm64
```

Use an explicit release configuration when desired:

```powershell
.\scripts\build-windows.ps1 -Architecture x64 -Configuration release
```

The output is kept under `dist\windows`:

```text
dist\windows\x64\WindowsKVM.exe
dist\windows\arm64\WindowsKVM.exe
```

Intermediate `bin`/`obj` state is written under the system temporary
directory, not into the repository. The publish script also isolates each
project in the reference graph so the `net8.0` protocol library cannot collide
with the `net8.0-windows` app restore state.

## Publish both architectures

```powershell
.\scripts\build-windows.ps1 -Architecture both
```

The script stops on the first failed publish. A successful run prints the
detected PE architecture (`x64` or `arm64`) for each executable.
The repository CI repeats this publish on a Windows runner, so a successful
local cross-build is not the only Windows build check.

## Run the pairing receiver

Confirm the executable before starting a test:

```powershell
.\WindowsKVM.exe --version
```

The current UI test build reports `WindowsKVM 1.02.08 (build 88)`.

After publishing on Windows, start the resident UI:

```powershell
.\dist\windows\arm64\WindowsKVM.exe
```

The UI adds a Windows notification-area icon, starts both listeners, and shows
native Yes/No dialogs for pairing and control consent. Closing the status
window hides it; choose **Quit WindowsKVM** in the window or tray menu to stop
all listeners. For a scripted console run, use `--pairing-listen`; `--yes` is
only for a controlled test because it automatically accepts pairing and
control:

The status window follows the macOS panel order and has two views. **Simple
mode** is selected automatically below 900×1120 screen pixels (or when the
window client area is compact); it keeps identity, readiness, pairing,
control-state, firewall, Refresh, and Quit actions visible. **Advanced mode**
shows the complete header, **Set up this PC**, **Physical input path**,
**Nearby Macs**, **Keyboard, mouse, and trackpad**, **Monitor input**, and
**Paired device information** sections. The header button switches between the
two modes, and Advanced remains scrollable on short displays. Pair and Connect
still start on the MacKVM peer, while Windows shows the corresponding consent
dialog and live status.

```powershell
.\dist\windows\x64\WindowsKVM.exe --pairing-listen --name "Windows x64"
```

The receiver advertises `_mackvm._tcp` for pairing and
`_mackvm-secure._tcp` for the later Connect on the local network. Both
listeners use random TCP ports by default. When the Mac connects for pairing,
the console mode prints the incoming peer, the verification code, and an
explicit `Accept pairing?` prompt. In UI mode the same decision appears in a
native Yes/No dialog. Compare the code with the initiating Mac, then type
`y` or `yes` in console mode, or choose **Yes** in the UI. Windows Defender Firewall may show its standard Private-network
prompt; allow the executable on the trusted local network only. The
application does not add a broad or silent firewall rule. The CLI also prints
each received pairing frame and detailed transport/protocol errors.

To inspect or remove the Windows-side trust pins from a console, use the full
peer ID printed by `--list-paired`:

```powershell
.\dist\windows\x64\WindowsKVM.exe --list-paired
.\dist\windows\x64\WindowsKVM.exe --forget <peer-id>
```

`--forget` is a one-shot durable trust-store operation; pair again from MacKVM
before pressing Connect. If another WindowsKVM receiver is already running,
restart it after the CLI command so it reloads the trust store, or use the UI
**Forget paired Mac** action to revoke that peer and close its active session.

After a successful pairing, Windows records the Mac's public identity in
`%LOCALAPPDATA%\MacKVM\trusted-peers.json`. The Mac can then select the paired
Windows device and press **Connect**. The Windows console should print
`Incoming secure-session connection`, `Secure handshake response sent`, and
`Secure session authenticated with ...`. A Windows W1 pairing made before W2
did not create this trust record; re-pair that Mac once with the W3 executable
before testing Connect. If the Mac was forgotten on macOS, or you want to
reset the Windows-side trust, choose **Forget paired Mac** while it is still
listed in the Windows UI, then start Pair again before pressing Connect. Forget
is a local revocation and intentionally removes the Windows-side pin. If the
Mac identity key was also reset, Windows shows a warning that pairing will
replace its old pin and updates it only after the verification code is
explicitly accepted. A changed key is never replaced by Secure Connect or by
an unapproved write.

After Connect, choose **Request keyboard and mouse control** on MacKVM. The
Windows console asks for a local `y`/`yes` decision (or accepts automatically
when `--yes` is used). Once granted, Windows prints `Windows control granted`
and injects the authenticated Mac input with `SendInput`. Press
`Ctrl+Alt+Shift+Esc` on Windows to release all held input and return control
locally; ending control from MacKVM has the same release-all behavior.

If the Mac reports `peer-upgrade-required` or Windows reports that the peer
does not support the authenticated disconnect signal, update both endpoints to
the current branch/build before testing Connect again. Pairing compatibility
alone is not enough for secure Connect.

The receiver uses a dual-mode TCP listener when the host can bind IPv6, and the
mDNS advertiser publishes only address records that match the active listener:
A records for IPv4 and AAAA records for IPv6. IPv6-only local networks are
supported when Windows has an IPv6 interface and multicast access; if the
dual-stack bind falls back to IPv4, IPv4-only discovery is advertised.

The identity private key is stored under `%LOCALAPPDATA%\MacKVM` protected by
Windows DPAPI. Do not copy `identity.json` to another computer. The public
peer trust list is separate and contains no private key. Pairing completion is
persisted by the macOS peer and the Windows W3 console records the approved
Mac identity for secure Connect admission.

If the saved identity cannot be decrypted or fails validation, the receiver
fails closed and does not generate a replacement identity. First forget the
old Windows peer on every Mac that trusted it, then remove the corrupt file
`%LOCALAPPDATA%\MacKVM\identity.json` deliberately and launch the receiver
again to create a new identity. This prevents an implicit key/UUID rotation
from silently stranding existing pairings.

The protocol self-test can be run on a Windows development host with:

```powershell
.\scripts\test-windows.ps1
```

On the M5 Pro, preview the command without executing it:

```sh
pwsh ./scripts/test-windows.ps1 -Plan
```

## Preview from the M5 Pro

The publish script intentionally runs on a Windows host. On macOS, use
`-Plan` to print the commands without invoking .NET or creating a Windows
executable:

```sh
pwsh ./scripts/build-windows.ps1 -Architecture both -Plan
```

The plan mode does not create `dist/windows`.

## Optional parameters

The script accepts a custom project and output directory for experiments:

```powershell
.\scripts\build-windows.ps1 `
  -Project WindowsKVM/src/WindowsKVM.App/WindowsKVM.App.csproj `
  -OutputDirectory dist/windows-local `
  -Architecture x64
```

Keep the project targeting `net8.0-windows10.0.19041.0` or a compatible
Windows target framework. The project must remain a Windows executable project
so the script can validate its published PE output.

## Verify the output

On Windows, inspect the file type with PowerShell or Visual Studio tooling:

```powershell
Get-Item .\dist\windows\x64\WindowsKVM.exe
Get-Item .\dist\windows\arm64\WindowsKVM.exe
```

The script already rejects an unexpected PE machine type. The UI and console
hosts complete signed pairing, the encrypted Connect handshake, authenticated
control-message validation, and Windows input control. A real Windows host is
still required to exercise the tray window, `SendInput`, and the global
release hotkey.

## Troubleshooting

- **`dotnet was not found`**: install the .NET 8 SDK, reopen PowerShell, and
  confirm that `dotnet --info` works.
- **The script says it must run on Windows**: use `-Plan` on macOS, or run the
  publish command on a Windows host/VM.
- **Execution policy blocks the script**: invoke it for the current process
  only with `powershell -ExecutionPolicy Bypass -File
  .\scripts\build-windows.ps1 -Architecture x64`.
- **Wrong architecture**: use `x64` for Windows x86_64 and `arm64` for Windows
  ARM64; do not pass `x86` or `i686`.

The Windows executable is not included in macOS DMG packaging. The Windows UI
and console hosts share the cross-platform signed pairing flow, authenticated
encrypted Connect, and keyboard/mouse hand-off. A Windows host is still needed
for final visual, notification-area, firewall, and input-injection acceptance.
