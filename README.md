# MacKVM

MacKVM is a native macOS menu bar app for sharing one keyboard, mouse, and
monitor between two Macs on the same local network.

The current MVP provides:

- a persistent local device identity;
- Bonjour discovery on the local network;
- signed pairing requests that must be accepted on the receiving Mac;
- a six-digit device-key verification code;
- persistent public-key pinning for paired devices;
- a persistent authenticated session using signed ephemeral P-256 key exchange,
  directional HKDF keys, ChaChaPoly encryption, and replay-protected counters.
- validated keyboard, mouse, and scroll event forwarding over that encrypted
  session;
- Input Monitoring and Accessibility permission controls;
- injected-event marking that prevents input feedback loops;
- request/grant control ownership with deterministic collision handling;
- local input suppression while controlling and an emergency
  `Control-Option-Command-Escape` return shortcut;
- configurable BenQ MA270U input switching through `m1ddc`, with a clear
  manual OSD fallback.

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

## Build and run the macOS app

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

The app bundle is the supported launch path because it contains the Bonjour
and Local Network privacy metadata required by macOS. Run it on both Macs while
they are connected to the same local network. For pointer mapping, set the
MA270U as the main display on both Macs.

In the MacKVM menu:

1. On the M5 Pro Mac, select **M5 / USB-C preset**. This sets this Mac to
   USB-C (VCP 27), the other Mac to HDMI 1 (VCP 17), and enables DDC.
2. On the 2019 Intel Mac, select **Intel / HDMI preset**. This sets the local
   route to HDMI 1 and keeps automatic DDC off.
3. If the Intel Mac uses HDMI 2, change both matching input pickers to HDMI 2.
4. Use **Show this Mac** and **Show other Mac** to verify switching before
   starting remote control. If it fails, enable DDC/CI in the MA270U OSD and
   use the OSD input menu as the fallback.

## Validate

Run local CI after every code change:

```sh
./.codex/ci.sh
```

CI builds, tests, and packages both arm64 and x86_64 app bundles.

Run Codex CI and code review after each complete plan step:

```sh
./.codex/step-review.sh
```

After every plan step is complete, run the final Claude reviewer:

```sh
./.codex/final-review.sh
```

See [`.codex/WORKFLOW.md`](.codex/WORKFLOW.md) for the full development policy.
See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the current architecture, known
issues, wiring diagram, and MVP usage instructions.
See [`MANUAL_TEST.md`](MANUAL_TEST.md) for the complete two-Mac hardware
acceptance checklist.

## Recommended wiring

- Apple Silicon MacBook Pro: USB-C to the BenQ MA270U
- Intel 2019 MacBook Pro: USB-C/Thunderbolt 3 to HDMI

This keeps DDC/CI communication on the more reliable USB-C connection.

The input values and command syntax follow the
[m1ddc project documentation](https://github.com/waydabber/m1ddc). BenQ lists
two HDMI 2.0 ports and one USB-C video/data/90 W port in the
[MA270U specifications](https://www.benq.com/en-us/monitor/home/ma270u/spec.html).
