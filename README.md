[繁體中文](README.zh-TW.md)

# RemoteMac self-hosted relay

MacKVM is the native macOS client for the RemoteMac self-hosted relay.

MacKVM is a native macOS app with both a menu-bar entry and a regular window
for sharing a keyboard, mouse, and trackpad, with optional monitor switching, between two
Macs on the same local network.

The current MVP provides:

- a native high-resolution app icon, a KVM/display-sharing icon in the macOS
  menu bar, and a regular Dock/window entry; it adds a warning symbol for a
  pending incoming control request;
- a persistent local device identity;
- Bonjour discovery on the local network;
- signed pairing requests that must be accepted on the receiving Mac;
- a six-digit device-key verification code;
- persistent public-key pinning for paired devices;
- persistent paired-device profiles with editable friendly names, detected Mac
  models, last successful connection times, and SHA-256 key fingerprints;
- per-paired-Mac seamless control authorization, enabled when pairing
  completes and revocable from **Paired device information**;
- a **Copy support information** action that exports public diagnostics without
  private keys, credentials, or network endpoints;
- a persistent authenticated session using signed ephemeral P-256 key exchange,
  directional HKDF keys, ChaChaPoly encryption, and replay-protected counters.
- validated keyboard, mouse, and trackpad event forwarding over that encrypted
  session, including high-resolution two-axis trackpad scrolling, scroll phase
  and momentum, click/drag/secondary-click state, and pressure when macOS
  exposes it, plus an allowlisted set of media, volume, and brightness keys;
- a sequential Local Network, Input Monitoring, and Accessibility setup
  checklist that prevents overlapping macOS permission prompts and refreshes
  when MacKVM becomes active again;
- an optional **Launch MacKVM at Login** setting;
- injected-event marking that prevents input feedback loops;
- explicit Allow/Deny control consent on the receiving Mac, deterministic
  collision handling, and a receiver-side stop action;
- explicit physical-input topology modes that document the external USB path;
  each Mac can still originate software control from its own keyboard, mouse,
  and trackpad, regardless of CPU architecture or HDMI wiring;
- network-path monitoring with bounded automatic reconnect after Wi-Fi,
  sleep/wake, or peer-service interruptions;
- a control-protocol compatibility check before consent, cross-layout keyboard
  remapping so typing keys still produce the right characters when the two
  Macs use different keyboard layouts, and a safe identity-reset path when the
  local Keychain identity is damaged;
- native macOS incoming-control notifications with Allow, Deny, and Review
  actions, so the receiver can respond while the menu is closed;
- local input suppression while controlling and an emergency
  `Control-Option-Command-Escape` return shortcut, plus a
  `Control-Option-Command-K` shortcut for toggling keyboard, mouse, and trackpad ownership
  after the monitor input has been selected manually, and a
  `Control-Option-Command-O` guarded display-first shortcut that automatically
  switches the display before transferring keyboard, mouse, and trackpad ownership like
  **Show other Mac**;
- native DDC/CI input switching through IOKit on both Apple Silicon and Intel,
  including display discovery, stable display selection, diagnostics, and a
  manual OSD fallback when the monitor or cable does not expose DDC/CI.

## Requirements

- macOS 13 or later
- Swift 6 toolchain (Xcode is preferred when installed)
- An external monitor and cable that expose VESA DDC/CI are optional; they are
  required only for automatic monitor input switching.

MacKVM sends the input-source VCP command directly through IOKit: Apple
Silicon uses the display's `IOAVService`, while Intel uses the display's
`IOI2C` interface. No Homebrew helper or external executable is required, and
both architectures use the same automatic switching flow.

## How to build

Build and ad-hoc sign an app bundle for the current Mac:

```sh
./scripts/build-app.sh
open dist/MacKVM.app
```

The result is `dist/MacKVM.app`.

An Apple Silicon Mac can also cross-build both supported architectures:

```sh
# M5 Pro / Apple Silicon
./scripts/build-app.sh --arch arm64

# 2019 Intel MacBook Pro
./scripts/build-app.sh --arch x86_64
```

These commands produce `dist/arm64/MacKVM.app` and
`dist/x86_64/MacKVM.app`. Copy the x86_64 app to the Intel Mac and the arm64
app to the M5 Pro Mac. The build script verifies the Mach-O architecture and
the ad-hoc code signature without trying to execute the cross-built app.

### Native DDC diagnostics

Build the architecture-aware diagnostic tool when a monitor's input mapping
is unknown or when a write reports success without switching the display:

