[繁體中文](USER_MANUAL.zh-TW.md) · [HTML](USER_MANUAL.html)

# MacKVM user manual

MacKVM is a macOS menu-bar app for sharing one keyboard, mouse, and BenQ MA270U
display between a 14-inch M5 Pro MacBook Pro and a 2019 Intel MacBook Pro.

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
connection must expose VESA DDC/CI; enable it in the monitor OSD when needed.

For a local DMG:

```sh
./scripts/package-dmg.sh --arch universal
./scripts/verify-release.sh --app dist/universal/MacKVM.app --arch universal
```

Ad-hoc signing is for local testing. Distribution requires Developer ID,
hardened runtime, and Apple notarization.

## First launch

On each Mac open the menu-bar keyboard icon and complete **Set up this Mac**:

1. Enable Local Network and confirm the macOS prompt.
2. Request Input Monitoring and grant it.
3. Request Accessibility and grant it.
4. Optionally enable control request notifications and Launch MacKVM at Login.

If a permission was previously denied, use the matching **Settings** button.

## Monitor setup

1. Set the monitor as the main display on both Macs.
2. On either Mac select **Detect DDC-capable displays**, choose the intended
   display, and use the matching input preset.
3. Both the M5 Pro and Intel Mac use native DDC/CI after their display is
   verified.
4. Use **Show this Mac** and **Show other Mac** to verify switching. If DDC/CI
   fails, read the diagnostic and use the MA270U OSD.

## Pair and control

1. Under **Nearby Macs**, select **Pair** on one Mac.
2. Compare the six-digit security code and peer names; select **Accept** on both
   Macs only when the codes match.
3. Select **Connect**, then request control from the Mac whose keyboard and
   mouse you are using.
4. The receiving Mac must select **Allow**. A closed menu can use the native
   Allow/Deny/Review notification.
5. End control with **Return input to this Mac**, **Stop remote control**, or
   `Control-Option-Command-Escape`.

Reconnection uses bounded backoff but always requires fresh control consent.
**Disconnect**, **Forget**, and **Quit** clear reconnect intent.

## Paired profiles and support information

Under **Paired device information**, edit and save a friendly name. MacKVM
retains the name, advertised model, last authenticated connection time, and
SHA-256 fingerprint of the pinned public key.

Select **Copy support information** for a support report. It contains public
version, OS, device, UUID, fingerprint, and connection status data; it excludes
private keys, passwords, credentials, and network endpoints.

## More documentation

- [HTML manual](USER_MANUAL.html) · [繁體中文 HTML 手冊](USER_MANUAL.zh-TW.html)
- [Acceptance test](../MANUAL_TEST.md) · [繁體中文驗收](../MANUAL_TEST.zh-TW.md)
- [Architecture](../ARCHITECTURE.md) · [繁體中文架構](../ARCHITECTURE.zh-TW.md)
- [Security](../SECURITY.md) · [繁體中文安全](../SECURITY.zh-TW.md)
