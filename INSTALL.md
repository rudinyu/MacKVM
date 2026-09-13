[繁體中文](INSTALL.zh-TW.md)

# MacKVM installation guide

This guide installs MacKVM on the target two-Mac setup: a 14-inch Apple
Silicon M5 Pro MacBook Pro connected to a BenQ MA270U over USB-C, and a 2019
16-inch Intel MacBook Pro connected over HDMI.

## Requirements

- macOS 13 or later on both Macs.
- A trusted local network shared by both Macs.
- Swift 6 toolchain or Xcode on the Mac used to build the app.
- An external monitor and connection that expose VESA DDC/CI. Some MA270U
  firmware does not show a DDC/CI toggle in the OSD; MacKVM uses the native
  bridge when macOS exposes the display.

MacKVM uses native IOKit DDC/CI: `IOAVService` on Apple Silicon and `IOI2C`
on Intel. There is no Homebrew helper to install, and the same automatic input
switching flow is available on both Macs. The MA270U USB-C value is selected by
its EDID mapping (`19` / `0x13`); other models keep their generic value or can
be mapped after running the diagnostic scan.

## Build the app

Build on the M5 Pro, which can produce both architectures:

```sh
./scripts/build-app.sh --arch arm64
./scripts/build-app.sh --arch x86_64
```

Install `dist/arm64/MacKVM.app` on the M5 Pro and
`dist/x86_64/MacKVM.app` on the Intel Mac. The build script verifies the
Mach-O architecture and the ad-hoc signature.

Run the local checks before installation:

```sh
./scripts/ci.sh
```

### Build the native DDC diagnostic

The repository also ships the source and build script for the standalone
`ddc-diagnostic` tool. Build the matching report tool on each Mac, or build a
universal binary on the M5 Pro:

```sh
./scripts/build-ddc-diagnostic.sh --arch arm64
./scripts/build-ddc-diagnostic.sh --arch x86_64
./scripts/build-ddc-diagnostic.sh --arch universal
```

The tool reports the running architecture, compiled architecture, Mac model,
macOS build, display EDID identity, native transport, and VCP `0x60` input
state. Save a read-only report with:

```sh
./dist/ddc-diagnostic-arm64 > arm64-ddc-report.txt 2>&1
./dist/ddc-diagnostic-x86_64 > x86_64-ddc-report.txt 2>&1
```

When a monitor accepts an I2C write but does not change input, opt in to the
mapping scan. It writes each candidate to VCP `0x60`, reads it back, reports
only matching values as accepted, and restores the starting input:

```sh
./dist/ddc-diagnostic-universal --display 1 --scan-inputs \
  --values 15,16,17,18,19,27
```

The scan temporarily changes the monitor input, so run it only when the
display can safely switch and the original input can be restored. It never
modifies the app mapping automatically. For the tested BenQ MA270U, USB-C is
VCP `19` (`0x13`) and HDMI 1 is VCP `17` (`0x11`); other models and firmware
must be confirmed with the scan. See the [diagnostic tool guide](Tools/DDCDiagnostic/README.md)
and the [source](Tools/DDCDiagnostic/ddc-diagnostic.m). Ctrl-C/SIGTERM stops
the candidate loop and still attempts to restore the starting input.

Create and verify a universal DMG for local testing:

```sh
./scripts/package-dmg.sh --arch universal
./scripts/verify-release.sh \
  --app dist/universal/MacKVM.app \
  --arch universal
(cd dist && shasum -a 256 -c MacKVM-1.100.06-universal.dmg.sha256)
```

Ad-hoc signing is suitable only for local testing. For direct distribution
outside the Mac App Store, use the separate notarized release script. Create a
notarytool Keychain profile once; the command prompts for an app-specific
password:

```sh
xcrun notarytool store-credentials "mackvm-notary" \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "YOUR_TEAM_ID"

./scripts/package-notarized-dmg.sh \
  --arch universal \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  --keychain-profile "mackvm-notary"
```

