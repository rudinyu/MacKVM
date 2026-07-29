# Two-Mac acceptance test

Use this checklist with the actual BenQ MA270U, the 2019 16-inch Intel
MacBook Pro on HDMI, and the 14-inch M5 Pro MacBook Pro on USB-C.

## 1. Build and install on each architecture

On the M5 Pro, build both app architectures:

```sh
./.codex/ci.sh
./scripts/build-app.sh --arch arm64
./scripts/build-app.sh --arch x86_64
```

Copy `dist/arm64/MacKVM.app` to `/Applications` on the M5 Pro. Copy
`dist/x86_64/MacKVM.app` to `/Applications` on the Intel Mac, then launch each
app on its matching architecture.

Expected:

- `lipo -archs dist/arm64/MacKVM.app/Contents/MacOS/MacKVM` prints `arm64`.
- `lipo -archs dist/x86_64/MacKVM.app/Contents/MacOS/MacKVM` prints `x86_64`.
- `codesign --verify --deep --strict` succeeds for both app bundles.
- Finder displays the MacKVM app icon clearly at small and large icon sizes.
- MacKVM appears only in the menu bar with a visible keyboard icon.
- macOS asks for local-network access when needed.

## 2. Cable and monitor setup

1. Connect the M5 Pro Mac to the MA270U USB-C video/data/90 W port.
2. Connect the Intel Mac to HDMI 1. If using HDMI 2, use HDMI 2 consistently
   in all later steps.
3. Make the MA270U the main display in macOS on both Macs.
4. In the MA270U OSD, enable DDC/CI if that setting is available.
5. Install `m1ddc` on the M5 Pro Mac with `brew install m1ddc`.
6. Select **M5 / USB-C preset** on the M5 Pro Mac.
7. Select **Intel / HDMI preset** on the Intel Mac.

Expected:

- **Show this Mac** on the M5 Pro selects USB-C.
- **Show other Mac** on the M5 Pro selects HDMI 1.
- A failed DDC command finishes within about five seconds and tells the user
  which input to select through the OSD.

## 3. Permissions

1. Start MacKVM on a Mac where one or both keyboard/mouse permissions have not
   been granted.
2. In the MacKVM setup alert, select **Request Permissions**.
3. Grant the first permission requested, then quit and reopen MacKVM to request
   the next missing permission.
4. On both Macs, grant MacKVM:

   - Input Monitoring;
   - Accessibility;
   - Local Network access when prompted.

5. If a system permission sheet does not reappear after a previous denial,
   click the corresponding **Settings** button in the MacKVM menu.
6. Quit and reopen MacKVM after changing privacy permissions.

Expected:

- A setup alert appears proactively while either keyboard/mouse permission is
  missing.
- Only one macOS keyboard/mouse privacy prompt is requested per launch.
- **Settings** opens the matching Privacy & Security pane.
- Both permission rows show **Granted**.
- Control cannot begin while a required permission is missing.

## 4. Discovery and pairing

1. Confirm each Mac appears under **Nearby Macs**.
2. Press **Pair** on one Mac.
3. Confirm both Macs show the same six-digit code and peer name.
4. Press **Accept** on both Macs.
5. Repeat from a clean pairing state while pressing **Pair** on both Macs at
   nearly the same time.

Expected:

- A peer with a matching accepted code becomes **Paired** on both Macs.
- A code mismatch or decline never creates trust.
- Simultaneous Pair actions converge to one request and one code.
- **Forget** removes the pinned key; reconnect is blocked until pairing again.

## 5. Secure reconnect

1. Press **Connect**.
2. Disconnect and reconnect from each Mac.
3. Quit one app, reopen it, and reconnect.
4. Turn Wi-Fi off during a connection, then restore it.

Expected:

- The status reports an encrypted session with only the paired UUID.
- A transport loss immediately restores local input and releases remote keys
  and mouse buttons.
- Reconnect succeeds without repeating pairing.

## 6. Keyboard and mouse control

1. From the M5 Pro Mac, request control of the Intel Mac.
2. Type, move, click, drag, scroll, and use modifier shortcuts.
3. Rapidly click at least four times.
4. Move the pointer onto a secondary display, if connected.
5. Hold a modifier and mouse button, then disconnect the network.
6. Repeat with the Intel Mac controlling the M5 Pro Mac.

Expected:

- Input is not suppressed until the receiver grants the matching request ID.
- While controlling, input reaches only the receiving Mac.
- Pointer coordinates remain bounded to the receiving main display.
- Four-click sequences are delivered.
- Disconnect/end paths release every held key and mouse button.
- A second inbound control request is denied without disturbing the active one.

## 7. Safe return and monitor routing

1. While controlling, press **Control-Option-Command-Escape**.
2. Repeat using **Return input to this Mac**.
3. Repeat while DDC is disabled or `m1ddc` is unavailable.
4. Quit MacKVM while the monitor shows the other Mac.

Expected:

- The shortcut is consumed locally and immediately stops forwarding.
- Keyboard and mouse return before any monitor-switch result is assumed.
- The M5 Pro attempts the correct USB-C/HDMI route; otherwise status identifies
  the exact OSD input to choose.
- Quit waits for the final DDC attempt (at most about five seconds).

## 8. Menu-bar residency

1. Enable **Launch MacKVM at Login** in the MacKVM menu.
2. Confirm macOS lists or enables MacKVM under **System Settings → General →
   Login Items**. If approval is required, approve it there.
3. Sign out and back in, or restart the Mac.
4. Disable **Launch MacKVM at Login** and confirm the login item is removed.

Expected:

- The keyboard icon returns to the menu bar after login when enabled.
- MacKVM reports when macOS requires Login Items approval.
- Disabling the setting prevents future login launches without quitting the
  current MacKVM process.

## Acceptance record

Record the macOS version and result for each item:

| Area | M5 Pro | Intel 2019 | Result/notes |
| --- | --- | --- | --- |
| Native app launch |  |  |  |
| App/menu-bar icon |  |  |  |
| Permissions |  |  |  |
| Launch at login |  |  |  |
| Discovery/pairing |  |  |  |
| Secure reconnect |  |  |  |
| Keyboard/mouse |  |  |  |
| Emergency return |  |  |  |
| MA270U DDC switch |  | N/A (`m1ddc`) |  |
| Manual OSD fallback |  |  |  |
