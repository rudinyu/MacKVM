[繁體中文](README.zh-TW.md)

# WindowsKVM

WindowsKVM is the Windows companion for MacKVM. The current Windows feature
includes a resident native Win32 UI/tray host that can pair with MacKVM,
authenticate a secure Connect session, and receive keyboard/mouse control over
that encrypted session. A console mode remains available for automation and
firewall diagnostics.

## Current feature set — 1.02.09 (build 89)

The Windows host includes:

- MacKVM 1.00.00 is not supported by this beta; use a MacKVM build with the
  signed `disconnectSignalVersion` capability (introduced in MacKVM
  1.100.00/build 75) for pairing and authenticated secure Connect;
- authenticated secure Connect includes the signed
  `disconnectSignalVersion` capability and encrypted disconnect
  acknowledgement;
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
- native pairing/control consent dialogs in the UI, a resident system-tray
  icon, a macOS-aligned scrollable status window, and public **Copy support
  information** output;
- responsive **Simple mode** and **Advanced mode** views: the UI starts in
  Simple mode on compact displays, keeps essential identity/pairing/control
  actions visible, and lets the user switch modes from the header;
- an explicit **Forget paired Mac** action in both UI modes that removes the
  Windows trust pin and disconnects that peer's active secure session;
- a shared console consent prompt in `--pairing-listen` mode (or `--yes` for
  test runs); and
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

The UI host starts at launch and keeps the receiver resident in the Windows
notification area. Closing the status window hides it; **Quit WindowsKVM** in
the window or tray menu stops mDNS, TCP listeners, and input injection. The
Windows side never accepts unauthenticated input: a paired, authenticated Mac
session must request control and pass the local consent policy first. Windows
Raw Input capture and a polished firewall setup wizard remain later work.

### UI layout

The Windows status window follows the same information order as the macOS
MacKVM panel. It has two views:

- **Simple mode** is selected automatically when the screen is smaller than
  900×1120 pixels or the window client area is compact. It keeps the version,
  network/input readiness, pairing status, control state, firewall settings,
  Refresh, and Quit actions visible without requiring a long scroll.
- **Advanced mode** keeps the complete diagnostic and support sections. Use
  the header button to switch modes; the advanced view remains scrollable on
  short displays.

The full Advanced view contains:

1. **Header** — MacKVM branding, this PC's friendly name, device ID, model,
   version/build, and public key fingerprint.
2. **Set up this PC** — Local Network, Input Monitoring, Accessibility,
   firewall settings, input readiness, control-request notifications, and a
   refresh action.
3. **Physical input path** — the keyboard/mouse/trackpad ownership summary and
   the Windows `SendInput` path. **Local Windows input only** disables remote
   control admission (and releases any active grant); switch back to the first
   option to allow a paired Mac to request control again.
4. **Nearby Macs** — pairing listener state and a selector containing every
   trusted Mac (including its short device ID); choose the peer before using
   **Forget paired Mac**. Pair and Connect are initiated from the MacKVM peer.
5. **Keyboard, mouse, and trackpad** — permission state, current control state,
   and the local-return hotkey.
6. **Monitor input** — explains that display switching is optional and remains
   controlled from MacKVM or the monitor OSD.
7. **Paired device information** — the current Mac's public identity,
   **Forget paired Mac**, local identity details, and the public **Copy support
   information** action.

Native Windows Yes/No dialogs are used for pairing-code and control consent,
while the system-tray menu provides **Open WindowsKVM** and **Quit WindowsKVM**.

## Build and run

Use the [Windows build guide](../WINDOWS_BUILD.md) for SDK installation,
architecture-specific publishing, and troubleshooting. The supported native
targets are Windows x64 (`win-x64`, also called `x86_64`) and Windows ARM64
(`win-arm64`); 32-bit x86 is not supported.

```powershell
.\scripts\build-windows.ps1 -Architecture x64
.\scripts\build-windows.ps1 -Architecture arm64
.\dist\windows\x64\WindowsKVM.exe --version
.\dist\windows\x64\WindowsKVM.exe
```

The default command starts the resident UI and tray host. Use
`--pairing-listen --name "Windows x64"` for the console receiver. Use the ARM64 executable on Windows ARM. Allow the normal Windows Defender
Firewall prompt for the trusted Private network only; WindowsKVM does not add
a broad or silent firewall rule.

To inspect or remove Windows-side trust from a console, first list the stored
peer IDs and then pass the complete ID to `--forget`:

```powershell
.\dist\windows\x64\WindowsKVM.exe --list-paired
.\dist\windows\x64\WindowsKVM.exe --forget <peer-id>
```

The one-shot CLI command removes durable trust and requires a new Pair before
Connect. It cannot close an active session held by another already-running
receiver process; restart that receiver to reload the store, or use the UI
**Forget paired Mac** action when active-session revocation is needed.

## Pair and connect

1. Start `WindowsKVM.exe` (or `WindowsKVM.exe --ui`) on Windows. The UI starts
   the pairing and secure-session listeners and adds a tray icon. For a scripted
   console test, use `WindowsKVM.exe --pairing-listen` instead.
2. Start Pair on the paired Mac and compare the six-digit code.
3. In UI mode, compare the six-digit code in the pairing dialog and click
   **Yes**. In console mode, type `y` at the `Accept pairing?` prompt.
4. If the Windows peer was paired by an older W1 build, pair it once again so
   W2/W3 creates `%LOCALAPPDATA%\MacKVM\trusted-peers.json`.
5. To remove a Windows-side trust pin, choose **Forget paired Mac** in the
   Windows UI and confirm the warning. Forget disconnects any active secure
   session; start Pair again from MacKVM before connecting.
6. Press **Connect** for the paired Windows peer on MacKVM.
7. From MacKVM choose **Request keyboard and mouse control**. In UI mode,
   approve the native Windows control dialog. In console mode, compare the
   Windows prompt and type `y` (or start WindowsKVM with `--yes` for a
   controlled test run).
8. To return control locally, press `Ctrl+Alt+Shift+Esc` on Windows, or end
   control from MacKVM. Any held key/button is released during either path.

Successful authentication and control prints these lines in console mode (the
same state is shown in the UI status window):

```text
Incoming secure-session connection
Secure handshake response sent
Secure session authenticated with ...
Windows control granted for ...
```

If the peer public key changes, Windows rejects the connection instead of
silently replacing the pinned key. A deliberate re-pair after a Mac identity
reset shows an explicit replacement warning and updates the pin only after
the verification code is accepted. If the identity file cannot be decrypted
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
