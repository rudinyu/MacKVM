# MacKVM

MacKVM is a native macOS menu bar app for sharing one keyboard, mouse, and
monitor between two Macs on the same local network.

The current MVP provides:

- a native high-resolution app icon and an always-visible keyboard icon in the
  macOS menu bar while MacKVM is running; it adds a warning symbol for a
  pending incoming control request;
- a persistent local device identity;
- Bonjour discovery on the local network;
- signed pairing requests that must be accepted on the receiving Mac;
- a six-digit device-key verification code;
- persistent public-key pinning for paired devices;
- a persistent authenticated session using signed ephemeral P-256 key exchange,
  directional HKDF keys, ChaChaPoly encryption, and replay-protected counters.
- validated keyboard, mouse, and scroll event forwarding over that encrypted
  session;
- a sequential Local Network, Input Monitoring, and Accessibility setup
  checklist that prevents overlapping macOS permission prompts and refreshes
  when MacKVM becomes active again;
- an optional **Launch MacKVM at Login** setting;
- injected-event marking that prevents input feedback loops;
- explicit Allow/Deny control consent on the receiving Mac, deterministic
  collision handling, and a receiver-side stop action;
- explicit physical-input topology modes that prevent the HDMI-only Intel Mac
  from claiming bidirectional input unless an external USB switch is present;
- network-path monitoring with bounded automatic reconnect after Wi-Fi,
  sleep/wake, or peer-service interruptions;
- keyboard-layout and control-protocol compatibility checks before consent,
  with a safe identity-reset path when the local Keychain identity is damaged;
- native macOS incoming-control notifications with Allow, Deny, and Review
  actions, so the receiver can respond while the menu is closed;
- local input suppression while controlling and an emergency
  `Control-Option-Command-Escape` return shortcut;
- configurable BenQ MA270U input switching through `m1ddc`, including display
  discovery, stable display-ID selection, DDC diagnostics, and a manual OSD
  fallback.

## Requirements

- macOS 13 or later
- Swift 6 toolchain (Xcode is preferred when installed)
- `m1ddc` on the Apple Silicon Mac for automatic monitor switching (optional)

Install the optional DDC helper on the M5 Pro Mac:

```sh
brew install m1ddc
```

The upstream tool supports external displays connected to Apple Silicon by
USB-C/DisplayPort Alt Mode, but not Intel Macs. MacKVM therefore keeps manual
MA270U OSD switching available at all times.

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

Create a disk image after building. The default is a universal DMG with an
ad-hoc signature for local testing:

```sh
./scripts/package-dmg.sh --arch universal
```

The package is built from a fresh staging directory and writes a portable
SHA-256 sidecar next to the DMG. Verify the pair from the `dist` directory:

```sh
(cd dist && shasum -a 256 -c MacKVM-0.6.1-universal.dmg.sha256)
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

Run the Swift test suite before packaging:

```sh
swift test
```

The app bundle is the supported launch path because it contains the Bonjour
and Local Network privacy metadata required by macOS. Run it on both Macs while
they are connected to the same local network. For pointer mapping, set the
MA270U as the main display on both Macs.

Before the first launch, copy the matching app into `/Applications`. MacKVM
appears as a keyboard icon in the menu bar rather than as a regular Dock app.
Open that menu and complete **Set up this Mac** on each computer:

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

The menu follows the Mac's language and includes English and Traditional
Chinese resources. The three required macOS permission descriptions are also
localized; if macOS does not show a prompt after a previous denial, use the
matching **Settings** shortcut instead.

In the MacKVM menu:

1. Under **Physical input path**, keep **One keyboard on M5 Pro (USB-C)** for
   the current wiring. Connect the keyboard and mouse to the M5 Pro directly
   or through the MA270U USB hub. HDMI carries video only, so the Intel Mac
   cannot originate a control request in this mode. If both Macs really see
   the devices through an external USB switch, select **External USB switch
   (bidirectional)** on both Macs and test both directions first.
2. On the M5 Pro Mac, select **Detect MA270U** and choose the detected display
   explicitly identified as **MA270U**. MacKVM saves its stable m1ddc
   identifier rather than assuming display number 1; an unrecognized display
   cannot enable automatic switching.
3. On the M5 Pro Mac, select **M5 / USB-C preset**. This sets this Mac to
   USB-C (VCP 27), the other Mac to HDMI 1 (VCP 17), and enables DDC.
4. On the 2019 Intel Mac, select **Intel / HDMI preset**. This sets the local
   route to HDMI 1 and keeps automatic DDC off.
5. If the Intel Mac uses HDMI 2, change both matching input pickers to HDMI 2.
6. Use **Show this Mac** and **Show other Mac** to verify switching before
   starting remote control. If it fails, read the **DDC diagnostic**, enable
   DDC/CI in the MA270U OSD, and use the OSD input menu as the fallback.

When one Mac selects **Request control of other Mac**, the receiving Mac must
select **Allow** or **Deny**. If its MacKVM menu is closed, macOS shows a
native notification with **Allow**, **Deny**, and **Review in MacKVM** instead.
**Review in MacKVM** opens an explicit Allow/Deny dialog. Each action is checked
against the live request ID and a fresh device-local notification nonce, so an
expired notification cannot start control. **Allow** requires macOS
authentication when the receiver is locked. Only the explicit **Enable** setup
action can show the optional macOS notification-permission prompt; otherwise
MacKVM falls back to a visible menu-bar warning and the menu controls. It can always
select **Stop remote control** to release
injected keys/buttons and return control locally. If macOS notifications are
disabled, its keyboard menu-bar icon shows a warning symbol and the same
request remains in the menu.

After an authenticated transport loss, MacKVM releases local input immediately
and retries the last user-selected peer with a bounded 0/1/2/4…30-second
backoff. A deliberate **Disconnect**, **Forget**, or **Quit** clears that
reconnect intent. Pairing is not repeated, but control consent must be granted
again after a reconnect. If the keyboard layout changes while control is live,
the receiver stops remote input and asks both users to choose the same macOS
input source before trying again.

If the app cannot load its Keychain identity, the error view offers **Reset this
Mac identity**. Use it only after confirming that the old identity should be
discarded; it removes local pairings, and the next launch requires pairing both
Macs again.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the current architecture, known
issues, wiring diagram, and MVP usage instructions.
See [`MANUAL_TEST.md`](MANUAL_TEST.md) for the complete two-Mac hardware
acceptance checklist.
See [`docs/USER_MANUAL.html`](docs/USER_MANUAL.html) for the end-user
Traditional Chinese manual that can be opened directly in a browser.

## 中文說明

MacKVM 是 macOS 選單列應用程式，讓兩台 Mac 在同一個區域網路中共用一組
鍵盤、滑鼠與螢幕。配對與控制都需要兩台 Mac 明確同意；控制資料會透過
加密連線傳送。

### 建置與打包

建議在 M5 Pro Apple Silicon Mac 上執行：

```sh
# 建立 Apple Silicon 版本
./scripts/build-app.sh --arch arm64

