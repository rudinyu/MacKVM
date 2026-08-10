[繁體中文](INSTALL.zh-TW.md) · [README](README.md)

# MacKVM installation guide

This guide installs MacKVM on the target two-Mac setup: a 14-inch Apple
Silicon M5 Pro MacBook Pro connected to a BenQ MA270U over USB-C, and a 2019
16-inch Intel MacBook Pro connected over HDMI.

## Requirements

- macOS 13 or later on both Macs.
- A trusted local network shared by both Macs.
- Swift 6 toolchain or Xcode on the Mac used to build the app.
- Optional: `m1ddc` on Apple Silicon for automatic MA270U input switching.

Install the optional DDC helper:

```sh
brew install m1ddc
```

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

Create and verify a universal DMG for local testing:

```sh
./scripts/package-dmg.sh --arch universal
./scripts/verify-release.sh \
  --app dist/universal/MacKVM.app \
  --arch universal
(cd dist && shasum -a 256 -c MacKVM-0.7.0-universal.dmg.sha256)
```

Ad-hoc signing is suitable only for local testing. For distribution to
another Mac, use a Developer ID Application identity, require the hardened
runtime, and complete Apple notarization:

```sh
./scripts/package-dmg.sh \
  --arch universal \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  --require-developer-id
```

No signing, notarization, or Keychain credentials belong in this repository.

## Install and grant permissions

1. Copy the matching app bundle to `/Applications` on each Mac and open it.
2. Select **Enable Local Network**, respond to the macOS prompt, then select
   **I handled the macOS prompt**.
3. Select **Request Input Monitoring** and grant the permission.
4. Select **Request Accessibility** and grant the permission.
5. If a permission was previously denied, use the matching **Settings** button.
6. Optionally select **Enable** beside **Control request notifications** before
   the first control request.
7. Optionally enable **Launch MacKVM at Login**.

MacKVM appears as a keyboard icon in the menu bar rather than as a Dock app.
The app bundle, rather than `swift run`, is required because it contains the
Bonjour and Local Network privacy metadata.

## Configure the monitor and input path

1. Connect the M5 Pro to the MA270U USB-C video/data port.
2. Connect the Intel Mac to HDMI 1, or use HDMI 2 consistently in both input
   pickers if that is the chosen port.
3. Set the MA270U as the main display on both Macs.
4. On the M5 Pro, select **Detect MA270U**, choose the verified MA270U display,
   then select **M5 / USB-C preset**.
5. On the Intel Mac, select **Intel / HDMI preset**.
6. Select **One keyboard on M5 Pro (USB-C)** when the keyboard and mouse are
   connected to the M5 Pro or the MA270U USB hub. HDMI does not carry USB data.
7. Use **Show this Mac** and **Show other Mac** to verify switching. If DDC/CI
   fails, use the diagnostic text and switch inputs through the MA270U OSD.

Select **External USB switch (bidirectional)** only after both Macs visibly see
the keyboard and mouse through a real physical USB switch.

## Pair and control the Macs

1. After the Local Network step is complete, open the MacKVM menu on both Macs.
2. Under **Nearby Macs**, select **Pair** on one Mac.
3. Compare the six-digit security code and peer name on both Macs.
4. Select **Accept** on both Macs only when the codes match.
5. Select **Connect** on either Mac.
6. On the controlling Mac, select **Request control of other Mac**.
7. On the receiving Mac, select **Allow**. A closed menu can use the native
   Allow/Deny/Review notification; Review opens the MacKVM approval dialog.
8. End control with **Return input to this Mac**, **Stop remote control**, or
   `Control-Option-Command-Escape`.

After a transport loss, MacKVM reconnects with bounded backoff but requires a
new control consent. **Disconnect**, **Forget**, and **Quit** clear reconnect
intent.

## Device profiles and support information

Under **Paired device information**, edit and save a friendly name. MacKVM
retains the name, advertised model, last authenticated connection time, and
the SHA-256 fingerprint of the pinned public key across relaunches.

Select **Copy support information** when reporting a problem. The report
contains public version, OS, device, fingerprint, and connection-status data;
it excludes private keys, passwords, credentials, and network endpoints.

## More documentation

- [Architecture](ARCHITECTURE.md) · [繁體中文架構](ARCHITECTURE.zh-TW.md)
- [Acceptance test](MANUAL_TEST.md) · [繁體中文驗收](MANUAL_TEST.zh-TW.md)
- [Security status](SECURITY.md) · [繁體中文安全說明](SECURITY.zh-TW.md)
- [English HTML manual](docs/USER_MANUAL.html) · [Traditional Chinese HTML manual](docs/USER_MANUAL.zh-TW.html)
- [English Markdown manual](docs/USER_MANUAL.md) · [Traditional Chinese Markdown manual](docs/USER_MANUAL.zh-TW.md)
