# Two-Mac acceptance test

[繁體中文](MANUAL_TEST.zh-TW.md) · [Installation guide](INSTALL.md) · [HTML manual](docs/USER_MANUAL.html)

Use this checklist with the actual BenQ MA270U, the 2019 16-inch Intel
MacBook Pro on HDMI, and the 14-inch M5 Pro MacBook Pro on USB-C.

## 1. Build and install on each architecture

On the M5 Pro, build both app architectures:

```sh
./scripts/ci.sh
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
(cd dist && shasum -a 256 -c MacKVM-0.12.30-universal.dmg.sha256)
```

Expected: the app reports both `arm64` and `x86_64`, and an ad-hoc signature
is explicitly labelled as local-testing-only. The checksum command reports
`OK`, and `dist/.staging` is absent after packaging. A release build must
provide a Developer ID Application identity, pass `--require-developer-id`,
and report the hardened runtime before notarization is attempted.

### 1.1 Build and exercise the DDC diagnostic tool

Build all supported diagnostic targets from the same checkout:

```sh
./scripts/build-ddc-diagnostic.sh --arch arm64
./scripts/build-ddc-diagnostic.sh --arch x86_64
./scripts/build-ddc-diagnostic.sh --arch universal
```

On the real machines, save one read-only report from each native binary:

```sh
./dist/ddc-diagnostic-arm64 > arm64-ddc-report.txt 2>&1
./dist/ddc-diagnostic-x86_64 > x86_64-ddc-report.txt 2>&1
```

Verify that each report identifies the running and compiled architecture,
Mac model, macOS build, display EDID, native transport, and VCP `0x60` state.
When the monitor mapping is unknown, run the explicit scan and keep the
result with the acceptance record:

```sh
./dist/ddc-diagnostic-universal --display 1 --scan-inputs \
  --values 15,16,17,18,19,27
```

Only `accepted=yes` readbacks count as mapping evidence. Confirm that the
original input is restored after the scan and that the tool does not change
the app source automatically. Ctrl-C/SIGTERM stops the candidate loop and
still attempts to restore the starting input. For the tested MA270U, expect
USB-C `19` (`0x13`) and HDMI 1 `17` (`0x11`).

## 2. Cable and monitor setup

1. Connect the M5 Pro Mac to the MA270U USB-C video/data/90 W port.
2. Connect the Intel Mac to HDMI 1. If using HDMI 2, use HDMI 2 consistently
   in all later steps.
3. Make the MA270U the main display in macOS on both Macs.
4. MA270U firmware may not expose a DDC/CI OSD toggle. Do not block this
   test on finding one; verify the direct cable path and let MacKVM probe its
   native DDC bridge.
5. On either Mac, select **Detect DDC-capable displays** and choose the
   intended external display explicitly.
7. Select **M5 / USB-C preset** on the M5 Pro Mac.
8. Select **Intel / HDMI preset** on the Intel Mac.

Expected: the MA270U EDID mapping sends the M5 Pro USB-C route as VCP 19
(`0x13`) and the Intel HDMI 1 route as VCP 17 (`0x11`). Other monitor models
use their own mapping; the monitor may silently ignore a value it does not
advertise even when the I2C transaction itself succeeds. Run the diagnostic
scan before accepting a new model mapping.

Expected:

- **Show other Mac** on the M5 Pro selects HDMI 1 and starts the guarded
  keyboard/mouse hand-off when control prerequisites are ready.
- If control prerequisites are not ready, **Show other Mac** still performs
  the display-only route and leaves the physical input local.
- A reconnect or additional display does not silently redirect DDC to display
  number 1; the selected native DDC display remains visibly verified.
- If an older installation saved display number 1, detecting a display can
  replace it with the stable native selector before automatic switching.
- If a saved stable selector is not present, detection does not replace it with
  a different display; select a new display explicitly before enabling DDC.
- After launching MacKVM at login, a native Allow action can switch the
  previously selected display even if its menu has not been opened first; it
  waits for native DDC verification rather than silently losing the first route.
- A display that does not expose a native DDC selector cannot silently enable
  automatic switching.
- A failed DDC command finishes within about five seconds and tells the user
  which input to select through the OSD, including a useful DDC diagnostic.

### Physical input path (P0)

1. Leave **Physical input path** set to **One keyboard on M5 Pro (USB-C)**.
2. Connect the keyboard and mouse to the M5 Pro directly or through the
   MA270U USB hub. Do not assume the Intel HDMI cable carries USB data.
3. On the Intel Mac, verify that **Request keyboard and mouse control** is disabled
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
4. On the receiving Mac, press **Accept** once. On the initiating Mac, press
   **Confirm code** after comparing the same code.
5. Repeat from a clean pairing state with **Pair** pressed on only one Mac and
   both signed decisions completed.
6. Block the receiving Mac's incoming rule or leave its firewall prompt
   unanswered. Confirm the initiator shows a waiting status, then use
   **Cancel pairing** and **Retry pairing** after allowing the rule. Repeat with
   the Intel Mac as initiator and then with the M5 Pro as initiator.

Expected:

