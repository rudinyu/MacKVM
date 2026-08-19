# MacKVM roadmap

[Architecture](ARCHITECTURE.md) · [Installation guide](INSTALL.md) ·
[Security status](SECURITY.md) · [繁體中文](ROADMAP.zh-TW.md)

This roadmap is written against the 0.11.0 source tree. Every gap below was
confirmed in code rather than inferred from the documentation, and each item
records the files a change would start from.

## Where the project stands

The parts that are hard to get right are done: mutual pairing with a
commit-then-reveal verification code, key pinning with generation-guarded
revocation, an authenticated encrypted session with key confirmation, bounded
queues and buffers on every inbound path, and explicit receiver consent with
safe teardown of held keys and buttons. Those areas need maintenance, not new
design.

What the project lacks is daily usability. MacKVM is currently correct but
tiring to use: it forwards a narrow slice of input, requires a full
request/consent round trip for every switch, and maps only one display.

| Area | Current behavior | Starting point |
| --- | --- | --- |
| Forwarded input | Keyboard (with cross-layout remapping), mouse, scroll (with phase/momentum), and an allowlisted set of media keys; no clipboard yet | [`RemoteInputProtocol.swift:3`](Sources/MacKVMCore/RemoteInputProtocol.swift:3) |
| Switching | Menu → Request → local one-time authorization for newly paired peers; Allow/Deny remains available when revoked | [`ControlCoordinator.swift:163`](Sources/MacKVM/ControlCoordinator.swift:163) |
| Pointer mapping | Main display only; other screens clamp to its edge | [`InputServices.swift:1154`](Sources/MacKVM/InputServices.swift:1154) |
| Peer count | One peer at a time, arbitrated by UUID comparison | [`PeerArbitration.swift:4`](Sources/MacKVMCore/PeerArbitration.swift:4) |
| Monitor switching | Native DDC/CI through IOAVService (Apple Silicon) or IOI2C (Intel); OSD fallback when unavailable | [`Sources/MacKVM/NativeDDCService.swift`](Sources/MacKVM/NativeDDCService.swift) |

## Priorities

| ID | Feature | Impact | Effort | Phase |
| --- | --- | --- | --- | --- |
| F1 | Clipboard sync | High | Medium | P0 |
| F2 | Edge crossing and pre-authorized peers | High | Medium | P0 |
| F3 | Media and system key forwarding | High | Low | **Done** |
| F4 | Multi-display mapping | Medium | Medium | P1 |
| F5 | Scroll fidelity | Medium | Low | **Done** |
| F6 | Keyboard layout remapping | Medium | Medium | **Done** |
| F7 | Native DDC without external helper | Medium | Medium | **Done** |
| F8 | Three or more Macs | Low | High | P2 |
| F9 | Notarized release and updates | Low | Medium | P2 |
| F10 | Connection diagnostics | Low | Low | P2 |
| F11 | Trackpad gestures | Medium | Unknown | P3 |
| F12 | File transfer and drag and drop | Low | High | P3 |
| F13 | Waking a sleeping Mac | Low | Low | P3 |

Impact is measured against daily two-Mac use, not against feature parity with
other KVM software.

## P0 — make it usable every day

### F1. Clipboard sync

Copying text between the two Macs currently requires AirDrop or a chat app.
This is the feature users of comparable tools reach for first.

`RemoteInputKind` has no concept of clipboard content, so this needs a new
`ControlMessageKind.clipboard` alongside the existing kinds in
[`ControlProtocol.swift:3`](Sources/MacKVMCore/ControlProtocol.swift:3).

Design constraints, in keeping with the existing security posture:

- Clipboards frequently hold passwords. Respect
  `org.nspasteboard.ConcealedType`, which password managers set, and never
  synchronize content carrying that marker.
- Start with a single type allowlist (`public.utf8-plain-text`). Reuse the
  existing 32 KiB plaintext ceiling from
  [`ControlProtocol.swift:155`](Sources/MacKVMCore/ControlProtocol.swift:155)
  and reject anything larger instead of fragmenting it.
