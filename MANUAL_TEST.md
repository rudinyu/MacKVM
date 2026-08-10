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

Release check (from the M5 Pro) is also available:

```sh
./scripts/package-dmg.sh --arch universal
./scripts/verify-release.sh --app dist/universal/MacKVM.app --arch universal
(cd dist && shasum -a 256 -c MacKVM-0.6.2-universal.dmg.sha256)
```

Expected: the app reports both `arm64` and `x86_64`, and an ad-hoc signature
is explicitly labelled as local-testing-only. The checksum command reports
`OK`, and `dist/.staging` is absent after packaging. A release build must
provide a Developer ID Application identity, pass `--require-developer-id`,
and report the hardened runtime before notarization is attempted.

## 2. Cable and monitor setup

1. Connect the M5 Pro Mac to the MA270U USB-C video/data/90 W port.
2. Connect the Intel Mac to HDMI 1. If using HDMI 2, use HDMI 2 consistently
   in all later steps.
3. Make the MA270U the main display in macOS on both Macs.
4. In the MA270U OSD, enable DDC/CI if that setting is available.
5. Install `m1ddc` on the M5 Pro Mac with `brew install m1ddc`.
6. Select **Detect MA270U** on the M5 Pro Mac and choose the display explicitly
   identified as MA270U with its stable identifier.
7. Select **M5 / USB-C preset** on the M5 Pro Mac.
8. Select **Intel / HDMI preset** on the Intel Mac.

Expected:

- **Show this Mac** on the M5 Pro selects USB-C.
- **Show other Mac** on the M5 Pro selects HDMI 1.
- A reconnect or additional display does not silently redirect DDC to display
  number 1; the selected MA270U remains visibly verified.
- If an older installation saved display number 1, detecting the MA270U
  replaces it with the stable identifier before automatic switching.
- If a saved stable identifier is not present, detection does not replace it
  with a different MA270U; select a new display explicitly before enabling DDC.
- After launching MacKVM at login, a native Allow action can switch the
  previously selected MA270U even if its menu has not been opened first; it
  waits for MA270U verification rather than silently losing the first route.
- A non-MA270U display is visibly marked and cannot be reported as a verified
  MA270U or silently enable automatic switching.
- A failed DDC command finishes within about five seconds and tells the user
  which input to select through the OSD, including a useful DDC diagnostic.

### Physical input path (P0)

1. Leave **Physical input path** set to **One keyboard on M5 Pro (USB-C)**.
2. Connect the keyboard and mouse to the M5 Pro directly or through the
   MA270U USB hub. Do not assume the Intel HDMI cable carries USB data.
3. On the Intel Mac, verify that **Request control of other Mac** is disabled
   in this mode, while the Intel Mac can still receive remote control.
4. If an external USB switch is installed, select **External USB switch
   (bidirectional)** on both Macs and verify that both macOS systems see the
   keyboard and mouse before trying either control direction.

Expected:

- The recommended mode never advertises a false bidirectional HDMI path.
- The external-switch mode warns that hardware cannot be detected by software;
  selecting the mode after verifying both Macs see the devices is the user's
  acknowledgement, and it permits both directions.

## 3. Permissions

1. Start MacKVM on a Mac where one or more permissions have not been granted
   and open the menu-bar item.
2. Under **Set up this Mac**, select **Enable Local Network**. Answer the
   macOS prompt before selecting **I handled the macOS prompt**.
3. Select **Request Input Monitoring**, grant it, return to MacKVM, and verify
   that the checklist advances without quitting the app.
4. Select **Request Accessibility** and grant it.
5. After the checklist is complete, select **Enable** beside **Control request
   notifications** and grant the optional macOS alert permission.
6. Repeat on the other Mac.
7. If a system permission sheet does not reappear after a previous denial,
   click the corresponding **Settings** button and then use **Refresh setup
   status** after returning to the app.
8. If Local Network was denied, use **Review Local Network Settings**, allow
   MacKVM there, then confirm nearby Macs can be discovered. The app cannot
   preflight this particular macOS setting.

Expected:

- The checklist never presents Input Monitoring/Accessibility before the user
  has explicitly handled the Local Network step.
- Only one macOS privacy request can be initiated at a time.
- **Settings** opens the matching Privacy & Security pane.
- The Local Network row says **Reviewed**, not **Granted**, and its recovery
  shortcut remains available after the checklist advances.
- Both permission rows show **Granted**.
- Control cannot begin while a required permission is missing.
- The optional notification request is presented only after the three required
  setup items; granting or denying it does not grant remote control.

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

1. On the receiving Mac, close the MacKVM menu, then from the M5 Pro request
   control of the Intel Mac.
2. Verify the Intel Mac receives a native macOS notification naming the M5 Pro
   and offering **Allow**, **Deny**, and **Review in MacKVM**. Verify Review
   opens an explicit approval dialog, then test each action.
3. Lock the receiving Mac and choose **Allow** from the notification; macOS
   must require authentication before it accepts the action.