# 建立 2019 Intel Mac 可用的 x86_64 版本
./scripts/build-app.sh --arch x86_64

# 建立同時支援兩種架構的 DMG
./scripts/package-dmg.sh --arch universal
```

產物會放在 `dist/`。本機測試版本使用 ad-hoc signature；若要提供給其他
Mac 正式安裝，請使用 Developer ID Application identity、啟用 hardened
runtime，並在發佈前完成 Apple notarization。

### 你的硬體接法

- M5 Pro MacBook Pro：USB-C 連接 BenQ MA270U。
- 2019 Intel MacBook Pro：透過 USB-C/Thunderbolt 3 轉 HDMI 連接螢幕。
- 鍵盤與滑鼠：接在 M5 Pro 或 MA270U USB hub；HDMI 不會傳送 USB hub。
- 螢幕切換：M5 Pro 使用 USB-C preset，Intel Mac 使用 HDMI preset。

### 第一次使用

1. 在兩台 Mac 安裝並啟動 `MacKVM.app`。
2. 依畫面提示授予 Local Network、Input Monitoring 與 Accessibility 權限。
3. 在 **Nearby Macs** 找到另一台 Mac，兩邊都按 **Pair**，核對六位數驗證碼。
4. 配對完成後，在 M5 Pro 按 **Request control**，另一台 Mac 按 **Allow**。
5. 若需要自動切換 MA270U 輸入，先在 M5 Pro 安裝 `m1ddc`：

   ```sh
   brew install m1ddc
   ```

6. 若通知被關閉，仍可從選單列鍵盤圖示查看並處理控制請求。

完整的繁體中文操作與硬體驗收步驟，請參考
[`docs/USER_MANUAL.html`](docs/USER_MANUAL.html) 與
[`MANUAL_TEST.md`](MANUAL_TEST.md)。

## Recommended wiring

- Apple Silicon MacBook Pro: USB-C to the BenQ MA270U
- Intel 2019 MacBook Pro: USB-C/Thunderbolt 3 to HDMI
- Keyboard and mouse: connect to the M5 Pro directly or through the MA270U
  USB hub. HDMI does not carry the monitor hub upstream to the Intel Mac.

This is a one-way physical input topology: the M5 Pro can request control of
the Intel Mac, while the Intel Mac can receive control. Select the app's
**External USB switch (bidirectional)** mode only when a real USB switch makes
the devices visible to both Macs.

This keeps DDC/CI communication on the more reliable USB-C connection.

The input values and command syntax follow the
[m1ddc project documentation](https://github.com/waydabber/m1ddc). BenQ lists
two HDMI 2.0 ports and one USB-C video/data/90 W port in the
[MA270U specifications](https://www.benq.com/en-us/monitor/home/ma270u/spec.html).
