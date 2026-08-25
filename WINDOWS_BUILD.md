[繁體中文](WINDOWS_BUILD.zh-TW.md)

# Windows build guide

This guide builds the Windows branch of MacKVM. The current W1 deliverable is
a C#/.NET 8 protocol library, signed pairing state machine, a console pairing
receiver, and a small mDNS advertiser. It can establish a signed trust
relationship with MacKVM 1.00.00. It is not yet the full Windows KVM: WinUI 3,
Raw Input, SendInput, secure control sessions, hotkeys, and tray integration
remain later W2 work.

## Requirements

- Windows 10 version 2004 (build 19041) or later.
- .NET 8 SDK. Confirm it with `dotnet --info`; a runtime-only installation is
  not sufficient.
- PowerShell 5.1 or PowerShell 7.
- Git, if cloning the repository on the Windows build host.

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

## Run the pairing receiver

After publishing on Windows, start the W1 receiver:

```powershell
.\dist\windows\arm64\WindowsKVM.exe --pairing-listen --name "Windows ARM64"
```

Use `--yes` only for a controlled test run; it automatically accepts the
six-digit verification code. The normal flow prints the code and asks for a
local `y` after you compare it with the code shown by the initiating Mac:

```powershell
.\dist\windows\x64\WindowsKVM.exe --pairing-listen --name "Windows x64"
```

The receiver advertises `_mackvm._tcp` on the local network and listens on a
random TCP port by default. Windows Defender Firewall may show its standard
Private-network prompt; allow the executable on the trusted local network
only. The application does not add a broad or silent firewall rule.

The receiver uses a dual-mode TCP listener when the host can bind IPv6, and the
mDNS advertiser publishes only address records that match the active listener:
A records for IPv4 and AAAA records for IPv6. IPv6-only local networks are
supported when Windows has an IPv6 interface and multicast access; if the
dual-stack bind falls back to IPv4, IPv4-only discovery is advertised.

The identity private key is stored under `%LOCALAPPDATA%\MacKVM` protected by
Windows DPAPI. Do not copy `identity.json` to another computer. Pairing
completion is persisted by the macOS peer, while the Windows W1 console keeps
the identity ready for the next secure-session step.

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

The script already rejects an unexpected PE machine type. W1's receiver can
complete signed pairing, but it does not yet provide Windows input control.

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

The Windows executable is not included in macOS DMG packaging. W1 proves the
cross-platform signed pairing flow only; keyboard/mouse hand-off and the
encrypted control session will be implemented in W2 before a Windows release
is declared usable.