- Ship the setting off by default and require an explicit opt-in, matching the
  project's existing refusal to assume trust.

Images and files belong in F12, because they require fragmentation and
backpressure work against `InboundPayloadBudget`.

### F2. Edge crossing and pre-authorized peers

Edge crossing is still missing, but the per-peer pre-authorization layer is now
implemented. New pairings enable a receiver-side one-time authorization by
default, and the receiver can revoke it from **Paired device information**.
When it is disabled, the existing 15-second request and explicit **Allow**
flow remains in place. This removes the display/input deadlock for daily use
without moving consent into the wire protocol.

The goal is switching by pushing the pointer past the screen edge. This
conflicts directly with the current per-session consent model, so it should be
built in explicit layers:

1. The per-peer `seamlessControlAuthorized` flag in
   [`PairedPeerProfile.swift`](Sources/MacKVMCore/PairedPeerProfile.swift),
   enabled by a completed pairing and revocable at any time from the existing
   **Paired device information** menu section, is complete.
2. When the flag is set, `handleControlRequest`
   ([`ControlCoordinator.swift:468`](Sources/MacKVM/ControlCoordinator.swift:468))
   takes a fast path that grants without prompting. Without the flag, the
   current flow is unchanged. This layer is complete.
3. Detect edge dwell in `InputCaptureService.pointerEvent` and trigger a
   control request from there; `MonitorController` follows with the DDC input
   switch.
4. The `⌃⌥⌘Esc` emergency return must keep working in seamless mode. It is the
   only escape hatch and cannot be traded away for latency.

`SECURITY.md` states plainly that enabling seamless mode downgrades per-session
consent to a one-time authorization, leaving the local network and the pinned
key as the trust boundary.

### F3. Media and system key forwarding — completed

`RemoteInputKind.systemDefined` now carries an allowlisted `MediaKey`
(volume, brightness, play/pause, track skip, keyboard illumination — 13 keys
in total). The capture side reads `NSSystemDefined` (raw `CGEventType` 14,
which has no named case) via `NSEvent(cgEvent:)` to get at `subtype`/`data1`,
and only forwards `NX_SUBTYPE_AUX_CONTROL_BUTTONS` events whose key code is on
the allowlist. The power key and Caps Lock are deliberately excluded — the
former so a remote peer can never open the shutdown dialog or sleep the
receiving Mac, the latter because it already travels as an ordinary
`flagsChanged` edge. See [`SECURITY.md`](SECURITY.md) for the full rationale.

## P1 — fidelity and reach

### F4. Multi-display mapping

`MainDisplayCoordinateSpace` resolves `CGMainDisplayID()` on both sides and
clamps every other screen to its edge. The README instruction to make the
MA270U the main display on both Macs is a workaround for this limitation, and
it breaks as soon as a MacBook runs with its lid open.

The fix is to exchange a display topology (per-screen bounds and arrangement)
and map the pointer to the matching remote screen. This changes the wire
format, but `ControlProtocolCompatibility`
([`ControlProtocol.swift:129`](Sources/MacKVMCore/ControlProtocol.swift:129))
already reserves a version range, so a v2 negotiation path exists.

### F5. Scroll fidelity — completed

`RemoteInputEvent` now carries optional `scrollPhase` and
`scrollMomentumPhase` fields mirroring `CGScrollPhase` and
`CGMomentumScrollPhase`. A missing field means "no phase," so a plain mouse
wheel and a legacy peer both produce exactly the payload they always did;
only a trackpad's phased scroll stream adds the extra fields, letting the
receiver reproduce macOS inertia instead of discrete steps.

### F6. Keyboard layout remapping — completed

Two problems here turned out to be separate, and both are fixed:

- **False disconnects from toggling an input method.** The old layout
  identifier came from a UserDefaults key that reflects the active *input
  method* (for example `com.apple.inputmethod.TCIM.Zhuyin`), not the
  underlying keyboard hardware layout, so switching Zhuyin on or off looked
  like a layout change. `KeyboardLayoutIdentifier.current()` now reads
  `TISCopyCurrentKeyboardLayoutInputSource`
  ([`CarbonKeyboardLayout.swift`](Sources/MacKVM/CarbonKeyboardLayout.swift)),
  which returns the physical layout beneath any input method, so toggling an
  IME no longer touches this value at all.
- **Genuinely different physical layouts.** Each `keyDown` for a letter,
  digit, or symbol key (`RemappableKeyCodes.all` in
  [`KeyboardLayoutRemap.swift`](Sources/MacKVMCore/KeyboardLayoutRemap.swift) —
  arrows, Return, Tab, and every modifier are excluded, since those keys mean
  the same thing on every layout) now carries the character the sender's own
  layout produced for it. When the receiver's layout differs, it builds a
  `KeyboardLayoutReverseMap` once per layout change and looks up which local
  key produce that character, rather than injecting the sender's keycode
  under a meaning it doesn't have locally. What happens to the flags then
  splits on whether Command or Control was held. Plain typing replaces
  Shift/Option/Caps Lock with whatever combination the local layout needs to
  reproduce the sender's character. A key held with Command or Control looks
  itself up using its unmodified character — Shift and Caps Lock never affect
  which local key is found — and injects with every one of the sender's flags
  unchanged, including a real Shift that selects a different shortcut (Redo
  instead of Undo): only the keycode came from the lookup. That split is what
  lands Command-Z on the key that actually produces "z" on a layout where Y
  and Z are swapped (German QWERTZ, for one) without letting an incidental
  Caps Lock turn Command-C into Command-Shift-C. `ControlCoordinator` denies a
  request over a layout mismatch only when the requesting peer's protocol
  version predates character-based remapping (it would never send the
  character field, so admitting it would only grant control to end it on the
  first remappable keystroke); a v2 peer's differing layout is not denied,
  since `RemoteInputSink` resolves it instead — ending the session, the
  original fallback behavior, only when a specific key turns out to have no
  equivalent on the receiver's layout. A held key's auto-repeat reuses the
  same resolution as its first keyDown rather than recomputing one per
  repeat, so a modifier changing mid-hold cannot retarget a live press to a
  different local key and strand the original one held down.

Two review passes before merge caught five real gaps here, all now fixed: a
v1 peer with a differing layout was granted control only to have it end on
its first remappable keystroke (fixed by the protocol version gate above);
auto-repeat could retarget and strand a held key (fixed by pinning the
resolution above); `UCKeyTranslate` always passed keyboard type 0, which
silently selects the wrong ANSI/ISO/JIS sub-table on non-ANSI hardware (fixed
by reading `LMGetKbdType()` in
[`CarbonKeyboardLayout.swift`](Sources/MacKVM/CarbonKeyboardLayout.swift)); and
Command/Control shortcuts went through two fixes in sequence — first found to
be corruptible by Caps Lock or Option (an initial fix bypassed remapping for
them entirely), then found to land on the wrong key on a layout where letter
positions genuinely differ, like the Y/Z swap on German QWERTZ, because
bypassing remapping also bypassed the keycode translation these keys still
need (fixed by remapping only the keycode, via the unmodified character, and
leaving every flag untouched, as described above).

The reverse-map lookup logic is exercised by
[`KeyboardLayoutRemapTests.swift`](Tests/MacKVMCoreTests/KeyboardLayoutRemapTests.swift)
against a stub layout, and `RemoteInputSink`'s resolution of it — auto-repeat
pinning, the shortcut/typing flag split, and the unmappable-key path — by
[`RemoteInputSinkKeyRemapTests.swift`](Tests/MacKVMTests/RemoteInputSinkKeyRemapTests.swift)
against a fake `KeyboardLayoutProviding`, added after a third review pass
found the injection-side logic was entirely private and therefore
unreachable from `@testable import MacKVM` despite being exactly the code
those five bugs lived in. That same pass also found `RemoteInputSink` called
`CarbonKeyboardLayout` from its private background injection queue while the
capture side calls the same Text Input Source APIs from the main thread —
undocumented as thread-safe by Apple, and a real crash/hang risk from two
threads touching Carbon's TIS state concurrently. `RemoteInputSink` now takes
its layout lookups through an injectable `KeyboardLayoutProviding`, whose
production implementation, `CarbonKeyboardLayoutProvider`, marshals every
call onto the main thread with `DispatchQueue.main.sync`; the same protocol
is what lets the new tests substitute a fake layout instead of depending on
the test machine's real one.

