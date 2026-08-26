[繁體中文](README.zh-TW.md)

# WindowsKVM

WindowsKVM is the Windows companion for MacKVM. The current Windows W2
feature is a console receiver that can pair with MacKVM and authenticate a
secure Connect session over the local network.

## Current feature set — 1.01.02 (build 79)

W2 includes:

- signed pairing compatible with MacKVM 1.00.00 and later;
- DPAPI-protected Windows identity storage;
- atomic, key-pinned trusted-peer storage at
  `%LOCALAPPDATA%\MacKVM\trusted-peers.json`;
- dependency-free dual-stack mDNS advertising for `_mackvm._tcp` and
  `_mackvm-secure._tcp`;
- signed P-256 ephemeral key exchange, HKDF-SHA256 key derivation, and
  ChaCha20-Poly1305 key confirmation;
- bounded framing, replay protection, handshake timeouts, and connection
  admission limits; and
- protocol self-tests that run on macOS or Windows.

W2 proves the authenticated encrypted transport. It does not yet inject
Windows input or implement the final keyboard/mouse hand-off. WinUI/tray UI,
Raw Input, SendInput, encrypted control-message handling, global hotkeys, and
the least-privilege firewall UX are W3 work.

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
   W2 creates `%LOCALAPPDATA%\MacKVM\trusted-peers.json`.
5. Press **Connect** for the paired Windows peer on MacKVM.

Successful W2 authentication prints these lines on Windows:

```text
Incoming secure-session connection
Secure handshake response sent
Secure session authenticated with ...
```

If the peer public key changes, Windows rejects the connection instead of
silently replacing the pinned key. If the identity file cannot be decrypted
or validated, the receiver fails closed; follow the reset procedure in the
[Windows build guide](../WINDOWS_BUILD.md).

## Compatibility

Signed pairing works on Windows 10 build 19041 or later. Secure Connect
requires Windows build 10.0.20142 or later because that is the minimum Windows
build providing the .NET ChaCha20-Poly1305 primitive used by W2. On an older
Windows build, pairing remains available and the executable reports that
secure Connect is disabled.

Run the protocol self-test on a Windows development host with:

```powershell
.\scripts\test-windows.ps1
```

The macOS repository CI also runs this self-test when a .NET 8 SDK is present.