```sh
./scripts/build-ddc-diagnostic.sh --arch arm64
./scripts/build-ddc-diagnostic.sh --arch x86_64
./scripts/build-ddc-diagnostic.sh --arch universal
```

See the [diagnostic tool guide](Tools/DDCDiagnostic/README.md),
[diagnostic source](Tools/DDCDiagnostic/ddc-diagnostic.m), and
[diagnostic build script](scripts/build-ddc-diagnostic.sh) for the read-only
system/EDID report and the opt-in VCP `0x60` scan. The scan reads back every
candidate and restores the starting input; a successful I2C write alone is
not treated as proof that a monitor accepts a value. These files are part of
this repository and are built by the normal CI job. Ctrl-C/SIGTERM stops the
candidate loop and still attempts to restore the starting input.

Create a disk image after building. The default is a universal DMG with an
ad-hoc signature for local testing:

```sh
./scripts/package-dmg.sh --arch universal
```

The package is built from a fresh staging directory and writes a portable
SHA-256 sidecar next to the DMG. Verify the pair from the `dist` directory:

```sh
(cd dist && shasum -a 256 -c MacKVM-1.100.00-universal.dmg.sha256)
```

For distribution to another Mac, sign with a Developer ID Application
identity and require the release check to reject ad-hoc signing:

```sh
./scripts/package-dmg.sh \
  --arch universal \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  --require-developer-id
```

When a Developer ID identity is supplied, the app is signed with Apple's
hardened runtime and `--require-developer-id` verifies both the authority and
runtime flag. Submit the verified DMG to Apple's notarization service before
using it as a public release; no notarization credentials belong in this
repository.

`scripts/verify-release.sh` verifies an existing app bundle without creating a
DMG. Ad-hoc signatures pass local verification but are not Apple Developer ID
signatures and may require Finder's **Open** confirmation on another Mac.

The app bundle copies precompiled icon resources so normal builds also work
with Command Line Tools only. After editing `Resources/Assets.xcassets`, use
full Xcode to regenerate and commit both compiled resources:

```sh
DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer \
  ./scripts/regenerate-app-icon.sh
```

