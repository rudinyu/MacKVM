[繁體中文](CHANGELOG.zh-TW.md)

# Changelog

## Unreleased

## 1.100.06 (build 81) — 2026-09-13

### Added

- Include double-click install and uninstall commands plus the installation
  guides in the DMG. The scripts validate the MacKVM bundle and preserve
  pairing data, private keys, preferences, and macOS privacy permissions.

### Fixed

- Preserve fractional trackpad scrolling and terminate active scroll and
  momentum phases during teardown; release held media keys and preserve
  keyboard auto-repeat state.
- Use the correct Carbon no-dead-key option and keep manual
  `Control-Option-Command-K` sessions from restoring the display route after
  transport loss.
- Add an authenticated application heartbeat lease so a peer that sleeps or
  stops servicing MacKVM is cleared even when its TCP socket remains open;
  both Macs must use the current secure-session capability.

## 1.100.05 (build 80) — 2026-09-07

### Fixed

- Give pairing's Accept and Confirm steps a separate bounded user-decision
  timeout, while retaining shorter deadlines for the pre-authentication
  transport phases.
- Ignore duplicate reveal and confirmation frames after a contribution has
  already been recorded, preventing an unpaired request from extending its
  slot indefinitely.

## 1.100.04 (build 79) — 2026-09-04

### Added

- Add a separate Developer ID release script that signs the app and DMG,
  submits the DMG to Apple's notary service, staples the accepted ticket, and
  regenerates the final checksum without storing credentials in the repository.

### Changed

- Require a secure timestamp whenever a Developer ID signing identity is used,
  while keeping the default local packaging path ad-hoc signed.

## 1.100.03 (build 78) — 2026-09-04

### Fixed

- Detect authenticated secure-session loss even when the peer has no local
  keyboard or mouse, using bounded TCP keepalive and transport-viability
  handling. Stale sessions are cleared so the selected peer can reconnect
  without a manual **Disconnect** action.

## 1.100.02 (build 77) — 2026-08-31

### Fixed

- Ending a `Control-Option-Command-K` session — by K, Escape, or the peer's
  return action — no longer fires a DDC switch. The manual-monitor session is
  now tracked as not owning the display route, so only the plain and combined
  (`Control-Option-Command-O`) routes restore the local display when control
  ends, matching the documented K contract of moving input only.
- Extend the manual acceptance path to test the controller-side second
  `Control-Option-Command-O` press when only the shared keyboard is attached,
  while documenting that the receiver-side hotkey test requires a physical
  keyboard on the receiver.

## 1.100.01 (build 76) — 2026-08-26

This patch release hardens cross-Mac input and secure-session teardown after
the 1.100.00 release.

### Fixed

- Keep horizontal and vertical scroll deltas consistent with the single unit
  carried by the remote-input protocol, including tilt-wheel events.
- Clamp reported pointer pressure instead of dropping events that could leave
  a remote button state unmatched.
- Preserve reconnect intent when pairing completion races an in-flight
  handshake, and keep explicit disconnects from restarting a close in flight.
- Suppress automatic reconnect after an explicit disconnect even when the
  selected peer has already been cleared.

## 1.100.00 (build 75) — 2026-08-26

This release completes the local keyboard, mouse, and trackpad sharing path
for both Apple Silicon and Intel Macs, while retaining the documented external
USB wiring requirements.

### Fixed

- Forward trackpad-compatible pointer input, including clicks, secondary
  clicks, drag pressure when available, high-resolution two-axis scrolling,
  scroll phase, momentum, and line/pixel units.
- Allow either Mac to originate local keyboard, mouse, and trackpad control;
  the physical USB switch topology remains separately validated when external
  devices must be shared.
- Keep sleep/wake teardown and explicit disconnect handling from leaving the
  peer session or Hotkey path stuck.

## 1.00.00 (build 74) — 2026-08-24

This is the first formal MacKVM release. It includes the complete secure
pairing, native cross-architecture DDC/CI, keyboard/mouse hand-off, recovery,
and permission-aware control workflow delivered through the 0.12.x series.

### Fixed

- Keep `Control-Option-Command-K` as the keyboard/mouse control toggle for a
  monitor input selected manually. It no longer starts the display-first DDC
  route; `Control-Option-Command-O` remains the automatic display-plus-input
  hand-off shortcut.
- Close the secure transport before system sleep and restore the selected peer
  after wake, so the other Mac releases remote input and Hotkey switching does
  not remain blocked by a half-open session.

## 0.12.31 (build 71) — 2026-08-24

This release collects the reliability, display-routing, and control-flow fixes
made since the v0.12.4 release, and makes the pairing workflow easier to
understand during an active request.

### Pairing and control

- Keep pairing progress, an incoming **Accept** request, and the initiator's
  **Confirm code** action in one top-level menu section. The confirmation is no
  longer separated below unrelated monitor and peer sections, so the two-step
  pairing flow is visible while it is waiting for the next action.
- Harden pairing completion and timeout handling, including request/peer/
  generation matching and persistence before a session is considered paired.
- Make the `Control-Option-Command-O` display-first shortcut use the same
  protected hand-off and local-return behavior as **Show other Mac**.
- Improve keyboard/mouse return paths, emergency hotkeys, input release after
  event-creation failures, and control-request feedback.

### Reliability and display support

- Add bounded network-service recovery with readiness-aware backoff reset and
  preserve the selected display route across hot-plug refreshes.
- Keep onboarding state synchronized between the menu-bar scene and the main
  window, and distinguish launch-at-login approval from an enabled state.
- Validate modifier flags, prevent duplicate admission releases, and reject
  invalid peer arbitration inputs.
- Continue using native DDC/CI on Apple Silicon (`IOAVService`) and Intel
  (`IOI2C`), with cross-architecture diagnostics and safer display selection.

### Documentation and verification

- Synchronize the app version, build number, DMG checksum filenames, roadmap,
  and English/Traditional Chinese HTML and Markdown documentation.
- Local CI passed all 268 tests and built both arm64 and x86_64 app bundles.