The script requires Developer ID Application signing, enables the hardened
runtime, adds a secure timestamp, signs the DMG, submits it to Apple, staples
the accepted ticket, validates the result, and regenerates the final SHA-256
sidecar. No signing, notarization, or Keychain credentials belong in this
repository.

## Install and grant permissions

The release DMG includes `Install MacKVM.command`, `Uninstall MacKVM.command`,
and both installation guides. To install from Finder, open the DMG and
double-click `Install MacKVM.command`. The script validates the app signature
and bundle identifier, then installs it to `/Applications`; it does not change
pairing data, private keys, preferences, or macOS privacy permissions. Quit an
existing MacKVM process before upgrading. You can also drag `MacKVM.app` onto
the `/Applications` shortcut in the DMG.

To uninstall, quit MacKVM and double-click `Uninstall MacKVM.command`. It
removes only `/Applications/MacKVM.app`. If **Launch MacKVM at Login** was
enabled, remove MacKVM from **System Settings > General > Login Items**. The
script intentionally leaves user data and permissions intact; use MacKVM's
identity reset or the relevant System Settings pages when those need to be
reset separately. A signed PKG is not part of this release path because it
requires a Developer ID Installer certificate in addition to the app signing
certificate.

After installation, open MacKVM from `/Applications`.

1. Select **Enable Local Network**, respond to the macOS prompt, then select
   **I handled the macOS prompt**.
2. Select **Request Input Monitoring** and grant the permission.
3. Select **Request Accessibility** and grant the permission.
4. If a permission was previously denied, use the matching **Settings** button.
5. Optionally select **Enable** beside **Control request notifications** before
   the first control request.
6. Optionally enable **Launch MacKVM at Login**.

MacKVM appears with a KVM/display-sharing icon in the menu bar and as a regular
Dock app with a full control window. The app bundle, rather than `swift run`,
is required because it contains the Bonjour and Local Network privacy metadata.
Pairing and remote input work without an external display; DDC switching and
cross-display pointer mapping are optional monitor features.
When launched by Login Items, MacKVM keeps the full window hidden so startup
does not steal focus; open it from the menu-bar icon or activate it from the
Dock when needed.

## Configure the monitor and input path

1. Connect the M5 Pro to the MA270U USB-C video/data port.
2. Connect the Intel Mac to HDMI 1, or use HDMI 2 consistently in both input
   pickers if that is the chosen port.
3. Set the MA270U as the main display on both Macs.
4. On either Mac, select **Detect DDC-capable displays** and choose the
   intended external display explicitly, then select the matching preset.
5. On the M5 Pro, **M5 / USB-C preset** selects logical USB-C locally and HDMI
   1 (VCP 17) on the other Mac. The MA270U EDID mapping sends USB-C as VCP 19
   (`0x13`); on other models use the diagnostic scan. On the Intel Mac,
   **Intel / HDMI preset** selects HDMI 1 locally and keeps native DDC enabled.
   A fresh Intel install uses HDMI 1 as its local default; use the preset to
   migrate an older saved USB-C preference. Input values are monitor-firmware
   specific.
6. Select **One keyboard on M5 Pro (USB-C)** when the external keyboard and
   mouse are connected to the M5 Pro or the MA270U USB hub. HDMI does not carry
   USB data to the Intel Mac, but either Mac can still request control from its
   own keyboard, mouse, and trackpad.
7. Use **Show other Mac** to verify switching. Some MA270U firmware has no
   DDC/CI OSD toggle; if native detection fails, use the diagnostic text,
   check the direct cable path, and switch inputs through the MA270U OSD.
   For a display-only route, use **Return display to this Mac**. Returning
   control with the emergency shortcut or the receiver's
   **Return keyboard, mouse, and trackpad to [other Mac]** action restores the
   local route. On either Mac, **Show other Mac** also starts the guarded
   keyboard, mouse, and trackpad hand-off when the control prerequisites are
   ready. **Share keyboard, mouse, and trackpad with [other Mac]** remains the
   explicit equivalent; the receiver selects **Allow** unless seamless control
   was enabled for the paired peer.

Select **External USB switch (bidirectional)** only after both Macs visibly see
the external keyboard and mouse through a real physical USB switch. This setting
describes external USB wiring; it does not disable local keyboard, mouse, or
trackpad control on either Mac.