Run the Swift test suite with the full Xcode toolchain before packaging:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --disable-sandbox
```

The app bundle is the supported launch path because it contains the Bonjour
and Local Network privacy metadata required by macOS. Run it on both Macs while
they are connected to the same local network. Pairing and remote input do not
require an external display; only pointer mapping and DDC switching do.

Before the first launch, copy the matching app into `/Applications`. MacKVM
appears with a KVM/display-sharing icon in the menu bar and as a regular Dock
app with a full control window. Open either entry and complete **Set up this
Mac** on each computer:

1. Select **Enable Local Network**, answer the macOS prompt, then select
   **I handled the macOS prompt**.
2. Select **Request Input Monitoring** and grant the macOS prompt.
3. Select **Request Accessibility** and grant the next prompt. MacKVM refreshes
   the checklist when it becomes active after System Settings.
4. If a prompt was previously denied, use the matching **Settings** shortcut.
   After the Local Network step, **Review Local Network Settings** remains
   available because macOS does not expose an API that lets MacKVM verify the
   Allow/Deny choice.
5. After the checklist is complete, select **Enable** beside **Control request
   notifications**. This optional prompt is best handled before the first live
   control request, so it does not consume the 15-second consent window.
6. Enable **Launch MacKVM at Login** in the menu if the menu-bar icon should
   return automatically after signing in.
   Login-item launches keep the full window hidden so startup does not steal
   focus; open it from the KVM menu-bar icon or activate MacKVM from the Dock.
7. In **Paired device information**, review or edit a paired Mac's friendly
   name. The model, last successful connection time, and public-key fingerprint
   are retained across relaunches. Select **Copy support information** when
   reporting an issue; the copied text contains only public diagnostic values.
   A newly paired Mac is automatically authorized for seamless control on this
   Mac; turn off **Automatically allow control from this Mac** there if each
   control request should require Allow again.

The menu follows the Mac's language and includes English and Traditional
Chinese resources. The three required macOS permission descriptions are also
localized; if macOS does not show a prompt after a previous denial, use the
matching **Settings** shortcut instead.

In the MacKVM menu:

1. Under **Physical input path**, keep **One keyboard on M5 Pro (USB-C)** for
   the current external-device wiring. Connect the external keyboard and mouse
   to the M5 Pro directly or through the MA270U USB hub. HDMI carries video
   only, so those external USB devices remain attached to the M5 Pro; the
   Intel Mac can nevertheless originate control from its own keyboard, mouse,
   and trackpad. If both Macs see the external devices through a real USB
   switch, select **External USB switch (bidirectional)** on both Macs and test
   both directions first.
2. On either Mac, select **Detect DDC-capable displays** and choose the display
   explicitly. MacKVM saves a stable native DDC selector rather than assuming
   display number 1; a display that is not rediscovered cannot enable automatic
   switching.
3. On the M5 Pro Mac, select **M5 / USB-C preset**. This sets this Mac to
   logical USB-C, the other Mac to HDMI 1 (VCP 17), and enables native DDC.
   MacKVM applies the MA270U EDID-specific USB-C value (VCP 19 / 0x13); other
   monitor models keep their generic firmware value. Use the diagnostic scan
   when the model or firmware is unknown.
4. On the 2019 Intel Mac, select **Intel / HDMI preset**. This sets the local
   route to HDMI 1 and enables native DDC on Intel as well.
   A fresh Intel installation already uses HDMI 1 as its local default; the
   preset is still useful when upgrading an installation with older saved
   USB-C preferences.
5. If the Intel Mac uses HDMI 2, change both matching input pickers to HDMI 2.
6. Use **Show other Mac** to verify switching before starting remote control.
   MA270U firmware may not expose a DDC/CI toggle in its OSD; MacKVM uses the
   native bridge when macOS exposes the display. If detection or switching
   fails, read the **DDC diagnostic**, check the direct cable path, and use the
   OSD input menu as the fallback. For a display-only route, use **Return
   display to this Mac**; during control, the emergency shortcut or the
   receiver's **Return keyboard, mouse, and trackpad to [M5 Mac]** action restores the
   local route.
   On either Mac, **Show other Mac** also starts the guarded keyboard, mouse,
   and trackpad hand-off when the control prerequisites are ready. **Share
   keyboard, mouse, and trackpad with [other Mac]** remains the explicit
   equivalent; the receiver selects **Allow** unless seamless control was
   enabled for the paired peer.

After the receiving Mac accepts the matching code, the initiating Mac must
compare the same code and select **Confirm code**. Both signed decisions are
required before MacKVM automatically attempts to connect the encrypted
session. If the session remains idle, select **Connect** on a paired row. When
one Mac selects **Request keyboard, mouse, and trackpad control**, the
controlling Mac must have both Input Monitoring and Accessibility so its
active event tap can capture and suppress the physical input. The receiving
Mac must also have Accessibility before it selects **Allow** or **Deny**. If its MacKVM menu is closed, macOS shows a
native notification with **Allow**, **Deny**, and **Review in MacKVM** instead.
**Review in MacKVM** opens an explicit Allow/Deny dialog. Each action is checked
against the live request ID and a fresh device-local notification nonce, so an
expired notification cannot start control. **Allow** requires macOS
authentication when the receiver is locked. Only the explicit **Enable** setup
action can show the optional macOS notification-permission prompt; otherwise
MacKVM falls back to a visible menu-bar warning and the window/menu controls. It can always
select **Return keyboard, mouse, and trackpad to [M5 Mac]** to release injected
keys/buttons and return control to the controller. If macOS notifications are
disabled, its KVM menu-bar icon shows a warning symbol and the same
request remains in the menu.

Either Mac can initiate pairing. If the receiving Mac shows a macOS Firewall
prompt, allow incoming connections there before continuing. If the initiator
stays in a waiting state, use **Cancel pairing** or **Retry pairing** in the
menu after the firewall rule has been updated. For the common MA270U setup,
starting from the Intel Mac makes the M5 Pro the receiving Mac and can avoid an
unapproved inbound rule on the Intel Mac; this is an operational workaround,
not an architecture-specific protocol requirement.

After pairing, the receiving Mac enables seamless control for that pinned peer
by default, so the first request does not depend on seeing the receiving
display or sharing a second keyboard. This is a local one-time authorization,
not a wire-level grant; disable it from **Paired device information** to return
to per-request Allow prompts. Use the emergency shortcut or the receiver's
**Return keyboard, mouse, and trackpad to [M5 Mac]** action to stop an active or
waiting remote-control request and restore the local display and input.

For the MA270U wiring, the M5 Pro owns the external keyboard and mouse, but
either MacBook can be the software controller from its local keyboard, mouse,
and trackpad. After sharing starts, press
**Control-Option-Command-Escape** on the M5 Pro at any time to interrupt the
session and return input locally. The receiving Mac can select **Return
keyboard, mouse, and trackpad to [other Mac]**; it releases injected input and
the monitor route returns to the controller.
The global **Control-Option-Command-K** shortcut is for a manually selected
monitor route: it toggles keyboard, mouse, and trackpad ownership without running automatic
DDC display switching. It starts a request while idle and returns input while
controlling or receiving.
The **Control-Option-Command-O** shortcut follows the guarded display-first
**Show other Mac** route: when this Mac owns the local route, it switches the
display and then requests keyboard, mouse, and trackpad control; when this Mac is receiving
control, it ends receiving and restores the controller's display and input.

After an authenticated transport loss, MacKVM releases local input immediately
and retries the last user-selected peer with a bounded 0/1/2/4…30-second
backoff. A deliberate **Disconnect**, **Forget**, or **Quit** clears that
reconnect intent. Pairing is not repeated; a paired peer with seamless control
authorization can resume control without another prompt, while an opted-out
peer must be granted again. If the keyboard layout changes while control is live,
the receiver stops remote input and asks both users to choose the same macOS
input source before trying again.

When macOS is about to sleep, MacKVM closes the secure transport before network
suspension so the peer immediately returns to local input. After wake, the
previously selected paired peer is discovered and reconnected automatically;
keyboard, mouse, and trackpad Hotkeys are then available without a manual
Disconnect action.

If the app cannot load its Keychain identity, the error view offers **Reset this
Mac identity**. Use it only after confirming that the old identity should be
discarded; it removes local pairings, and the next launch requires pairing both
Macs again.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the current architecture, known
issues, wiring diagram, and MVP usage instructions.
See [`MANUAL_TEST.md`](MANUAL_TEST.md) for the complete two-Mac hardware
acceptance checklist.
See [`docs/USER_MANUAL.html`](docs/USER_MANUAL.html) for the English HTML manual,
[`docs/USER_MANUAL.zh-TW.html`](docs/USER_MANUAL.zh-TW.html) for the Traditional
Chinese HTML manual, and the matching Markdown files in `docs/`.

## Recommended wiring

- Apple Silicon MacBook Pro: USB-C to the BenQ MA270U
- Intel 2019 MacBook Pro: USB-C/Thunderbolt 3 to HDMI
- External keyboard and mouse: connect to the M5 Pro directly or through the
  MA270U USB hub. HDMI does not carry the monitor hub upstream to the Intel
  Mac. The built-in keyboard, mouse, and trackpad on either Mac remain valid
  local control sources.

This is a one-way external USB topology, not a one-way software-control
topology: either Mac can request control and the receiver can inject the full
keyboard, mouse, and supported trackpad pointer/scroll event set. Select the
app's **External USB switch (bidirectional)** mode only when a real USB switch
makes the external devices visible to both Macs.

The public Quartz event API carries trackpad movement, clicks, drags, precise
two-axis scrolling, inertia phases, and exposed pressure. AppKit-only gestures
such as pinch, rotate, and three-finger workspace swipes are not globally
injectable through public `CGEvent`; they remain outside this release's
acceptance scope.

This keeps DDC/CI communication on the more reliable USB-C connection.

The input-source VCP values follow the VESA DDC/CI convention. BenQ lists two
HDMI 2.0 ports and one USB-C video/data/90 W port in the
[MA270U specifications](https://www.benq.com/en-us/monitor/home/ma270u/spec.html).

## Documentation

- [English installation guide](INSTALL.md) · [繁體中文安裝指南](INSTALL.zh-TW.md)
- [English architecture](ARCHITECTURE.md) · [繁體中文架構](ARCHITECTURE.zh-TW.md)
- [English acceptance test](MANUAL_TEST.md) · [繁體中文驗收](MANUAL_TEST.zh-TW.md)
- [English security status](SECURITY.md) · [繁體中文安全說明](SECURITY.zh-TW.md)
- [English roadmap](ROADMAP.md) · [繁體中文路線圖](ROADMAP.zh-TW.md)
- [English changelog](CHANGELOG.md) · [繁體中文變更記錄](CHANGELOG.zh-TW.md)
- [English HTML manual](docs/USER_MANUAL.html) · [繁體中文 HTML 使用手冊](docs/USER_MANUAL.zh-TW.html)
- [English Markdown manual](docs/USER_MANUAL.md) · [繁體中文 Markdown 手冊](docs/USER_MANUAL.zh-TW.md)
