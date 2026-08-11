# MacKVM roadmap

[Architecture](ARCHITECTURE.md) · [Installation guide](INSTALL.md) ·
[Security status](SECURITY.md) · [繁體中文](ROADMAP.zh-TW.md)

This roadmap is written against the 0.8.0 source tree. Every gap below was
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
| Forwarded input | Keyboard, mouse, and scroll only (14 event kinds) | [`RemoteInputProtocol.swift:3`](Sources/MacKVMCore/RemoteInputProtocol.swift:3) |
| Switching | Menu → Request → remote Allow, with a 15-second window | [`ControlCoordinator.swift:163`](Sources/MacKVM/ControlCoordinator.swift:163) |
| Pointer mapping | Main display only; other screens clamp to its edge | [`InputServices.swift:894`](Sources/MacKVM/InputServices.swift:894) |
| Peer count | One peer at a time, arbitrated by UUID comparison | [`PeerArbitration.swift:4`](Sources/MacKVMCore/PeerArbitration.swift:4) |
| Monitor switching | Native DDC/CI through IOAVService (Apple Silicon) or IOI2C (Intel); OSD fallback when unavailable | [`Sources/MacKVM/NativeDDCService.swift`](Sources/MacKVM/NativeDDCService.swift) |

## Priorities

| ID | Feature | Impact | Effort | Phase |
| --- | --- | --- | --- | --- |
| F1 | Clipboard sync | High | Medium | P0 |
| F2 | Edge crossing and pre-authorized peers | High | Medium | P0 |
| F3 | Media and system key forwarding | High | Low | P0 |
| F4 | Multi-display mapping | Medium | Medium | P1 |
| F5 | Scroll fidelity | Medium | Low | P1 |
| F6 | Keyboard layout remapping | Medium | Medium | P1 |
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

Every switch today runs the full request and consent exchange with a
15-second timeout, and the receiving Mac must press **Allow**. That friction
dominates daily use.

The goal is switching by pushing the pointer past the screen edge. This
conflicts directly with the current per-session consent model, so it should be
built in explicit layers:

1. Add a per-peer `seamlessControlAuthorized` flag to
   [`PairedPeerProfile.swift`](Sources/MacKVMCore/PairedPeerProfile.swift),
   granted once by the receiver and revocable at any time from the existing
   **Paired device information** menu section.
2. When the flag is set, `handleControlRequest`
   ([`ControlCoordinator.swift:468`](Sources/MacKVM/ControlCoordinator.swift:468))
   takes a fast path that grants without prompting. Without the flag, the
   current flow is unchanged.
3. Detect edge dwell in `InputCaptureService.pointerEvent` and trigger a
   control request from there; `MonitorController` follows with the DDC input
   switch.
4. The `⌃⌥⌘Esc` emergency return must keep working in seamless mode. It is the
   only escape hatch and cannot be traded away for latency.

`SECURITY.md` must state plainly that enabling seamless mode downgrades
per-session consent to a one-time authorization, leaving the local network and
the pinned key as the trust boundary.

### F3. Media and system key forwarding

The capture mask in
[`InputServices.swift:409`](Sources/MacKVM/InputServices.swift:409) covers only
key, mouse, and scroll events. Volume, brightness, play/pause, and Mission
Control keys therefore do nothing on the target Mac, which users notice within
minutes.

These arrive as `NSSystemDefined` (type 14) events. Add a
`RemoteInputKind.systemDefined` carrying the subtype and key code, and validate
it against a known media-key subtype allowlist rather than permitting arbitrary
system event injection.

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

### F5. Scroll fidelity

Scroll capture in
[`InputServices.swift:313`](Sources/MacKVM/InputServices.swift:313) sends pixel
deltas with no phase information, so remote scrolling feels rigid and lacks
macOS inertia. Carrying `scrollWheelEventScrollPhase` and
`scrollWheelEventMomentumPhase` is a small change with a large effect on feel.

### F6. Keyboard layout remapping

A layout change currently terminates remote input
([`InputServices.swift:550`](Sources/MacKVM/InputServices.swift:550)). For
anyone switching between Traditional Chinese and English input sources, that
means changing input method drops the session.

Translate key codes to characters with `UCKeyTranslate` on the sending side and
resolve them back to key codes on the receiver. Keep the current abort behavior
as the fallback for characters that cannot be mapped.

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

Start with **F1 and F3**. Both are self-contained, leave the control state
machine untouched, and have clear verification paths. Together they are a
useful rehearsal for adding a protocol message kind and confirm the version
negotiation machinery works in practice.

Take **F2** next. It is the step that changes how the product feels, but
because it modifies the consent model it deserves its own design note covering
the security tradeoff before any code is written.

Order **F6** and **F7** by actual usage: F6 first if input sources are switched
frequently, F7 first if manually pressing the monitor's OSD for the Intel Mac
is the larger daily annoyance.
