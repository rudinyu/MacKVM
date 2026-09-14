[繁體中文](README.zh-TW.md)

# WindowsKVM

WindowsKVM is the Windows companion for MacKVM. The current Windows feature
includes a resident native Win32 UI/tray host that can pair with MacKVM,
authenticate a secure Connect session, and receive keyboard/mouse control over
that encrypted session. A console mode remains available for automation and
firewall diagnostics.

## Current feature set — 1.02.22 (build 102)

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
- authenticated secure sessions configure Windows TCP keepalive (five-second
  idle, two-second probe interval, three probes) and poll socket liveness with
  a five-second grace period, releasing control and allowing reconnect when a
  peer disappears without application traffic; and
- strict lower-camel control-message and remote-input validation compatible
  with MacKVM protocol v2;
- Windows `SendInput` keyboard, modifier, Unicode fallback, mouse, button,
  media-key, and unit-aware pixel/line scroll injection (including pointer
  pressure and trackpad phase metadata);
- key-repeat forwarding and native middle/XBUTTON1/XBUTTON2 mapping; unsupported
  brightness, keyboard-illumination keys, and extra mouse buttons are safely
  ignored instead of triggering unrelated Windows actions;
- release-all cleanup on control end, input failure, disconnect, or process
  shutdown;
- native pairing/control consent dialogs in the UI, a resident system-tray
  icon, a macOS-aligned scrollable status window, and public **Copy support
  information** output;
- Advanced mode renders the complete local key fingerprint over deterministic
  short lines, so high-DPI or narrow windows cannot let the following DPAPI
  note overwrite it;
- automatic control approval enabled by default when an interactive Mac
  pairing completes (the test-only `--yes` control approval remains one-shot);
  the **Automatically allow control from this paired Mac** checkbox and
  `--allow-control`/`--deny-control` commands can revoke or restore that local
  durable decision. If automatic approval is disabled, an individual control
  dialog's **Allow** applies to that request only; use the checkbox or
  `--allow-control` to enable approval durably again;
- responsive **Simple mode** and **Advanced mode** views: the UI starts in
  compact Simple mode, keeps essential identity/pairing/control
  actions visible, and lets the user switch modes from the header;
- an explicit **Forget paired Mac** action in device management that removes the
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
 session must request control and pass the local consent policy first. An
 interactive pairing enables the local automatic-control decision for that
 pinned key by default; the test-only `--yes` pairing does not persist it. Turn
 it off in **Paired device information** when every request should prompt.
Windows Raw Input capture and a polished firewall setup wizard remain later
work.

### UI layout

The Windows status window follows the same information order as the macOS
MacKVM panel. It has two views:

- **Simple mode** is the compact default. It shows the PC name, concise
  readiness, pairing and control status, essential actions, and a small
  version/build label. Model, TCP ports, UUIDs, full key fingerprints, and
  lengthy setup explanations are not shown in this everyday view.
- **Advanced mode** keeps the full identities, firewall settings, device
  management, control-approval settings, diagnostics, and support information.
  Use the header button to switch modes; returning to Simple makes the window
  compact again. Advanced scrolls vertically on short displays and adds a
  horizontal scrollbar on narrow windows so full-size controls remain reachable.

Manual resizing uses a monitor-aware minimum size and preserves Windows' own
minimum, preventing Simple controls from overlapping in an extremely narrow window.
The window title and heading are **WindowsKVM**. Narrow Simple windows place
the mode button below the heading. Scrolling batches child movement and
repaints the whole view instead of retaining old row pixels.

Consent requests are never hidden by the selected mode. Use Advanced to read
complete diagnostic details when the compact status reports an error. The
tray menu can reopen the hidden status window; the visible main window does
not need a second **Open window** button.

The full Advanced view contains:

1. **Header** — WindowsKVM branding, this PC's friendly name, device ID, model,
   version/build, and public key fingerprint.