`UCKeyTranslate` runs with `kUCKeyTranslateNoDeadKeysBit`, so a remapped
keystroke can land on a key that is a genuine dead key on the receiver's
layout (an accent key on German, French, or Spanish, for instance),
producing a stuck pending composition instead of the sender's character.
Narrow and not security-relevant — worth a manual-test pass if dead-key-heavy
layouts are ever in the two-Mac setup, not a code change on its own.

Both `KeyboardLayoutRemapTests.swift` and `RemoteInputSinkKeyRemapTests.swift`
are deterministic; the `UCKeyTranslate`/`TISCopyCurrentKeyboardLayoutInputSource`
calls themselves are not testable without real hardware and still need
verification: type through a genuinely different physical layout (not just a
different input method) on both Macs and confirm the right characters land,
including Shift/Option/Caps Lock combinations and held-key auto-repeat; that a
Cmd-modified shortcut for a key at a swapped position (Command-Z on German
QWERTZ, where Y and Z trade places, is the standing example) fires the
correct action; and that the same shortcut is unaffected by the sender's Caps
Lock state. Plus, if ISO or JIS hardware is available, that its
layout-specific keys translate correctly.

### F7. Native DDC without an external helper — completed

MacKVM now discovers external displays through a native IOKit bridge and sends
the DDC/CI input-source VCP 0x60 command without launching another process.
Apple Silicon uses the display's `IOAVService`; Intel uses `IOI2C` bus
interfaces. Display selection is based on a bounded native selector derived
from display identity, not a MA270U model-name allowlist or a numeric index.
When a monitor or cable does not expose DDC/CI, the app reports a diagnostic and
leaves the monitor OSD as the explicit fallback.

## P2 — scale and distribution

### F8. Three or more Macs

`SecureSessionService` tracks a single desired peer, and `PeerArbitration`
compares two UUIDs. Supporting more Macs requires redesigning both arbitration
(which Mac owns the keyboard) and the menu (which Mac to switch to). This is
the largest item here and is not worth starting for a two-Mac setup.

### F9. Notarized release and updates

Already recorded as outstanding in `ARCHITECTURE.md`. Required before anyone
else can install MacKVM without Finder's **Open** confirmation; deferrable
indefinitely for personal use.

### F10. Connection diagnostics

Beyond the static `SupportInformation` snapshot there is no runtime
observability, so stuttering remote input cannot be diagnosed. Latency and
jitter indicators plus a bounded event log would make the manual test
checklist far easier to complete.

## P3 — needs a spike first

- **F11. Trackpad gestures.** Pinch to zoom and multi-finger swipes.
  Synthesizing gesture events through CGEvent is limited and may require
  private API; scope this only after a research spike.
- **F12. File transfer and drag and drop.** Requires fragmentation,
  backpressure, and progress reporting, and materially widens the attack
  surface.
- **F13. Waking a sleeping Mac.** Nothing works when the target is asleep.
  Either a Wake-on-LAN magic packet or an option to hold the target awake while
  paired.

## Suggested order

F3, F5, F6, and F7 are done. **F1** is next: it is self-contained, leaves the
control state machine untouched, and — now that F3/F5/F6 have each added a
protocol field and shipped safely — is a well-rehearsed shape of change to
make.

Take **F2** after that. It is the step that changes how the product feels
most, but because it modifies the consent model it deserves its own design
note covering the security tradeoff before any code is written.

**F4** is the only P1 item left, and only matters once a MacBook runs with its
lid open rather than both Macs driving the MA270U as their main display.
