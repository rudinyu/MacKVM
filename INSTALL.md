[繁體中文](INSTALL.zh-TW.md)

# MacKVM installation guide

This guide installs MacKVM on the target two-Mac setup: a 14-inch Apple
Silicon M5 Pro MacBook Pro connected to a BenQ MA270U over USB-C, and a 2019
16-inch Intel MacBook Pro connected over HDMI.

Source version: **1.102.05 (build 102)**. These instructions describe packaging this
source checkout; they do not identify whether a particular artifact has been
published on GitHub.

## Requirements

- macOS 13 or later on both Macs.
- A trusted local network shared by both Macs.
- Full Xcode with the Swift 6 toolchain on the Mac used to build the app.
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
./scripts/check-environment.sh
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

The default CI command runs the full validation gate and reuses `.build/`.
`./scripts/ci.sh --clean` clears that cache and runs the same full gate;
`./scripts/ci.sh --quick` runs the native Swift suite and focused tooling
fixtures while skipping cross-architecture and Windows SDK checks. Individual
app and diagnostic builds also reuse the cache by default; pass `--clean` for a
cold build. `scripts/clean-build.sh` clears caches while preserving `dist/`,
and `scripts/clean-artifacts.sh` explicitly deletes generated `dist/` files.

## Build the Windows companion

Windows support lives in `WindowsKVM/` and uses C#/.NET 8 rather than Swift.
Build the self-contained x64 (`x86_64`) or ARM64 executable on a Windows host
with the .NET 8 SDK:

```powershell
.\scripts\build-windows.ps1 -Architecture x64
.\scripts\build-windows.ps1 -Architecture arm64
# or publish both in one clean batch
.\scripts\build-windows.ps1 -Architecture both
```

Outputs are written to `dist\windows\x64` and `dist\windows\arm64`. The
script verifies the PE architecture and keeps intermediate .NET state outside
the repository. The Windows UI and tray receiver share MacKVM's signed pairing
and Secure Connect protocol; Windows Defender Firewall should be allowed on
the trusted Private network only. See [WINDOWS_BUILD.md](WINDOWS_BUILD.md) for
publishing, pairing, firewall, and troubleshooting details. The macOS
`scripts/ci.sh` runs the Windows self-tests when .NET 8 is installed; use
`RUN_WINDOWS_CI=1` in required CI environments.

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

Create an app-only universal DMG for local testing:

```sh
./scripts/package-dmg.sh --arch universal
./scripts/verify-release.sh \
  --app dist/universal/MacKVM.app \
  --arch universal
(cd dist && shasum -a 256 -c MacKVM-1.102.05-universal.dmg.sha256)
```

The local-testing app is ad-hoc signed. The DMG contains `MacKVM.app`, an
Applications shortcut, executable `Install MacKVM.command` and
`Uninstall MacKVM.command` helpers, the helper scripts, and separate bilingual
installation and uninstallation guides. No PKG is created. Ad-hoc signatures
are suitable for local testing; use the notarized release command for direct
distribution outside the Mac App Store.

Create a notarytool Keychain profile once; the command prompts for an
app-specific password. The release script reads `MACOS_SIGNING_IDENTITY` and
`MACOS_NOTARY_PROFILE` from `~/.config/codex/notarization.env` (mode `0600`);
complete API-key settings are also supported. The default app-only path needs a
Developer ID Application identity. `--sign`, `--keychain-profile`, and `--auth`
remain available as explicit overrides.

```sh
xcrun notarytool store-credentials "mackvm-notary" \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "YOUR_TEAM_ID"

./scripts/package-notarized-dmg.sh --arch universal
```

The default release path signs the app with Developer ID Application, submits
the app to Apple, staples and verifies its ticket, then places that stapled app
directly in the DMG. It separately signs, submits, staples, and verifies the
DMG. The DMG has its own checksum and submission metadata; app submission
metadata is saved in `dist/` beside the DMG. Use `--timeout` to bound each wait
for Apple; an optional submission log never blocks stapling. Pass `--pkg` only to
opt into the legacy Installer-package layout, which also requires a separate
Developer ID Installer identity. No signing, notarization, or Keychain
credentials belong in this repository.

## Install and grant permissions

The app-only release DMG contains the app, an Applications shortcut, both
Finder command helpers, and bilingual install and uninstall guides. In Finder,
double-click `Install MacKVM.command`, or drag `MacKVM.app` onto the
Applications shortcut. The install helper validates and copies the app to
`/Applications`. Installing or upgrading preserves pairing data, private keys,
preferences, and TCC permission records; the helper does not reset or clear
permissions. Preserved records do not guarantee that macOS authorizes the
current app, so review System Settings if access is unavailable. Quit an
existing MacKVM process before upgrading.