4. Open the menu and select **Allow**. Repeat once with **Deny** and once by
   waiting for the timeout.
5. Type, move, click, drag, scroll, and use modifier shortcuts.
6. Rapidly click at least four times immediately after selecting **Allow**.
7. Move the pointer onto a secondary display, if connected.
8. Hold a modifier and mouse button, then disconnect the network.
9. After a timeout, disconnect, or remote cancellation, tap any retained
   notification action if macOS still displays it.
10. On a Mac where notifications are not enabled, request control and verify
    that MacKVM does not open a first-time notification-permission sheet during
    the short consent window; its keyboard menu-bar icon should add a warning
    symbol and retain the menu controls instead.
11. Disable MacKVM notifications in System Settings, request control again, and
   confirm the request remains available in the menu.
12. Repeat with the Intel Mac controlling the M5 Pro Mac.
13. Change the keyboard input source on one Mac while control is active, then
    press a key. Restore the same input source on both Macs and request control
    again.

Expected:

- Input is not suppressed until the receiver grants the matching request ID.
- The receiver never begins injection before its user selects **Allow**.
- A closed menu does not hide a request: native actions use the live request ID
  plus a fresh device-local notification nonce, while an expired/stale
  notification cannot grant or deny a later request.
- If notifications are disabled, MacKVM shows a warning symbol beside its
  keyboard menu-bar icon and preserves the manual Allow/Deny controls in the
  menu.
- While controlling, input reaches only the receiving Mac.
- The first keyboard/mouse event after **Allow** is not lost.
- Pointer coordinates remain bounded to the receiving main display.
- Four-click sequences are delivered.
- Disconnect/end paths release every held key and mouse button.
- A second inbound control request is denied without disturbing the active one.
- Different keyboard layout identifiers deny control before the receiver's
  consent prompt; a layout change during control ends remote input and releases
  held state.

## 7. Safe return and monitor routing

1. While controlling, press **Control-Option-Command-Escape**.
2. Repeat using **Return input to this Mac**.
3. From the receiving Mac, select **Stop remote control** while a key and a
   mouse button are held by the controlling Mac.
4. Repeat while DDC is disabled or `m1ddc` is unavailable.
5. Quit MacKVM while the monitor shows the other Mac.
6. Repeat step 5 while this Mac is receiving remote control.

Expected:

- The shortcut is consumed locally and immediately stops forwarding.
- The receiving Mac can stop a live session without disconnecting or quitting;
  both held keys and mouse buttons are released before the peer is notified.
- Keyboard and mouse return before any monitor-switch result is assumed.
- On quit during receiver-side control, injected input is released and the
  monitor finishes on this Mac's local input, never on the remote route.
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

## 9. Identity recovery

1. With a disposable test profile, make the stored identity and Keychain key
   disagree (or remove the Keychain item using a test account), then launch
   MacKVM.
2. Select **Reset this Mac identity** in the bootstrap error view.
3. Quit and relaunch, then pair both Macs again.

Expected:

- Reset is offered only for a device-credential error.
- The action reports that pairings will be removed and never rotates identity
  automatically during ordinary startup.
- After relaunch, a new identity is created and old pairings cannot reconnect.

## 10. P2 physical acceptance on the real setup

Run this section on the actual 14-inch M5 Pro, 2019 16-inch Intel MacBook Pro,
and BenQ MA270U; CI cannot emulate a monitor's DDC/CI response, a USB switch,
or macOS privacy prompts.

1. Launch the arm64 app on the M5 Pro and the x86_64 app on the Intel Mac.
   Complete Local Network, Input Monitoring, and Accessibility on both Macs,
   then pair them with matching verification codes.
2. With **One keyboard on M5 Pro (USB-C)** selected, connect the keyboard and
   mouse to the M5 Pro or the MA270U USB hub. Verify the M5 Pro can request
   control and the Intel Mac can receive it, while the Intel Mac's request
   action remains disabled.
3. If using a physical USB switch, connect it to both Macs, select
   **External USB switch (bidirectional)** on both, verify both systems see the
   devices, and test control in both directions. Do not rely on the app to
   detect the switch.
4. Use **Show this Mac** and **Show other Mac** while watching the MA270U OSD:
   USB-C must show the M5 Pro and HDMI 1 (or the selected HDMI input) must show
   the Intel Mac. If DDC/CI fails, use the OSD manually and record the
   diagnostic text.
5. During an active control session, test the menu-bar **Stop remote control**
   action, the emergency shortcut, a network unplug/reconnect, and a quit.
   Confirm the local keyboard/mouse returns and no key or mouse button remains
   stuck.

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
| Control consent / receiver stop |  |  |  |
| Emergency return |  |  |  |
| MA270U detection / stable ID |  | N/A (`m1ddc`) |  |
| MA270U DDC switch |  | N/A (`m1ddc`) |  |
| Manual OSD fallback |  |  |  |