## Pair and control the Macs

1. After the Local Network step is complete, open the MacKVM menu on both Macs.
2. Under **Nearby Macs**, select **Pair** on one Mac.
3. Compare the six-digit security code and peer name on both Macs.
4. On the receiving Mac, select **Accept** only when the code matches. On the
   initiating Mac, select **Confirm code** after comparing the same code.
   Either Mac may be the initiator. If the receiving Mac shows a macOS
   Firewall prompt, allow incoming connections there. If the initiator remains
   waiting, select **Cancel pairing** or **Retry pairing** after the rule is
   allowed. For the M5／Intel setup, starting from Intel is a valid workaround
   when Intel's inbound rule has not yet been approved.
5. After both signed decisions complete, MacKVM automatically attempts to
   connect the encrypted session. If it remains idle, select **Connect** on
   either paired row.
6. On either Mac, select **Share keyboard, mouse, and trackpad with [other Mac]**.
   This switches the MA270U to the other Mac when DDC is configured and then
   starts the keyboard, mouse, and trackpad control request.
7. A newly paired receiver automatically enables seamless control for that
   pinned peer. To keep per-request consent, turn off **Automatically allow
   control from this Mac** under **Paired device information**. When it is off,
   select **Allow** on the receiving Mac; a closed menu can use the native
   Allow/Deny/Review notification, and Review opens the MacKVM approval dialog.
8. Either Mac can interrupt at any time with
   `Control-Option-Command-Escape`. To switch back from Intel, select
   **Return keyboard, mouse, and trackpad to [other Mac]** on the receiving
   Mac. The controller can also select **Return keyboard, mouse, and trackpad
   to this Mac**. The global `Control-Option-Command-K` shortcut toggles
   keyboard, mouse, and trackpad ownership after
   you manually select the monitor input; it starts a request when idle and
   returns input when controlling or receiving, without running automatic DDC
   switching. `Control-Option-Command-O` follows the guarded **Show other Mac**
   route: it automatically switches the display and then requests keyboard,
   mouse, and trackpad control, or ends receiving and restores the controller's
   display and input.

The public Quartz event path forwards trackpad movement, clicks, drags,
secondary clicks, precise two-axis scrolling, and momentum phases. A shared
trackpad acts as a pointing device, not a gesture surface: `CGEvent` publishes
constructors for keyboard, mouse, and scroll wheel only, so pinch, rotate,
smart zoom, three- and four-finger swipes, Mission Control, App Exposé, and
Launchpad stay local to the controlling Mac. The pressure value on a click is
carried, but the force-click stage transition is not, so force click does not
activate on the receiver.

After a transport loss, MacKVM reconnects with bounded backoff. A peer with
seamless control authorization can resume control without another prompt;
otherwise it requires fresh consent. **Disconnect**, **Forget**, and **Quit**
clear reconnect intent.

## Device profiles and support information

Under **Paired device information**, edit and save a friendly name. MacKVM
retains the name, advertised model, last authenticated connection time, and
the SHA-256 fingerprint of the pinned public key across relaunches. A newly
paired Mac is automatically authorized for seamless control; use the per-peer
toggle there to require Allow for every request.

Select **Copy support information** when reporting a problem. The report
contains public version, OS, device, fingerprint, and connection-status data;
it excludes private keys, passwords, credentials, and network endpoints.

## More documentation

- [Architecture](ARCHITECTURE.md) · [繁體中文架構](ARCHITECTURE.zh-TW.md)
- [Acceptance test](MANUAL_TEST.md) · [繁體中文驗收](MANUAL_TEST.zh-TW.md)
- [Security status](SECURITY.md) · [繁體中文安全說明](SECURITY.zh-TW.md)
- [English HTML manual](docs/USER_MANUAL.html) · [Traditional Chinese HTML manual](docs/USER_MANUAL.zh-TW.html)
- [English Markdown manual](docs/USER_MANUAL.md) · [Traditional Chinese Markdown manual](docs/USER_MANUAL.zh-TW.md)
