[繁體中文](CHANGELOG.zh-TW.md)

# Changelog

## WindowsKVM 1.02.27 (build 107) — 2026-09-15

This Windows-only maintenance release makes every direct Windows or macOS
build start from clean generated state, so stale binaries cannot remain in the
default `dist` output.

### Changed

- Clean SwiftPM/Clang build state and the repository `dist` directory before a
  direct macOS app or native DDC diagnostic build.
- Clean the Windows `dist` output and temporary publish state before each
  `build-windows.ps1` invocation; publishing both architectures still keeps
  both outputs in the same batch.
- Add an explicit `--no-clean` option for macOS scripts used only by CI and
  multi-architecture wrapper flows after their one initial clean.

### Validation

- Clean-build behavior is exercised by the normal CI build sequence; Windows
  protocol and desktop self-tests remain required when the .NET 8 SDK is
  available.

## WindowsKVM 1.02.26 (build 106) — 2026-09-15

This Windows-only terminology update makes the device selector accurate for
Mac, Windows, and future peers.

### Changed

- Rename the Advanced-mode **Nearby Macs** section to **Nearby devices**;
  trusted peers are no longer described as Mac-only.
- Keep the English and Traditional Chinese Windows documentation aligned with
  the new label and bump the UI build metadata to 1.02.26 (build 106).

### Validation

- Windows x64/ARM64 cross-builds and the existing desktop self-test remain
  required; native DPI rendering still needs acceptance on a Windows desktop.

## WindowsKVM 1.02.25 (build 105) — 2026-09-14

This Windows-only UI refinement makes the default Simple mode fit in one
viewport and reduces typography in both views for a denser, more readable
status panel.

### Changed

- Compact the Simple layout and its action rows so the normal 520x480 window
  can show all essential setup, pairing, control, and input-path information
  without mouse-wheel scrolling.
- Reduce title, section, body, caption, and monospace font sizes consistently
  in Simple and Advanced modes while preserving the existing responsive
  reflow for narrow displays.

### Validation

- Windows x64/ARM64 cross-builds and the existing desktop self-test remain
  required; native DPI rendering still needs acceptance on a Windows desktop.

## WindowsKVM 1.02.24 (build 104) — 2026-09-14

This Windows-only UI polish makes Advanced mode narrower and gives the
resident status window a consistent, restrained visual style.

### Changed

- Reduce the Advanced canvas and reflow its status, input-path, pairing, and
  action rows so the detailed view fits comfortably on laptop displays.
- Replace the legacy white/static-control contrast with a slate background,
  softer separators, and accessible primary, secondary, success, and warning
  text colors.
- Enable the native Windows common-controls visual style for buttons,
  checkboxes, and combo boxes while preserving the existing Win32 behavior.

### Validation

- Windows x64/ARM64 cross-builds and the existing desktop self-test remain
  required; native DPI rendering still needs acceptance on a Windows desktop.

## WindowsKVM 1.02.23 (build 103) — 2026-09-14

This Windows-only UI fix keeps the live Advanced-mode status readable after
the receiver starts. Runtime details now stay within three explicit lines so
the status row is not covered by overflowing endpoint or fingerprint text.

### Fixed

- Keep version, model, device ID, and TCP endpoint details in a bounded header
  block. The complete key fingerprint remains in **Paired device information**
  and **Copy support information**.
- Prevent the live `Remote keyboard and mouse input enabled.` status from
  being clipped or overwritten when the receiver updates its ports.

### Validation

- Windows x64/ARM64 cross-builds and the existing desktop self-test remain
  required; native DPI rendering still needs acceptance on a Windows desktop.

## WindowsKVM 1.02.22 (build 102) — 2026-09-14

This Windows-only UI fix prevents the local key fingerprint in **Paired
device information** from being clipped or overwritten on Advanced-mode
windows. The fingerprint is rendered as explicit, DPI-tolerant lines and the
following controls are reflowed below it. macOS sources, macOS version
metadata, and the wire protocol are unchanged.

### Fixed

- Wrap the SHA-256 fingerprint at deterministic boundaries and allocate enough
  native label height so the complete value remains readable instead of being
  covered by the DPAPI support note.
- Keep the Advanced content height and section separator aligned with the
  expanded fingerprint block.

### Validation

- Cross-platform tests and Windows x64/ARM64 builds remain required; native
  Windows DPI rendering still needs desktop acceptance on the target display.

## WindowsKVM 1.02.21 (build 101) — 2026-09-14

