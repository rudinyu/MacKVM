[繁體中文](CHANGELOG.zh-TW.md)

# Changelog

## 1.02.02 (build 82) — 2026-08-27

This patch closes the remaining review findings around network recovery,
keyboard-layout transitions, release documentation, and regression coverage.

### Fixed

- Stop Bonjour recovery after five scheduled attempts; readiness callbacks from
  both Bonjour services reset the bounded backoff cycle.
- Fail closed for remappable captured key-down events while the Carbon layout
  snapshot is stale, including matching repeats and key-ups.
- Align installation, manual, and component documentation with the current W3
  feature set and the 1.02.02/build 82 release artifacts.

### Tests

- Add deterministic tests for the retry limit/backoff policy and stale-layout
  capture behavior.

## 1.02.01 (build 81) — 2026-08-26

This release aligns the Windows W3 receiver with the current macOS secure-session
contract and brings the corresponding macOS lifecycle fixes into the Windows
development branch.

### Added

- Sign and validate the `disconnectSignalVersion` secure-session capability as
  a separate handshake extension on both platforms.
- Exchange authenticated encrypted disconnect and acknowledgement markers so a
  deliberate close does not fall back to ambiguous EOF teardown.
- Add Windows protocol self-tests for capability round-trips and exact control
  signal matching.
- Sync the macOS secure-session sleep/wake, disconnect policy, input topology,
  trackpad scroll, and protocol tests required by the current Mac build line.

### Fixed

- Keep Windows authenticated input sessions alive with a rolling per-second
  packet/byte budget instead of a cumulative 256-packet cap.
- Correct Apple function/navigation/keypad mappings for Windows `SendInput`,
  including End, PageUp/PageDown, Forward Delete, and F1–F20.
- Preserve scroll unit, phase, momentum, and pointer-pressure metadata across
  the Windows protocol; pixel scroll no longer becomes a full 120-unit wheel.
- Synchronize Windows hotkey teardown state and require both secure Bonjour
  services to report `.ready` before resetting network recovery backoff.
- Use a notification-driven macOS forward keyboard-layout cache so Carbon is
  not queried for every captured keyDown.

### Compatibility

- Signed pairing remains compatible with MacKVM 1.00.00 and later.
- Secure Connect requires MacKVM 1.100.00/build 75 or later; older peers are
  rejected with an explicit upgrade-required error.

## 1.01.02 (build 79) — 2026-08-26

This patch documents the Windows W2 deliverable and aligns the reported
application version across the macOS and Windows build metadata.

### Documentation

- Add English and Traditional Chinese WindowsKVM component READMEs covering
  secure Connect, trust storage, compatibility, build, and test steps.
- Link the component READMEs from the root project documentation.

## 1.01.01 (build 78) — 2026-08-26

This patch hardens the Windows W2 secure-session responder after review.

- Rate-limit unauthenticated secure-session connection attempts so idle TCP
  clients cannot starve the eight active handshake slots.
- Drain coalesced encrypted frames in bounded batches instead of disconnecting
  when one read contains more than 16 frames.
- Serialize ECDSA signing across pairing and secure-session responders.
- Make Windows trust recording transactional and persist it before sending the
  final pairing-completion frame.
- Expire partial post-authentication frames after five seconds and surface
  unexpected mDNS/listener task failures to the console entry point.

## 1.01.00 (build 77) — 2026-08-26

This feature release adds the Windows W2 secure Connect responder while
keeping the signed pairing protocol compatible with MacKVM 1.00.00.

### Added

- Advertise a separate `_mackvm-secure._tcp` service and accept only Mac
  public identities recorded by the completed pairing flow.
- Complete the signed ephemeral P-256 handshake, derive directional
  HKDF-SHA256 keys, and verify the ChaCha20-Poly1305 encrypted key
  confirmation with replay-checked sequence numbers.
- Persist Windows paired Mac public identities atomically under
  `%LOCALAPPDATA%\MacKVM\trusted-peers.json`; changed keys are rejected.
- Add protocol self-tests for cross-direction encryption, replay rejection,
  and tampered handshakes.

### Limitations

- Windows Raw Input/SendInput, encrypted control-message handling, tray UI,
  global hotkeys, and the final firewall UX are not enabled in this build.

## 1.00.02 (build 76) — 2026-08-25

This patch makes the Windows console pairing flow observable and reliable.

### Fixed

- Do not use the stale `TcpClient.Connected` snapshot to decide whether to
  read an accepted pairing connection; rely on `ReadAsync` EOF/error results.
- Show the incoming peer, verification code, and an explicit **Accept pairing?**
  prompt in the Windows CLI, and log each received pairing frame and rejection
  reason to make firewall and transport troubleshooting actionable.

## 1.00.01 (build 75) — 2026-08-25

This patch hardens the Windows pairing scaffold and local validation.

### Fixed

- Serialize first-run Windows identity creation so concurrent receiver starts
  cannot overwrite each other's credentials.
- Advertise both reachable mDNS address families, support IPv6-only local
  networks, and keep local macOS CI usable when the optional .NET SDK is absent.
- Keep the Windows protocol compatible with MacKVM 1.00.00 while retaining
  bounded, secure pairing behavior.

## 1.00.00 (build 74) — 2026-08-24

This is the first formal MacKVM release. It includes the complete secure
pairing, native cross-architecture DDC/CI, keyboard/mouse hand-off, recovery,
and permission-aware control workflow delivered through the 0.12.x series.

### Fixed

- Keep `Control-Option-Command-K` as the keyboard/mouse control toggle for a
  monitor input selected manually. It no longer starts the display-first DDC
  route; `Control-Option-Command-O` remains the automatic display-plus-input
  hand-off shortcut.

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
