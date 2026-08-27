[繁體中文](README.zh-TW.md)

# WindowsKVM

WindowsKVM is the Windows companion for MacKVM. The current Windows W3
feature is a console receiver that can pair with MacKVM, authenticate a
secure Connect session, and receive keyboard/mouse control over that
encrypted session.

## Current feature set — 1.02.02 (build 82)

W3 includes:

- signed pairing compatible with MacKVM 1.00.00 and later;
- authenticated secure Connect compatible with MacKVM 1.100.00/build 75 and
  later, including the signed `disconnectSignalVersion` capability and
  encrypted disconnect acknowledgement;
- DPAPI-protected Windows identity storage;
- atomic, key-pinned trusted-peer storage at
  `%LOCALAPPDATA%\MacKVM\trusted-peers.json`;
- dependency-free dual-stack mDNS advertising for `_mackvm._tcp` and
  `_mackvm-secure._tcp`;
- signed P-256 ephemeral key exchange, HKDF-SHA256 key derivation, and
  ChaCha20-Poly1305 key confirmation;
- bounded framing, replay protection, handshake timeouts, and connection
  admission limits; and
- strict lower-camel control-message and remote-input validation compatible
  with MacKVM protocol v2;
- Windows `SendInput` keyboard, modifier, Unicode fallback, mouse, button,
  media-key, and unit-aware pixel/line scroll injection (including pointer
  pressure and trackpad phase metadata);
- release-all cleanup on control end, input failure, disconnect, or process
  shutdown;
- a shared console consent prompt (or `--yes` for test runs); and
- `Ctrl+Alt+Shift+Esc` as the local emergency shortcut that returns control
  to Windows.

Authenticated input uses a rolling per-second packet/byte budget, so normal
high-polling mice and trackpads remain connected without allowing an unbounded
input flood. Windows cannot reproduce macOS momentum phases exactly through
`SendInput`, but it preserves the metadata on the wire and converts pixel
movement to high-resolution wheel units without the legacy 120x amplification.

Secure Connect deliberately fails closed when the Mac peer does not advertise
the signed disconnect capability. Pairing remains available, but an old Mac
build must be updated before it can establish an encrypted control session.

W3 is intentionally still a console receiver. WinUI/tray UI, Windows Raw
Input capture, and a polished firewall setup wizard remain later work. The
Windows side never accepts unauthenticated input: a paired, authenticated
Mac session must request control and pass the local consent policy first.

## Build and run

Use the [Windows build guide](../WINDOWS_BUILD.md) for SDK installation,
architecture-specific publishing, and troubleshooting. The supported native
targets are Windows x64 (`win-x64`, also called `x86_64`) and Windows ARM64
(`win-arm64`); 32-bit x86 is not supported.

```powershell
.\scripts\build-windows.ps1 -Architecture x64
.\scripts\build-windows.ps1 -Architecture arm64
.\dist\windows\x64\WindowsKVM.exe --version
.\dist\windows\x64\WindowsKVM.exe --pairing-listen --name "Windows x64"
```

Use the ARM64 executable on Windows ARM. Allow the normal Windows Defender
Firewall prompt for the trusted Private network only; WindowsKVM does not add
a broad or silent firewall rule.

## Pair and connect

1. Start `WindowsKVM.exe --pairing-listen` on Windows.
2. Start Pair on the paired Mac and compare the six-digit code.
3. Type `y` at the Windows `Accept pairing?` prompt after the codes match.
4. If the Windows peer was paired by an older W1 build, pair it once again so
   W2/W3 creates `%LOCALAPPDATA%\MacKVM\trusted-peers.json`.
5. Press **Connect** for the paired Windows peer on MacKVM.
6. From MacKVM choose **Request keyboard and mouse control**. Compare the
   Windows console prompt and type `y` (or start WindowsKVM with `--yes` for a
   controlled test run).
7. To return control locally, press `Ctrl+Alt+Shift+Esc` on Windows, or end
   control from MacKVM. Any held key/button is released during either path.

Successful W3 authentication and control prints these lines on Windows:

```text
Incoming secure-session connection
Secure handshake response sent
Secure session authenticated with ...
Windows control granted for ...
```

If the peer public key changes, Windows rejects the connection instead of
silently replacing the pinned key. If the identity file cannot be decrypted
or validated, the receiver fails closed; follow the reset procedure in the
[Windows build guide](../WINDOWS_BUILD.md).

## Compatibility

Signed pairing works on Windows 10 build 19041 or later. Secure Connect
requires Windows build 10.0.20142 or later because that is the minimum Windows
build providing the .NET ChaCha20-Poly1305 primitive used by W3. On an older
Windows build, pairing remains available and the executable reports that
secure Connect is disabled.

Run the protocol self-test on a Windows development host with:

```powershell
.\scripts\test-windows.ps1
```

The macOS repository CI also runs this self-test when a .NET 8 SDK is present.