Windows-only UI fixes following desktop testing of **1.02.09 (build 89)
Beta 3**. This build also includes the subsequent fixes listed below; macOS
version metadata and the wire protocol are unchanged.

### Fixed

- Discard old child-window pixels when scrolling or resizing, and repaint
  the parent, descendants, and control borders as one batch. Beta 3 moved
  children individually and invalidated only the parent, leaving text trails.
- Preserve the expanded native combo-box height separately from the
  collapsed layout row, including after scrolling, resizing, or mode changes.
  Both remote-input and local-only choices remain accessible; long trusted
  peer lists use a bounded drop-down with a scrollbar.
- Use **WindowsKVM** for the window title, main heading, and hide-to-tray
  guidance. Stack the mode button below the longer name on narrow windows.

### Validation

- Add portable regression cases for combo geometry across scroll/resize
  sequences, different item heights, long peer lists, and narrow headings.
- Native scrolling, dropdown selection, and DPI behavior still require
  Windows x64/ARM64 desktop acceptance; cross-builds alone do not verify pixels.

## WindowsKVM 1.02.20 (build 100) — 2026-09-12

This Windows-only maintenance update addresses input, control-lifecycle, and
consent-dialog review findings. macOS sources, macOS version metadata, and
the wire protocol are unchanged.

### Fixed

- Preserve held-key tracking when a native key-up fails so control teardown
  can retry the release instead of silently leaving a modifier pressed.
- Keep the authenticated connection open when valid input already in flight
  arrives for an ended control request. Retired request tracking is bounded;
  unknown request IDs remain protocol violations.
- End and notify the Mac of the current grant when switching to local-only
  input. Quickly re-enabling remote input cannot revive an old grant or an
  approval that was already pending when input was disabled.
- Forward repeated key-down events using the original held-key mapping.
- Map Mac button 2 to the middle button, 3 to XBUTTON1, and 4 to XBUTTON2,
  including release-all cleanup. Ignore unsupported extra buttons safely.
- Ignore unsupported brightness and keyboard-illumination keys instead of
  invoking unrelated Windows media or application-launch actions.
- Serialize request-bound UI consent dialogs and close cancelled or expired
  prompts, preventing stale acceptance and blocked subsequent prompts.
- Share one listener-instance guard between UI and console receivers so they
  cannot advertise the same identity from different ports. One-shot version
  and paired-device management commands remain available.
- Make Simple mode a compact status panel. Keep routine diagnostics and
  full identity details in Advanced mode, remove the redundant in-window
  Open window action, and keep the window within the available work area.
  Reflow Simple controls when resizing and provide horizontal scrolling for
  full-size Advanced controls in narrow windows.
  Enforce a usable minimum tracking size to prevent Simple controls from
  overlapping when the window is dragged extremely narrow.

### Tests and documentation

- Add desktop regression tests alongside the existing protocol self-test,
  exercising production input and receiver paths with simulated native APIs.
- Document Windows x64/ARM64 desktop acceptance checks and switching between
  UI mode and console logging without starting a duplicate receiver.

## 1.02.19 (build 99) — 2026-09-05

This cross-platform maintenance release gives the Windows secure-session
receiver the same bounded peer-liveness behavior as MacKVM.

### Fixed

- Configure Windows secure sessions with TCP keepalive (five-second idle,
  two-second probe interval, and three probes) and a short socket liveness
  grace period. A peer that sleeps, is force-quit, or loses its network path
  now releases Windows keyboard/mouse control and permits reconnect without a
  manual restart.
- Add deterministic Windows protocol coverage for the Winsock keepalive
  settings while preserving the existing signed disconnect capability and
  wire compatibility.

## 1.02.18 (build 98) — 2026-09-05

This maintenance release recovers authenticated secure sessions when a peer
disappears without sending application traffic.

### Fixed

- Enable bounded TCP keepalive and Network.framework viability handling for
  secure sessions. A headless peer that is force-quit, put to sleep, or loses
  its network path now clears the stale session and permits reconnect without
  a manual **Disconnect** action.
- Add manual acceptance coverage for a controller with no local keyboard or
  mouse, including the expected stale-session cleanup and reconnect path.

## 1.02.17 (build 97) — 2026-09-05

This maintenance release expands the manual acceptance coverage for the
combined O shortcut and the manual K monitor route.

### Tests and documentation

- Add controller-side and receiver-side second-press O checks, including the
  expected return of display and keyboard/mouse ownership.
