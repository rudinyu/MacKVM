[繁體中文](CHANGELOG.zh-TW.md)

# Changelog

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