2. **Set up this PC** — Local Network, Input Monitoring, Accessibility,
   firewall settings, input readiness, control-request notifications, and a
   refresh action.
3. **Physical input path** — the keyboard/mouse/trackpad ownership summary and
   the Windows `SendInput` path. **Local Windows input only** disables remote
   control admission (and releases any active grant); switch back to the first
   option to allow a paired Mac to request control again.
   The dropdown opens with room for both options, even after scrolling or
   resizing. This setting does not enable Windows-to-Mac input forwarding.
4. **Nearby Macs** — pairing listener state and a selector containing every
   trusted Mac (including its short device ID); choose the peer before using
   **Forget paired Mac**. Pair and Connect are initiated from the MacKVM peer.
5. **Keyboard, mouse, and trackpad** — permission state, current control state,
   and the local-return hotkey.
6. **Monitor input** — explains that display switching is optional and remains
   controlled from MacKVM or the monitor OSD.
7. **Paired device information** — the current Mac's public identity,
   **Forget paired Mac**, the **Automatically allow control from this paired
   Mac** setting, local identity details, and the public **Copy support
   information** action.

Native Windows Allow/Deny dialogs are used for pairing-code consent and for control
requests whose automatic approval was disabled. Peers from an interactive
pairing are admitted without a control dialog until that setting is turned off;
the test-only `--yes` pairing instead leaves approval unconfigured. After that, an
individual control-dialog **Allow** is one-shot and does not change the durable
setting; use the checkbox or `--allow-control` to restore automatic approval.
The system-tray menu provides **Open WindowsKVM** and **Quit WindowsKVM**.

Only one UI or console receiver may run at a time. Close the running receiver
with **Quit WindowsKVM** before starting `--pairing-listen`; hiding its window
does not stop it. Version and paired-device management commands remain usable
without starting another receiver.

Consent dialogs are tied to the current request and are shown one at a time.
A cancelled or expired request closes its dialog; it cannot be approved later.
If that happens, start a new request from MacKVM and verify its new code.

## Build and run

Use the [Windows build guide](../WINDOWS_BUILD.md) for SDK installation,
architecture-specific publishing, and troubleshooting. The supported native
targets are Windows x64 (`win-x64`, also called `x86_64`) and Windows ARM64
(`win-arm64`); 32-bit x86 is not supported.
For console log capture and cross-platform diagnosis, see the
[debugging guide](../DEBUGGING.md).

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
Connect. An already-running receiver refreshes the durable trust decision at
control admission and while input is flowing, so **Forget**, key replacement,
and `--deny-control` take effect without restarting it. The UI **Forget paired
Mac** action also asks the resident receiver to close matching sessions
immediately.

## Pair and connect

1. Start `WindowsKVM.exe` (or `WindowsKVM.exe --ui`) on Windows. The UI starts
   the pairing and secure-session listeners and adds a tray icon. For a scripted
   console test, use `WindowsKVM.exe --pairing-listen` instead.
2. Start Pair on the paired Mac and compare the six-digit code.
3. In UI mode, compare the six-digit code in the pairing dialog and click
   **Allow**. In console mode, type `y` at the `Accept pairing?` prompt.
4. If the Windows peer was paired by an older W1 build, pair it once again so
   W2/W3 creates `%LOCALAPPDATA%\MacKVM\trusted-peers.json`.
5. To remove a Windows-side trust pin, choose **Forget paired Mac** in the
   Windows UI and confirm the warning. Forget disconnects any active secure
   session; start Pair again from MacKVM before connecting.
6. Press **Connect** for the paired Windows peer on MacKVM.
7. From MacKVM choose **Request keyboard and mouse control**. A newly paired
   Mac is allowed automatically by default. Disable the checkbox or run
   `--deny-control <peer-id>` to require confirmation again; the Windows UI
   dialog or console `y`/`yes` prompt will then appear. An individual **Allow**
   in that dialog is one-shot and does not re-enable the durable approval. Use
   the checkbox or `--allow-control <peer-id>` to restore automatic approval.
   The `--yes` option grants control only for the current request during a
   controlled test run; that automatic-control approval is never persisted
   (the pairing trust pin is still stored).