- Document that ending a manual K session with K, Escape, or the peer return
  action must not trigger a DDC switch or change the manually selected input.

## 1.02.16 (build 96) — 2026-09-05

This maintenance release fixes Windows trust-store rollback and tray-window
visibility races, and clarifies control-consent persistence in the user
documentation.

### Security

- Invalidate the cached trust-file stamp whenever a trust-store mutation or
  rollback fails, so a rejected key replacement cannot keep stale control
  authorization after another process changes the durable trust decision.

### Fixed

- Preserve the parent and child visibility state while batching Win32 redraws;
  hidden tray windows and inactive Simple/Advanced controls no longer become
  visible when `WM_SETREDRAW` is re-enabled.
- Clarify that interactive pairing enables durable automatic control approval,
  while a control-dialog **Allow** and test-only `--yes` pairing are one-shot.

## 1.02.15 (build 95) — 2026-09-04

This security maintenance release closes authorization and lifecycle races in
the Windows companion and Mac input sender.

### Security

- Bind remembered Windows control approval to the authenticated Mac public key,
  re-check that key before activation, and revoke active sessions when a key is
  replaced so an old session cannot inherit a replacement key's approval. An
  already-running receiver refreshes the durable trust decision while input is
  flowing, so a cross-process Forget, replacement, or deny cannot keep the old
  session active.
- Keep interactive control consent one-shot; only the explicit paired-device
  setting or `--allow-control` command persists automatic approval. Unattended
  `--yes` pairing does not save that authorization, and legacy trust files are
  treated as unconfigured until the user makes an explicit choice.
- Release active Windows input immediately when a trusted peer is forgotten or
  its key is replaced.

### Fixed

- Clear delayed Mac pointer snapshots on every control-session transition and
  avoid coalescer queue self-deadlocks during teardown.
- Preserve concurrent Windows tray status updates while coalescing UI refreshes.

## 1.02.14 (build 94) — 2026-09-04

This maintenance release improves pointer responsiveness and keeps the
Windows companion stable while pairing and control state changes arrive.

### Fixed

- Coalesce consecutive absolute mouse-move snapshots on the Mac sender with a
  bounded four-millisecond flush window. Keyboard, button, scroll, and
  lifecycle messages keep their ordering, and pending movement is discarded
  when a secure connection ends so stale pointer events cannot leak into a new
  session.
- Keep Windows pairing and runtime status callbacks off the Win32 control path:
  network callbacks are queued to the UI message loop and bursts are reduced to
  the newest state before controls are updated.
- Batch Windows child-window positioning during scrolling and Simple/Advanced
  mode changes, suspend redraw during the transaction, and use a composited
  parent plus an immediate full-child redraw to avoid torn or partially
  rendered rows.

## 1.02.13 (build 93) — 2026-09-04

This feature release makes trusted Windows control seamless by default after
the user completes pairing.

### Added

- Enable automatic control approval for each newly pinned Mac public key, so
  subsequent control switches do not block on a repeated confirmation dialog.
- Keep the Windows UI **Automatically allow control from this paired Mac**
  setting and console `--allow-control`/`--deny-control` commands available to
  opt out or restore seamless control.

### Security

- Keep remembered control approval separate from pairing trust; **Forget** and
  an explicitly approved public-key replacement clear the old approval before
  the replacement receives the default grant.
- Reload the atomic trust snapshot before each control request so a separate
  CLI process can revoke or restore the local decision without exposing private
  key material. The test-only `--yes` option remains one-shot and is not saved.

## 1.02.11 (build 91) — 2026-09-02

This maintenance release adds a cross-platform debugging guide for collecting
macOS unified logs, Windows console traces, network/firewall state, and native
DDC reports without exposing private credentials.

### Added

- Document the recommended console-only Windows log capture flow and the
  expected pairing, Secure Connect, and control checkpoints.
- Document macOS `log stream`/`log show`, support-information export, mDNS
  checks, and architecture-aware DDC diagnostics.

### Changed

- Synchronize the MacKVM and WindowsKVM version metadata to 1.02.11/build 91.

## 1.02.10 (build 90) — 2026-08-31

This maintenance release syncs the macOS core with the latest cross-Mac
control lifecycle fixes while retaining the Windows companion changes.

### Fixed

- Keep the manual `Control-Option-Command-K` monitor route under the user's
  control; ending that session returns keyboard, mouse, and trackpad input
  without triggering an unwanted DDC display switch.
- Add regression coverage for local and peer-ended manual-monitor sessions.

### Changed