- A peer with a matching accepted code becomes **Paired** on both Macs.
- A code mismatch or decline never creates trust.
- The initiating Mac's Pair and Confirm code actions plus the receiving Mac's
  Accept action converge to one request and one code.
- A waiting transport can be canceled without quitting either app, and Retry
  starts a fresh request after firewall approval.
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
- Reconnect succeeds without repeating pairing; seamless-authorized peers can
  resume control without another Allow prompt.

## 6. Keyboard and mouse control

1. After pairing, open **Paired device information** on the receiver and verify
   **Automatically allow control from this Mac** is enabled for the paired
   controller.
2. Close the receiver menu, then from the M5 Pro request control of the Intel
   Mac. Verify control starts without a second Allow action and the monitor and
   keyboard route agree.
3. Turn off **Automatically allow control from this Mac** on the receiver,
   then request control again after returning input locally.
4. Verify the Intel Mac receives a native macOS notification naming the M5 Pro
   and offering **Allow**, **Deny**, and **Review in MacKVM**. Verify Review
   opens an explicit approval dialog, then test each action.
5. Lock the receiving Mac and choose **Allow** from the notification; macOS
   must require authentication before it accepts the action.
6. Open the menu and select **Allow**. Repeat once with **Deny** and once by
   waiting for the timeout.
7. Type, move, click, drag, scroll, and use modifier shortcuts.
8. Rapidly click at least four times immediately after selecting **Allow**.
9. Move the pointer onto a secondary display, if connected.
10. Hold a modifier and mouse button, then disconnect the network.
11. After a timeout, disconnect, or remote cancellation, tap any retained
   notification action if macOS still displays it.
12. On a Mac where notifications are not enabled, request control and verify
    that MacKVM does not open a first-time notification-permission sheet during
    the short consent window; its keyboard menu-bar icon should add a warning
    symbol and retain the menu controls instead.
13. Disable MacKVM notifications in System Settings, request control again, and
   confirm the request remains available in the menu.
14. Repeat with the Intel Mac controlling the M5 Pro Mac.
15. While control is active, toggle an input method on the controlling Mac (for
    example enable Zhuyin, type a letter, then switch back to English) without
    changing its underlying physical keyboard layout. Press keys throughout.
16. Set the two Macs to genuinely different physical keyboard layouts in
    **System Settings → Keyboard → Input Sources** (for example US on one,
    Dvorak or a European ABC layout on the other). Request keyboard and mouse
    control, then type
    letters, numbers, and symbol keys, including combinations that need Shift,
    Option, and Caps Lock on at least one of the two layouts.
17. Still on differing layouts — ideally with one Mac set to a layout where
    letter positions genuinely move, such as German QWERTZ, where Y and Z
    trade places relative to US — use Cmd-Z to undo an action on the
    controlling Mac.
18. Still on differing layouts, turn Caps Lock on on the controlling Mac, then
    repeat the same Cmd-Z shortcut from step 15.
19. Still on differing layouts, hold a remappable letter key on the
    controlling Mac long enough for macOS's own key-repeat to kick in, release
    Shift partway through the hold without releasing the letter key, then
    release the letter key.
20. Still on differing layouts, type a character that exists on the
    controller's layout but has no equivalent on the receiver's layout (a
    layout-specific symbol is usually easiest to find), then request control
    again from the same Mac.
21. Restore both Macs to the same keyboard layout before continuing to the
    next section.
22. If an older MacKVM build (from before cross-layout remapping) is
    available, pair it with a current build, set the two Macs to differing
    keyboard layouts, and request control from either side.
23. If ISO or JIS keyboard hardware is available, set the two Macs to
    differing layouts including that hardware and type its layout-specific
    keys (for example the ISO key next to the left Shift key) during control.
24. While controlling, press and hold a volume key, then a brightness key, on
    the controlling Mac's physical keyboard.
25. While controlling, press the power key and Caps Lock on the controlling
    Mac's physical keyboard.

Expected:

- Input is not suppressed until the receiver grants the matching request ID or
  the receiver-side seamless authorization is enabled for that pinned peer.
- A newly paired peer starts without a second prompt; after the toggle is
  disabled, the receiver never begins injection before its user selects
  **Allow**.
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
- Using the emergency shortcut or the receiver's **Return keyboard and mouse
  to [M5 Mac]** action while a request is active or waiting stops remote
  capture and restores the local display and keyboard route.
- After a display-only **Show other Mac**, **Return display to this Mac** is
  available even when the global emergency shortcut could not be registered.
- A second inbound control request is denied without disturbing the active one.
- Toggling an input method (step 13) does not end control and does not change
  which characters are typed; a differing keyboard layout no longer denies the
  control request at all.
- With genuinely different physical layouts (step 14), each typed character
  matches what the controller intended, including Shift/Option/Caps
  Lock-modified keys, not whatever the sender's keycode means on the
  receiver's layout. Keys outside the remapped set — arrows, Return, Tab,
  Delete, Escape, Space, function keys, and modifiers — behave identically to
  same-layout control.
