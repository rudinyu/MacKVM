[繁體中文](USER_MANUAL.zh-TW.md) · [HTML](USER_MANUAL.html)

# MacKVM user manual

MacKVM is a macOS app with a menu-bar entry and a full control window for
sharing one keyboard, mouse, and optionally a BenQ MA270U display between a
14-inch M5 Pro MacBook Pro and a 2019 Intel MacBook Pro.

## Hardware and wiring

- Connect the M5 Pro to the MA270U USB-C video/data port.
- Connect the Intel Mac to HDMI through a USB-C/Thunderbolt adapter.
- Connect the keyboard and mouse to the M5 Pro or the MA270U USB hub. HDMI does
  not carry the monitor hub upstream to the Intel Mac.
- Use **One keyboard on M5 Pro (USB-C)** for the recommended one-way topology.
  Use **External USB switch (bidirectional)** only when both Macs visibly see a
  real physical USB switch.

## Install and build

Build on the M5 Pro and copy the matching app to `/Applications`:

```sh
./scripts/build-app.sh --arch arm64
./scripts/build-app.sh --arch x86_64
```

MacKVM uses native IOKit DDC/CI: `IOAVService` on Apple Silicon and `IOI2C`
on Intel. No display helper or Homebrew package is required. The monitor and
connection must expose VESA DDC/CI; some MA270U firmware does not show a
DDC/CI toggle in the OSD, so MacKVM uses the native bridge when macOS exposes
the display.

For a local DMG:

```sh
./scripts/package-dmg.sh --arch universal
./scripts/verify-release.sh --app dist/universal/MacKVM.app --arch universal
```

Ad-hoc signing is for local testing. Distribution requires Developer ID,
hardened runtime, and Apple notarization.

## First launch

On each Mac open the KVM/display-sharing menu-bar icon or the MacKVM Dock/window
entry and complete **Set up this Mac**:

1. Enable Local Network and confirm the macOS prompt.
2. Request Input Monitoring and grant it.
3. Request Accessibility and grant it.
4. Optionally enable control request notifications and Launch MacKVM at Login.

If a permission was previously denied, use the matching **Settings** button.

An external display is not required for pairing or remote input. It is only
needed for automatic DDC input switching and cross-display pointer mapping.
When started by Login Items, the full window stays hidden so startup does not
steal focus; use the menu-bar icon or activate MacKVM from the Dock to reopen it.

## Monitor setup

1. Set the monitor as the main display on both Macs.
2. On either Mac select **Detect DDC-capable displays**, choose the intended
   display, and use the matching input preset.
3. Both the M5 Pro and Intel Mac use native DDC/CI after their display is
   verified.
   The MA270U EDID mapping sends USB-C as VCP 19 (`0x13`) and HDMI 1 as VCP 17
   (`0x11`); other monitor models use their own firmware mapping. Run the
   diagnostic scan before relying on a new model.
4. Use **Show this Mac** and **Show other Mac** to verify switching. If native
   detection or switching fails, read the diagnostic, check the direct cable
   path, and use the MA270U OSD.
   On the M5 Pro, **Show other Mac** also performs the guarded keyboard/mouse
   hand-off when control prerequisites are ready. **Share keyboard and mouse
   with [Intel Mac]** remains the explicit equivalent; the Intel Mac selects
   **Allow** unless seamless control was enabled for the paired M5 Pro.

### Diagnose a monitor-specific input mapping

The repository includes a native diagnostic tool for both CPU families:

```sh
./scripts/build-ddc-diagnostic.sh --arch arm64
./scripts/build-ddc-diagnostic.sh --arch x86_64
./scripts/build-ddc-diagnostic.sh --arch universal
```

Run the matching binary to save system, EDID, transport, and VCP `0x60` data:

```sh
./dist/ddc-diagnostic-arm64 > arm64-ddc-report.txt 2>&1
./dist/ddc-diagnostic-x86_64 > x86_64-ddc-report.txt 2>&1
```

If the monitor accepts I2C writes but does not switch, opt in to a mapping
scan. It writes candidate values, reads them back, reports matching values as
`accepted=yes`, and restores the initial input:

```sh
./dist/ddc-diagnostic-universal --display 1 --scan-inputs \
  --values 15,16,17,18,19,27
```

The scan temporarily changes the monitor input and must only be run when it is
safe to switch and restore the display. It never changes MacKVM's source
mapping automatically. Ctrl-C/SIGTERM stops the candidate loop and still
attempts to restore the starting input. The tested MA270U uses USB-C VCP `19`
(`0x13`) and HDMI 1 VCP `17` (`0x11`); other models require their own scan.
See the [diagnostic guide](../Tools/DDCDiagnostic/README.md).

## Pair and control

1. Under **Nearby Macs**, select **Pair** on one Mac.
2. Compare the six-digit security code and peer names. The receiving Mac selects
   **Accept** only when the codes match; the initiating Mac selects
   **Confirm code** after comparing the same code.
3. After both signed decisions complete, MacKVM automatically attempts to
   connect the encrypted session. If it remains idle, select
   **Connect** on a paired row. With the keyboard and mouse connected to the M5 Pro, use
   **Show other Mac** or **Share keyboard and mouse with [Intel Mac]**; on the
   M5 Pro both use the display-first route and request control in one action.
   The controlling Mac needs both Input
   Monitoring and Accessibility for its active event tap.
4. A newly paired receiver automatically enables seamless control for the
   pinned peer. To keep per-request consent, turn off **Automatically allow
   control from this Mac** under **Paired device information**. When it is off,
   the receiving Mac needs Accessibility before it selects **Allow**; a closed
   menu can use the native Allow/Deny/Review notification.
5. The M5 Pro can interrupt sharing at any time with
   `Control-Option-Command-Escape`. The global
   `Control-Option-Command-K` shortcut toggles sharing without opening the
   menu: it starts a request while idle and returns input while controlling or
   receiving. To switch back from Intel, select
   **Return keyboard and mouse to [M5 Mac]** on the Intel Mac. The controller
   can also select **Return keyboard and mouse to this Mac**.

Reconnection uses bounded backoff. A peer with seamless control authorization
can resume without another prompt; an opted-out peer requires fresh control
consent. **Disconnect**, **Forget**, and **Quit** clear reconnect intent.

## Paired profiles and support information

Under **Paired device information**, edit and save a friendly name. MacKVM
retains the name, advertised model, last authenticated connection time, and
SHA-256 fingerprint of the pinned public key. New pairings enable seamless
control automatically; use the per-peer toggle to require Allow for every
request.

Select **Copy support information** for a support report. It contains public
version, OS, device, UUID, fingerprint, and connection status data; it excludes
private keys, passwords, credentials, and network endpoints.

## More documentation

- [HTML manual](USER_MANUAL.html) · [繁體中文 HTML 手冊](USER_MANUAL.zh-TW.html)
- [Acceptance test](../MANUAL_TEST.md) · [繁體中文驗收](../MANUAL_TEST.zh-TW.md)
- [Architecture](../ARCHITECTURE.md) · [繁體中文架構](../ARCHITECTURE.zh-TW.md)
- [Security](../SECURITY.md) · [繁體中文安全](../SECURITY.zh-TW.md)