For ordinary removal, quit MacKVM and double-click `Uninstall MacKVM.command`,
or move `MacKVM.app` from Applications to the Trash. This removes only the app
and preserves user data, trust, preferences, and TCC records. If **Launch MacKVM at
Login** was enabled, remove MacKVM from **System Settings > General > Login
Items**. The DMG includes [UNINSTALL.md](UNINSTALL.md) and
[UNINSTALL.zh-TW.md](UNINSTALL.zh-TW.md) for these steps and the optional purge.

After installation, open MacKVM from `/Applications`.

On macOS 27, the privacy permission previously labelled **Accessibility** is
labelled **Device Control and Data Access**. This is inside **Privacy & Security**;
the separate Accessibility category in the System Settings sidebar contains
assistive features and is not the app permission page. The broader permission
can also allow keyboard monitoring, so an absent entry in the Input Monitoring
list alone does not establish that the running app cannot listen to input.
Check MacKVM's reported API results as well as the relevant system settings.

While a MacKVM window or menu is visible, input checks refresh every two seconds,
including while System Settings is in front. The last-checked time shows when
those APIs were queried. After changing Local Network settings, return to
MacKVM or select **Check Local Network Access** to test a fresh connection to
a nearby device. A successful network test verifies that operation; a timeout
can also mean the other device is offline or blocked by a firewall. With no
nearby device, access cannot be confirmed from a peer connection.

Use a Developer ID-signed release when upgrading an installed release. An
ad-hoc development build is not an equivalent signing identity. Keep the app at
`/Applications/MacKVM.app`; do not reset privacy permissions or purge app data
as a routine upgrade step. macOS owns the grant decision, so retaining the
signing identity and records cannot force an existing or revoked grant to apply.

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

## Remove MacKVM and saved data

The DMG includes `Uninstall MacKVM.command` for app-only removal and preserves
saved data by default. The shared `scripts/uninstall-app.sh` helper also has an
explicit destructive `--purge` mode for this macOS user's saved data. Read
[UNINSTALL.md](UNINSTALL.md) before using it. This does not uninstall WindowsKVM
or erase another user's data.

1. Turn off **Launch MacKVM at Login**, if enabled, and quit every running copy
   of MacKVM. The script refuses to purge while MacKVM is running.
2. In Terminal, change to the mounted image's root folder or the repository
   root, then preview the exact actions:

   ```sh
   ./scripts/uninstall-app.sh --purge --dry-run
   ```

3. Run the removal and read its confirmation prompt:

   ```sh
   ./scripts/uninstall-app.sh --purge
   ```

   `--yes` skips the destructive confirmation for unattended use. Add
   `--target-dir "$HOME/Applications"` only if that is where you installed the
   app. Do **not** run the whole script with `sudo`: preferences, Keychain and
   permissions belong to the signed-in user. A narrowly scoped administrator
   prompt may be needed to remove the app from `/Applications`.

Purge removes the app, preferences in `app.mackvm.MacKVM` and
`app.mackvm.device-identity`, and the single Keychain identity item with service
`app.mackvm.device-identity` and account `p256-signing-key`. It asks `tccutil` to
reset permissions for **only** `app.mackvm.MacKVM`, including Accessibility and
Input Monitoring. If present, only `~/Library/Caches/app.mackvm.MacKVM` and
`~/Library/Saved Application State/app.mackvm.MacKVM.savedState` are removed
as app-owned cache and window-state data. It also works when the app has
already been deleted. Check the result of every step: an error does not mean
that cleanup finished. If the identity key cannot be deleted, its identity
preferences are retained to avoid leaving a mismatched identity.

**Deleting the identity key and pairing data cannot be undone by this script.**
After reinstalling, remove the old pairing with **Forget** on the other devices
and pair again. Downloaded installers, repository/build files, other apps and
user-exported debug logs are not removed.

Some system entries still need manual attention:

- **Local Network:** turn off MacKVM in **System Settings > Privacy & Security >
  Local Network** if listed. Apple documents that macOS cannot reset this
  permission to the undetermined state; `tccutil` does not provide a complete
  reset. See [Apple's Local Network privacy guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).
- **Login Items:** remove or disable any remaining MacKVM entry in **System
  Settings > General > Login Items**. The script does not reset the shared
  background-item database.
- **Notifications:** turn off any remaining MacKVM entry in **System Settings >
  Notifications**. Historical shared system logs are retained.
- **Firewall:** optionally run the purge with `--remove-firewall-rule` to request
  removal of the Apple application-firewall rule for the exact installed app
  path. This option requires the app to still be present and validated; on
  failure the script keeps the app and data for retry. It may require an
  administrator password. Otherwise remove that
  app's rule manually; third-party rules such as Little Snitch are always a
  manual step. No global firewall settings are changed.

## Configure the monitor and input path

1. Connect the M5 Pro to the MA270U USB-C video/data port.
2. Connect the Intel Mac to HDMI 1, or use HDMI 2 consistently in both input
   pickers if that is the chosen port.
3. Set the MA270U as the main display on both Macs.
4. On either Mac, select **Detect DDC-capable displays** and choose the
   intended external display explicitly, then select the matching preset.
5. On the M5 Pro, **M5 / USB-C preset** selects logical USB-C locally and HDMI
   1 (VCP 17) on the other device. The MA270U EDID mapping sends USB-C as VCP 19
   (`0x13`); on other models use the diagnostic scan. On the Intel Mac,
   **Intel / HDMI preset** selects HDMI 1 locally and keeps native DDC enabled.
   A fresh Intel install uses HDMI 1 as its local default; use the preset to
   migrate an older saved USB-C preference. Input values are monitor-firmware
   specific.
6. Select **One keyboard on M5 Pro (USB-C)** when the external keyboard and
   mouse are connected to the M5 Pro or the MA270U USB hub. HDMI does not carry
   USB data to the Intel Mac, but either Mac can still request control from its
   own keyboard, mouse, and trackpad.
7. Use **Show other device** to verify switching. Some MA270U firmware has no
   DDC/CI OSD toggle; if native detection fails, use the diagnostic text,
   check the direct cable path, and switch inputs through the MA270U OSD.
   For a display-only route, use **Return display to this Mac**. Returning
   control with the emergency shortcut or the receiver's
   **Return keyboard, mouse, and trackpad to [other device]** action restores the
   local route. On either Mac, **Show other device** also starts the guarded
   keyboard, mouse, and trackpad hand-off when the control prerequisites are
   ready. **Share keyboard, mouse, and trackpad with [other device]** remains the
   explicit equivalent; the receiver selects **Allow** unless seamless control
   was enabled for the paired peer.

Select **External USB switch (bidirectional)** only after both Macs visibly see
the external keyboard and mouse through a real physical USB switch. This setting
describes external USB wiring; it does not disable local keyboard, mouse, or
trackpad control on either Mac.

## Pair and control the Macs

1. After the Local Network step is complete, open the MacKVM menu on both Macs.
2. Under **Nearby devices**, select **Pair** on one device.
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
6. On either Mac, select **Share keyboard, mouse, and trackpad with [other device]**.
   This switches the MA270U to the other device when DDC is configured and then
   starts the keyboard, mouse, and trackpad control request.
7. A newly paired receiver automatically enables seamless control for that
   pinned peer. To keep per-request consent, turn off **Automatically allow
   control from this Mac** under **Paired device information**. When it is off,
   select **Allow** on the receiving Mac; a closed menu can use the native
   Allow/Deny/Review notification, and Review opens the MacKVM approval dialog.
8. Either Mac can interrupt at any time with
   `Control-Option-Command-Escape`. To switch back from Intel, select
   **Return keyboard, mouse, and trackpad to [other device]** on the receiving
   Mac. The controller can also select **Return keyboard, mouse, and trackpad
   to this Mac**. The global `Control-Option-Command-K` shortcut toggles
   keyboard, mouse, and trackpad ownership after
   you manually select the monitor input; it starts a request when idle and
   returns input when controlling or receiving, without running automatic DDC
   switching. `Control-Option-Command-O` follows the guarded **Show other device**
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

Select **Forget** to revoke a paired Mac. The paired row and the status beside
**Quit** update immediately to **Pairing forgotten**; the old peer name must not
remain, and restarting MacKVM is not required.

Select **Copy support information** when reporting a problem. The report
contains public version, OS, device, fingerprint, and connection-status data;
it excludes private keys, passwords, credentials, and network endpoints.

## More documentation

- [Architecture](ARCHITECTURE.md) · [繁體中文架構](ARCHITECTURE.zh-TW.md)
- [Acceptance test](MANUAL_TEST.md) · [繁體中文驗收](MANUAL_TEST.zh-TW.md)
- [Security status](SECURITY.md) · [繁體中文安全說明](SECURITY.zh-TW.md)
- [English HTML manual](docs/USER_MANUAL.html) · [Traditional Chinese HTML manual](docs/USER_MANUAL.zh-TW.html)
- [English Markdown manual](docs/USER_MANUAL.md) · [Traditional Chinese Markdown manual](docs/USER_MANUAL.zh-TW.md)