- Cmd-Z in step 15 fires Undo on the receiving Mac even though the letter
  positions differ between the two layouts — it must land on the receiver's
  key that actually produces "z", not on whatever the sender's raw keycode
  means locally (which, on a US-sender/German-receiver pairing, would be
  "y"). Step 16 confirms the same shortcut fires identically with the
  sender's Caps Lock on: it must not turn into Command-Shift-Z (Redo) or
  anything else.
- In step 17, the receiving Mac shows the repeated character only for as long
  as the key is actually held, and releasing the key leaves nothing stuck
  down or still repeating — releasing Shift mid-hold must not change which
  local key eventually receives the release.
- The unmappable character in step 18 ends remote input safely — a clear
  status message, no stuck key or mouse button, local input still works
  immediately afterward — rather than injecting the wrong character, and a
  fresh control request from the same Mac succeeds normally afterward.
- In step 20, the current build denies the older build's request before the
  consent prompt when the layouts differ (status names the version gap)
  rather than granting it and ending control on the first remappable
  keystroke; requests with matching layouts, or from the older build acting
  as receiver, are unaffected.
- In step 21, the ISO/JIS-specific keys type the correct character, not
  whatever an ANSI interpretation of the same position would produce.
- The volume and brightness keys in step 22 change the setting only on the
  receiving Mac, with its own on-screen indicator; the controlling Mac's own
  volume/brightness is unaffected.
- The power key in step 23 has no effect on either Mac — no shutdown or sleep
  dialog appears on the receiver. Caps Lock toggles correctly and only once
  per physical press.

## 7. Safe return and monitor routing

1. On the M5 Pro, select **Show other Mac** (or the explicit
   **Share keyboard and mouse with [Intel Mac]** action) and verify that the
   display switches before input capture starts.
2. With the session connected and idle, press **Control-Option-Command-O** and
   verify that it follows the guarded **Show other Mac** route: the monitor
   switches first, then the control request starts without opening the menu.
   After the receiver accepts (when seamless control is disabled), verify that
   the display and keyboard/mouse ownership move together.
3. From the Mac that is receiving control, press **Control-Option-Command-O**
   again and verify that receiving ends and the controller's display and
   keyboard/mouse ownership are restored.
4. While controlling, press **Control-Option-Command-K** and verify that input
   returns locally; repeat with **Control-Option-Command-Escape**.
5. Repeat using **Return keyboard and mouse to this Mac**.
6. From the receiving Intel Mac, select **Return keyboard and mouse to [M5 Mac]** while a key and a
   mouse button are held by the controlling Mac.
7. Repeat the hotkey test from the receiving Mac when a bidirectional USB path
   is configured; verify it returns control to the controller.
8. Repeat while DDC/CI is disabled or unavailable and confirm the OSD fallback.
9. Quit MacKVM while the monitor shows the other Mac.
10. Repeat step 9 while this Mac is receiving remote control.

Expected:

- The shortcut is consumed locally and immediately stops forwarding.
- `Control-Option-Command-K` starts or ends the control route without opening
  the menu, depending on the current state.
- `Control-Option-Command-O` follows the guarded display-first route: it moves
  the display and keyboard/mouse ownership together, and from the receiving
  side it ends receiving and restores both to the controller.
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

## 9. Paired-device profile and support information

1. Pair the two Macs, then open **Paired device information** in the menu.
2. Confirm the paired device's friendly name and detected model are shown.
3. Replace the friendly name with a safe value, select **Save**, quit and
   relaunch MacKVM, and confirm the edited name remains.
4. Connect to the peer, disconnect, and reopen the menu. Confirm **Last
   connected** changes to the time of the authenticated connection.
5. Confirm the key fingerprint is a 32-byte SHA-256 value shown as 32
   colon-separated hexadecimal pairs and remains unchanged after reconnect.
6. Select **Copy support information**, paste into a plain-text editor, and
   verify it contains app/build, OS, local model/name/fingerprint, paired
   metadata, and connection status.
7. Verify the copied report contains no private key, password, credential,
   or network endpoint, and that names/statuses containing line breaks are kept
   on one line.

Expected:

- Profile fields survive app restart and pair removal clears the profile.
- A successful authenticated connection updates only the timestamp/model; it
  does not replace a user-edited friendly name.
- The support report is deterministic in peer order and contains public
  diagnostics only.

## 10. Identity recovery

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

## 11. P2 physical acceptance on the real setup

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
4. Use **Show other Mac** while watching the MA270U OSD: HDMI 1 (or the
   selected HDMI input) must show the Intel Mac. If DDC/CI fails, use the OSD
   manually and record the diagnostic text.
5. During an active control session, test the menu-bar **Return keyboard and mouse to [M5 Mac]**
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
| Paired profile / support copy |  |  |  |
| Secure reconnect |  |  |  |
| Keyboard/mouse |  |  |  |
| Media/system keys |  |  |  |
| Cross-layout keyboard remap |  |  |  |
| Control consent / receiver stop |  |  |  |
| Emergency return |  |  |  |
| DDC-capable display detection / stable ID |  |  |  |
| ARM64/Intel diagnostic report |  |  |  |
| VCP 0x60 mapping scan / restore |  |  |  |
| Native DDC/CI switch |  |  |  |
| Manual OSD fallback |  |  |  |