8. To return control locally, press `Ctrl+Alt+Shift+Esc` on Windows, or end
   control from MacKVM. Any held key/button is released during either path.

Returning control does not disconnect the authenticated session. Input already
in flight for the ended request is ignored; a later control request must obtain
a new grant. Selecting **Local Windows input only** also notifies the Mac that
control ended. Re-enabling remote input permits a new request, but does not
silently revive the previous grant.

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

## Windows regression acceptance

Run these checks on both Windows x64 and ARM64 using a compatible MacKVM peer.
Use a disposable text document for input tests. Automated tests with simulated
native APIs do not replace these desktop checks.

1. Hold a letter, Backspace, and an arrow key in turn. Repeat should continue
   while held and stop on release. End control while Ctrl or a mouse button is
   down; ordinary local input must work afterwards without a stuck modifier.
2. Check a middle click and both side buttons with a five-button mouse. The
   middle button must not become Back; both side buttons must remain usable
   without ending control. Test brightness/illumination keys: they must not
   launch Mail, stop playback, or disconnect the session. Windows brightness
   adjustment is not implemented by this receiver.
3. Move the mouse continuously while using the Windows release hotkey. The
   secure connection must remain established; request control again without
   re-pairing or reconnecting.
4. During control, select **Local Windows input only**, then quickly re-enable
   remote input. The old grant must stay ended. A fresh request from MacKVM
   must work; also repeat while a consent request is still pending.
5. Disable automatic control approval for the test peer. Leave a control
   consent dialog unanswered past its 15-second timeout, and separately cancel
   a pairing request from the Mac. The obsolete dialog must close, and retry
   must show only the new request. Test multiple queued requests and closing
   the app while a consent dialog is open; none may accept a stale request.
6. With UI mode resident, start `--pairing-listen` in a console: the second
   receiver must exit while the first remains usable. Check `--version` and
   `--list-paired` still work. Quit the UI, start the console receiver, and
   repeat the duplicate-start check by opening the UI.
7. Check Simple mode on a 1366×768 desktop and at 150%/200% scaling. Its
   essential actions must remain reachable and the outer window must not
   cover the taskbar. Open Advanced to inspect the hidden identity and port
   details; on a narrow window, use the Advanced horizontal scrollbar to reach
   the right-hand actions. Return to Simple and confirm the window shrinks and
   the horizontal scrollbar disappears. Drag to the minimum size and check
   that the mode and pairing buttons do not overlap. Resize or
   move between monitors during a connection; changing the view must not
   reset pairing or control, and consent prompts must remain usable.
8. Confirm `--version` reports **1.02.22 (build 102)**; the reported UI defects
   were tested on **1.02.09 (build 89) Beta 3**, not this build. Quit the old
   tray receiver before starting the replacement. Check the title/heading say
   **WindowsKVM**. Scroll Advanced rapidly up/down and drag both scrollbars;
   old text must not remain. Open **Physical input path** before and after
   scrolling/resizing and select each of the two options. Repeat in Simple
   mode and check that both selectors reflect the same choice. Restore remote
   input and request fresh control from the Mac to verify it still works.

## Compatibility

Signed pairing works on Windows 10 build 19041 or later. Secure Connect
requires Windows build 10.0.20142 or later because that is the minimum Windows
build providing the .NET ChaCha20-Poly1305 primitive used by W3. On an older
Windows build, pairing remains available and the executable reports that
secure Connect is disabled.

Run the protocol and desktop regression self-tests on a development host with:

```powershell
.\scripts\test-windows.ps1
```

The macOS repository CI also runs these self-tests when a .NET 8 SDK or newer
is present. Desktop tests use injected platform boundaries for deterministic
checks; native Windows dialog and input acceptance remains a separate step.