- Rename the Windows application source directory from `WindowsKVM.App` to
  `WindowsKVM.Desktop` so macOS Finder does not present the tracked source as
  an application bundle. Build outputs remain under the ignored `dist/` path.

## 1.02.09 (build 89) — 2026-08-31

This release hardens the Windows companion after the P1/P2 review findings.

### Fixed

- Keep the notification-area icon on the legacy callback contract so double-click
  and right-click still reopen or quit the hidden UI.
- Require an explicit interactive consent decision before replacing a pinned Mac
  public key; `--yes` no longer performs a silent key replacement.
- Make **Local Windows input only** disable remote-control admission and release
  any active Windows input grant immediately.

### Added

- Show every trusted Mac in the Windows UI selector and apply **Forget paired Mac**
  to the selected peer instead of an arbitrary entry.

## 1.02.08 (build 88) — 2026-08-30

This release adds console commands for inspecting and removing Windows-side
paired-Mac trust pins.

### Added

- Add `--list-paired` to print each trusted Mac's friendly name, full peer ID,
  and public-key fingerprint.
- Add `--forget <peer-id>` to remove one trusted Mac from the Windows trust
  store; pair again before pressing Connect.
- Document that the one-shot CLI command changes durable trust, while an
  already-running receiver must be restarted (or use the UI Forget action) to
  close its in-memory active session.

## 1.02.07 (build 87) — 2026-08-30

This release adds Windows-side paired-Mac revocation so forgetting a pairing
does not leave a stale trust pin that blocks the next pairing.

### Added

- Add **Forget paired Mac** to the Windows UI in both Simple and Advanced
  modes.
- Remove the selected Mac public-key pin transactionally from
  `%LOCALAPPDATA%\\MacKVM\\trusted-peers.json` and close any active secure
  session for that peer.
- Load the existing Windows trust list at startup so Forget remains available
  after a restart; pairing is required again after a Forget action.

## 1.02.06 (build 86) — 2026-08-30

This release makes a re-pair after a deliberately reset Mac identity explicit
and reviewable instead of silently replacing a pinned public key.

### Fixed

- Keep Secure Connect fail-closed for changed peer keys.
- Show a replacement warning in the Windows UI and console pairing prompt;
  replace an old pin only after the signed verification-code flow is accepted
  locally.

## 1.02.05 (build 85) — 2026-08-30

This release makes the Windows companion UI responsive on compact displays
while keeping the complete macOS-aligned diagnostics available.

### Added

- Add automatic Simple mode selection for compact screens and a header toggle
  to switch between Simple and Advanced modes.
- Keep identity, readiness, pairing, control state, firewall, Refresh, and Quit
  actions visible in Simple mode without requiring a long scroll.

## 1.02.04 (build 84) — 2026-08-30

This release aligns the Windows companion UI with the macOS setup panel while
retaining the same pairing and secure-session runtime.

### Added

- Add a scrollable, macOS-aligned Windows status panel with setup readiness,
  physical input path, nearby/paired peer, keyboard/mouse control, monitor
  guidance, and support-information sections.
- Add native status colors, live paired-peer and control-state updates, a
  Windows Firewall settings action, and a local key-fingerprint display.
- Publish matching Windows x64 and ARM64 UI test executables.

## 1.02.03 (build 83) — 2026-08-27

This release adds the first usable Windows desktop host while retaining the
console path for automation and diagnostics.

### Added

- Add a native Win32 status window and resident notification-area tray icon.
- Show pairing verification and authenticated control consent in native
  Windows Yes/No dialogs instead of requiring a visible console.
- Add single-instance protection, hide-to-tray behavior, explicit Quit cleanup,
  runtime status updates, and public **Copy support information** output.
- Share one runtime lifecycle between UI and CLI so trust storage, mDNS
  advertising, secure-session admission, and release-all teardown stay
  identical in both modes.
- Add a least-privilege, per-monitor-DPI application manifest.
- Verify the Windows desktop publish on a native Windows CI runner for both
  x64 and ARM64 targets.

### Compatibility

- The Windows beta remains incompatible with MacKVM 1.00.00; use a Mac build
  that signs `disconnectSignalVersion` (MacKVM 1.100.00/build 75 or later).

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

- The Windows beta is not compatible with the MacKVM 1.00.00 release.
- Pairing and secure Connect require a MacKVM build with the signed
  `disconnectSignalVersion` capability (introduced in MacKVM 1.100.00/build 75);
  older peers are rejected with an explicit upgrade-required error.

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
