# MacKVM architecture and usage

[繁體中文](ARCHITECTURE.zh-TW.md) · [Installation guide](INSTALL.md) · [HTML manual](docs/USER_MANUAL.html)

## Current scope

The repository implements discovery, mutual pairing, a persistent encrypted
session, validated keyboard, mouse, and trackpad forwarding, explicit receiver consent and
safe local-return controls, a sequential macOS setup checklist, and native
DDC/CI monitor input switching.

```mermaid
flowchart LR
    subgraph MacA["MacBook Pro A"]
        UIA["SwiftUI menu bar + MacKVM window<br/>persistent KVM/display icon"]
        PermA["Guided setup checklist<br/>Local Network → Input Monitoring → Accessibility"]
        LoginA["LaunchAtLoginController<br/>SMAppService"]
        DA["PeerDiscoveryService"]
        WA["NWListener + NWBrowser"]
        KA["Keychain private key"]
        RA["PairingRegistry<br/>UserDefaults"]
        ProfileA["PairedPeerProfile<br/>name, model, last connection, fingerprint,<br/>seamless control authorization"]
        PA["Pairing + SecureSession<br/>P-256 + HKDF + ChaChaPoly"]
        IA["CGEventTap capture<br/>Input Monitoring"]
        OA["CGEvent injection<br/>Accessibility"]
        NA["ControlRequestNotifier<br/>native Allow / Deny / Review"]
        MA["MonitorController<br/>native IOAVService / IOI2C<br/>or OSD fallback"]
        UIA --> DA
        UIA --> PermA
        UIA --> LoginA
        DA --> WA
        DA --> PA
        DA --> KA
        DA --> RA
        RA --> ProfileA
        UIA --> ProfileA
        IA --> PA
        PA --> OA
        PA --> NA
        UIA --> MA
    end

    subgraph LAN["Trusted local network"]
        Bonjour["Bonjour _mackvm._tcp"]
        TCP["Signed pairing + encrypted control session<br/>over TCP"]
    end

    subgraph MacB["MacBook Pro B"]
        UIB["SwiftUI menu bar + MacKVM window<br/>persistent KVM/display icon"]
        PermB["Guided setup checklist"]
        LoginB["LaunchAtLoginController"]
        DB["PeerDiscoveryService"]
        WB["NWListener + NWBrowser"]
        KB["Keychain private key"]
        RB["PairingRegistry<br/>UserDefaults"]
        ProfileB["PairedPeerProfile<br/>name, model, last connection, fingerprint"]
        PB["Pairing + SecureSession"]
        IB["CGEventTap capture"]
        OB["CGEvent injection"]
        NB["ControlRequestNotifier"]
        MB["MonitorController"]
        UIB --> DB
        UIB --> PermB
        UIB --> LoginB
        DB --> WB
        DB --> PB
        DB --> KB
        DB --> RB
        RB --> ProfileB
        UIB --> ProfileB
        IB --> PB
        PB --> OB
        PB --> NB
        UIB --> MB
    end

    WA <--> Bonjour
    WB <--> Bonjour
    PA <--> TCP
    PB <--> TCP
```

The pairing protocol currently works as follows:

1. Each Mac creates a persistent UUID and P-256 signing key. The private key
   is stored in the macOS Keychain; the public identity is advertised through
   Bonjour TXT data.
2. `NWBrowser` discovers the other Mac and reads its name, UUID, and public
   key.
3. The initiator and responder exchange signed commitments to independent
   random contributions, then reveal those contributions only after both
   commitments are fixed.
4. Both sides derive a six-digit verification code from the contributions,
   request UUID, roles, and both public keys. The user compares the code on both
   Macs.
5. The receiving Mac selects **Accept** and the initiating Mac selects
   **Confirm code** after comparing the matching code. Both signed decisions
   are required. The peer public key is pinned in `PairingRegistry` only after
   both signed acceptance messages, signed
   completion messages, and completion acknowledgements arrive. Each
   acknowledgement closes that Mac's sending direction; the peer's half-close
   must also arrive before trust is persisted.
   Either Mac may be the initiator. A blocked or waiting inbound listener is a
   transport/firewall condition, not a different cryptographic role; the menu
   exposes **Cancel pairing** and **Retry pairing** and clears unfinished
   requests when Network.framework reports a service failure.
6. A later control connection exchanges signed ephemeral P-256 keys, derives
   directional keys with HKDF, and requires an encrypted key-confirmation packet
   before the responder marks the session connected.
7. The receiving Mac presents each signed/encrypted control request to its user.
   When its menu is closed, `ControlRequestNotifier` also presents a native
   Allow/Deny/Review notification. The Allow action requires macOS
   authentication at the lock screen. Its action includes the request UUID plus
   a fresh device-local notification nonce; `ControlRequestNotifier` checks the
   nonce against its one live notification, and `ControlCoordinator` separately
   checks the UUID against its one live request before taking any action.
   **Review in MacKVM** opens an explicit Allow/Deny dialog. For a newly paired
   peer, the receiver may take the local `seamlessControlAuthorized` fast path
   and use the same acceptance routine without showing a prompt; otherwise
   only after **Allow** is selected does its injection queue become ready and
   return a matching grant. The controlling
   Mac then captures selected
   keyboard, mouse, and trackpad pointer/scroll events with a suppressing `CGEventTap`, validates
   and encrypts them, and sends them through the secure session. The receiver
   validates them again and injects them using `CGEvent`; either side can end
   control safely.

After pairing, each Mac stores a profile beside the pinned public key. The
profile keeps the peer's validated friendly name and advertised model, records
the time of the last authenticated connection, and derives a display-only
SHA-256 fingerprint from the pinned public key. New pairings enable the local
`seamlessControlAuthorized` flag; the menu lets the user revoke it per peer,
edit the friendly name, and copy a support report containing these public
fields plus version, OS, and connection status. Private keys, credentials, and
endpoints are deliberately excluded from that report.

```mermaid
stateDiagram-v2
    [*] --> idle
    idle --> connected: encrypted transport ready
    connected --> suspended: request control
    suspended --> controlling: peer grants
    suspended --> connected: deny or timeout
    controlling --> connected: stop or emergency shortcut
    controlling --> disconnected: transport loss
    connected --> disconnected: transport loss
    disconnected --> connected: reconnect
```

## Physical setup for the target KVM

```mermaid
flowchart LR
    Intel["2019 16-inch MacBook Pro<br/>Thunderbolt 3"] -->|"USB-C to HDMI adapter"| HDMI["MA270U HDMI input"]
    Apple["M5 Pro 14-inch MacBook Pro<br/>USB-C"] -->|"USB-C video + data + power"| USBC["MA270U USB-C input"]
    HDMI --> Monitor["BenQ MA270U 4K"]
    USBC --> Monitor
    Input["Keyboard + mouse + trackpad"] -->|"CGEventTap"| Control["Encrypted MacKVM control session"]
    Control -->|"CGEvent injection"| Target["Active Mac"]
    Control -->|"control lifecycle"| DDC["MonitorController"]
    DDC -->|"native DDC/CI<br/>IOAVService or IOI2C"| Monitor
```

Recommended wiring is USB-C for the Apple Silicon Mac and USB-C/Thunderbolt 3
to HDMI for the 2019 Intel Mac. MA270U's USB-C input carries video, data, and
up to 90 W power.

### Native DDC/CI transport

`MonitorController` never shells out to a helper. `NativeDDCService` calls the
small `MacKVMNativeDDC` bridge on its serial queue, and the bridge exposes only
bounded display names, selectors, and success/error results to Swift:

```mermaid
flowchart LR
    MC["MonitorController"] --> SW["NativeDDCService"]
    SW --> C["MacKVMNativeDDC"]
    C -->|"Apple Silicon"| AV["IOAVService\nDCPAVServiceProxy"]
    C -->|"Intel"| I2C["IOI2C\nIOFramebuffer bus"]
    AV --> VCP["DDC/CI Set VCP 0x60"]
    I2C --> VCP
    VCP --> M["External monitor"]
```

Discovery is limited to 32 online external displays. Each display is selected
by a `native-ddc:` identifier derived from CoreGraphics/EDID vendor, model and
serial values; numeric display indexes are never sent to IOKit. The bridge
allow-lists the five input-source values used by the app and bounds all error
text before it returns to the UI. If the display transport is unavailable or
the monitor rejects DDC/CI, switching ends with a diagnostic and the user can
choose the monitor OSD explicitly.

### Cross-architecture DDC diagnostic tool

`Tools/DDCDiagnostic/ddc-diagnostic.m` is a standalone diagnostic client built
against the same native bridge as the app. `scripts/build-ddc-diagnostic.sh`
produces separate `arm64`, `x86_64`, and universal binaries, so a report can
be collected on both the M5 Pro and the 2019 Intel Mac without Homebrew or a
helper executable. The report combines system architecture/model data with
the native selector, EDID identity/checksum, transport (`IOAVService` on
Apple Silicon or `IOFramebuffer`/`IOI2C` on Intel), and VCP `0x60` readback.

The optional `--scan-inputs` path is deliberately separate from normal app
operation. It writes user-supplied candidate values only to VCP `0x60`, reads
each value back, labels a value `accepted=yes` only when the readback matches,
and restores the starting input. This distinguishes a transport-level I2C
success from a monitor firmware mapping. The tool never edits the app mapping
or reads identities, private keys, credentials, or network endpoints. The
tested MA270U mapping is USB-C `19` (`0x13`) and HDMI 1 `17` (`0x11`); other
models must be confirmed from their own report and scan. See the
[diagnostic guide](Tools/DDCDiagnostic/README.md) and
[source](Tools/DDCDiagnostic/ddc-diagnostic.m). Ctrl-C/SIGTERM stops the
candidate loop while still attempting to restore the starting input.

### Physical input topology (P0)

The monitor's HDMI input is a video path; it does not upstream the MA270U USB
hub to the Intel host. Therefore the recommended one-way topology is:

```mermaid
flowchart LR
    KM["External keyboard + mouse"] --> HUB["M5 Pro directly or MA270U USB hub"]
    HUB --> M5["M5 Pro / USB-C"]
    M5 -->|"MacKVM request + encrypted input"| INTEL["2019 Intel / HDMI target"]
    SWITCH["Optional external USB switch"] --> M5
    SWITCH --> INTEL
```

`InputTopologyController` persists an explicit mode on each Mac. **One
keyboard on M5 Pro (USB-C)** documents the external keyboard and mouse path,
but either Mac can initiate software control from its local keyboard, mouse, or
trackpad; HDMI still does not carry the monitor's USB hub upstream. **External
USB switch (bidirectional)** permits either host to see the external devices,
but the app cannot detect or validate that physical switch; manual verification
on both Macs is required. Receiving remote control remains available in either
mode.

## What needs to change before this is a real KVM

### Pairing issues resolved in Step 1

- Outbound and inbound pairing both enforce the pinned public key.
- Bonjour advertising and browsing begin only after the user handles the
  Local Network setup step, so its macOS prompt cannot race the input-permission
  prompts.
- Only one outbound pairing request can be active, and its verification code is
  cleared on every terminal path.
- Completing or cancelling a request clears its connection timeout and receive
  buffer.

### Remaining product validation

- The P2 release path now creates a fresh universal-image staging directory
  and a portable SHA-256 sidecar. Passing a Developer ID identity enables the
  hardened runtime and the release verifier checks it; Apple notarization is
  still required before distribution outside the developer's own Macs.
- Complete the real-hardware section in [`MANUAL_TEST.md`](MANUAL_TEST.md):
  verify native DDC/CI input-source VCP commands on both the M5 Pro and Intel
  connections, the OSD fallback, and the optional physical USB switch. Software
  cannot prove those behaviors without the monitor, two Macs, and macOS privacy
  prompts.

### Runtime responsibilities

The major runtime responsibilities are separated as follows:

```text
AppBootstrap            service wiring and Local Network-gated startup
PermissionOnboarding    sequential checklist, permission refresh, Settings links
LaunchAtLoginController SMAppService login-item state
PeerDiscoveryService    Bonjour pairing discovery and pairing session lifecycle
SecureSessionService    authenticated encrypted message channel
InputCaptureService     CGEventTap capture and Input Monitoring state
RemoteInputSink         validated CGEvent injection and Accessibility state
ControlRequestNotifier  native incoming-control notification and stale-action guard
MonitorController       DDC-capable display discovery, stable native selection, diagnostics, OSD fallback
PairingRegistry         paired-peer persistence
PairedPeerProfile        friendly name, model, connection time, key fingerprint,
                         seamless control authorization
DeviceCredentialsStore  Keychain identity persistence
```

Input capture uses the main display bounds on each Mac. Configure the MA270U as
the main display on both computers so normalized pointer positions map to the
same physical screen. Control uses a request/grant exchange. A newly paired
peer can use the receiver's local one-time authorization; otherwise the
receiver must confirm the request before events are suppressed locally and
forwarded remotely.
The controller can press **Control–Option–Command–Escape** to interrupt sharing,
while the receiver can use **Return keyboard, mouse, and trackpad to [M5 Mac]** to release
injected input and return control to the controller.
The global **Control–Option–Command–K** shortcut toggles the same route: it
starts a normal control request while idle and returns input when either side
is actively controlling or receiving. The independent
**Control–Option–Command–O** shortcut shares the guarded **Show other Mac**
route: it changes the monitor input before requesting keyboard, mouse, and trackpad control,
and ends receiving to restore the controller's display and input.

The public Quartz event path preserves trackpad movement, clicks, drags,
secondary clicks, precise two-axis scrolling, and scroll phase and momentum.
The capture tap subscribes to keyboard, mouse, scroll-wheel, and NSSystemDefined
types only, and `CGEvent` publishes constructors for keyboard, mouse, and scroll
wheel alone, so multi-touch gestures are neither captured nor injectable through
public API: pinch, rotate, smart zoom, three- and four-finger swipes, Mission
Control, App Exposé, and Launchpad remain local to the controlling Mac. The
pressure value on a click is carried; the `NSEventTypePressure` stage transition
is not, so force click does not activate on the receiver.

`SecureSessionService` remembers only a user-selected paired peer for automatic
reconnect. `NSWorkspace` sleep/wake notifications close the active transport
before networking suspends, preserve that reconnect intent, and restart secure
discovery after wake. `NWPathMonitor` pauses attempts while the network path is
unavailable and resumes with a bounded exponential backoff (0/1/2/4…30 seconds)
after a path or Bonjour update. A deliberate Disconnect, Forget, or app stop
clears the desired peer. Reconnection returns both Macs to a local-input state;
a peer with seamless authorization can be granted again automatically, while an
opted-out peer must confirm the request again.

Control requests carry a protocol-version range and the current macOS
physical-keyboard-layout identifier (from `TISCopyCurrentKeyboardLayoutInputSource`,
so switching an input method like Zhuyin on or off is not a layout change). A
mismatched protocol-version range is denied before the receiver's consent
prompt, as is a differing keyboard layout when the requesting peer's version
is below the v2 that added character-based remapping — that peer would never
send the character field remapping needs, so admitting it would only grant
control to end it on the first remappable keystroke. A v2 peer's differing
layout is not denied, since `RemoteInputSink` resolves it instead. Each
`keyDown` for a letter, digit, or symbol key also carries the character the
sender's own layout and modifier state produced for it. When the receiver's
layout differs, it looks up which local key produces that same character —
built once per layout change into a `KeyboardLayoutReverseMap`, and reused for
the rest of a held key's auto-repeat so a modifier changing mid-hold cannot
retarget a live press to a different local key — and injects that key instead
of the sender's keycode, which would mean something else under a different
layout. What happens to the injected event's flags then depends on whether
Command or Control was held. For plain typing, Shift/Option/Caps Lock are
replaced with whatever combination the local layout needs to reproduce the
sender's character. For a key held with Command or Control, the character
used for that lookup is always the key's unmodified character — Shift and
Caps Lock never affect which local key is found — and every flag the sender
held, including a real Shift that selects a different shortcut such as Redo
instead of Undo, passes through completely unchanged: only the keycode came
from the lookup. This is what keeps Command-Z landing on the local key that
actually produces "z" on a layout where Y and Z are swapped (for example
German QWERTZ), without also letting an incidental Caps Lock turn Command-C
into Command-Shift-C. A key with no equivalent on the receiver's layout ends
remote input safely rather than injecting the wrong character. Keys outside
that letter/digit/symbol set
(arrows, Return, Tab, Delete, Escape, Space, function keys, and every
modifier) occupy the same physical position on every layout and are injected
by keycode exactly as before. Missing identifiers remain accepted for legacy
peers, while new peers use the negotiation fields.

If the local identity/keychain pair becomes inconsistent, the bootstrap error
view exposes an explicit reset operation. It deletes the Keychain key and
stored identity together, clears local pairings, and requires a relaunch and
new pairing. It never rotates identity automatically.

### Runtime safety boundaries

The network and input layers use explicit bounded queues and buffers rather than
assuming a cooperative peer:

- pairing and secure-session frames are limited to 64 KiB; encrypted session
  plaintext is limited to 32 KiB;
- each pairing transport delivery processes at most 16 framed messages; a
  larger burst is rejected with a message-count error rather than decoded as
  an unbounded batch;
- secure-session decoding batches at most 16 frames at a time but may drain
  multiple batches for high-polling input; its 64 KiB buffer and packet/byte
  budgets remain the cumulative bounds;
- incomplete secure frames time out after five seconds, and secure sessions
  enforce limits on pending connections, queued payloads, packets, and bytes;
- Bonjour pairing accepts only bounded connection/message rates and rejects
  conflicting records for the same UUID;
- the coordinator and injection queue each have a 256-item admission gate. A
  full gate closes the session and releases tracked input, so key-up or
  mouse-up transitions are never silently discarded;
- `Forget` removes the pinned key before cross-service cleanup begins, then
  advances a per-peer generation so late pairing completions cannot re-add the
  trust record. Secure-session revoke also cancels all anonymous handshakes,
  because an unauthenticated context cannot yet be attributed to a different
  peer; an unrelated handshake may therefore need to retry after Forget.

These limits are enforced before JSON decoding or event injection where
possible. They are defensive availability controls; the encrypted channel and
signed identity checks remain the authorization boundary.

The CGEvent teardown path is OS-dependent; manual QA should verify that ending
remote control releases held regular keys, modifiers, and mouse buttons while
preserving locally held modifiers. Pure modifier projection and admission
behavior are covered by the automated test suite.

## How to use the current MVP

1. Connect both Macs to the same trusted local network.
2. Connect the 14-inch Apple Silicon Mac to MA270U by USB-C, and connect the
   2019 MacBook Pro to an MA270U HDMI input using a Thunderbolt 3/USB-C to HDMI
   adapter.
3. In **System Settings → Displays → Arrange**, make the MA270U the main
   display on both Macs.
4. In the MacKVM menu, keep **One keyboard on M5 Pro (USB-C)** for the
   current wiring and connect the external keyboard/mouse to the M5 Pro or its MA270U
   USB hub. HDMI cannot carry the monitor hub upstream to the Intel Mac. Only
   select **External USB switch (bidirectional)** after both Macs visibly see
   the devices through a physical switch.
5. On the M5 Pro, build both architecture-specific app bundles:

   ```sh
   ./scripts/build-app.sh --arch arm64
   ./scripts/build-app.sh --arch x86_64
   ```

   Copy `dist/arm64/MacKVM.app` into `/Applications` on the M5 Pro and
   `dist/x86_64/MacKVM.app` into `/Applications` on the 2019 Intel Mac. On
   each Mac, launch the installed app:

   ```sh
   open /Applications/MacKVM.app
   ```

   Do not use `swift run` for normal operation: the generated `.app` carries
   the Bonjour and Local Network privacy metadata required by macOS.
6. MacKVM appears as a KVM/display-sharing icon in the menu bar and as a
   regular Dock app with a full control window. Open either entry and complete
   **Set up this Mac** in order: select **Enable Local Network**, answer the
   macOS prompt and select **I handled the macOS prompt**, then request Input
   Monitoring and Accessibility one at a time. Returning from System Settings
   refreshes the checklist; **Review Local Network Settings** remains available
   for a prior Local Network denial because macOS does not expose its result to
   MacKVM.
7. After that checklist finishes, select **Enable** next to **Control request
   notifications**. This optional macOS alert permission should be handled
   before the first request, outside its short consent window. A control
   request never triggers this authorization sheet by itself; without alerts,
   MacKVM adds a warning symbol beside its KVM menu-bar icon and retains the
   menu and window controls.
8. Optionally enable **Launch MacKVM at Login** so the menu-bar icon returns
   automatically after signing in.
   Login-item startup keeps the full window hidden; the menu-bar entry and Dock
   activation remain available to open it on demand.
9. After the Local Network step is complete, open the MacKVM menu-bar item on
   either Mac to inspect nearby devices.
10. Under **Nearby Macs**, select **Pair** on one Mac.
11. Compare the six-digit security code shown on both Macs. Verify the peer name
    on each Mac, then press **Accept** on the receiver and **Confirm code** on
    the initiator only when the codes match.
12. On either Mac, select **Detect DDC-capable displays** and choose the
    intended display explicitly before selecting the matching preset. Native
    DDC/CI uses `IOAVService` on Apple Silicon and `IOI2C` on Intel. Test
    **Show other Mac**. If the display does not expose DDC/CI, follow the
    diagnostic and use the monitor OSD.
13. After the receiver accepts and the initiator confirms the matching code, the
    app automatically attempts to connect the encrypted session. If it remains idle, select **Connect** on
    one paired row. When the encrypted session is connected, **Show other Mac**
    on the physical-input M5 Pro follows the guarded display-first path and
    starts the keyboard, mouse, and trackpad request when its prerequisites are
    ready. **Share keyboard, mouse, and trackpad with [Intel Mac]** is the
    explicit equivalent.
14. The controlling Mac needs both Input Monitoring and Accessibility because
    its active event tap suppresses local input while forwarding it. The
    receiving Mac must select **Allow** before input is sent only to the
    other Mac unless seamless control is enabled for that pinned peer. With the
    menu closed, it can use the native notification's
    **Allow**, **Deny**, or **Review in MacKVM** action; Review opens an
    explicit approval dialog, Allow requires macOS authentication if the
    receiver is locked, and old/expired actions are ignored. Press
    **Control–Option–Command–Escape** or use **Return keyboard, mouse, and trackpad to
    this Mac** on the controller; the receiver can also select **Return
    keyboard, mouse, and trackpad to [M5 Mac]**. If DDC cannot switch the monitor, follow the diagnostic and
    select the requested input through the OSD. A display-only route can be
    restored with **Return display to this Mac**, even when the global
    emergency shortcut could not be registered.

After an authenticated transport loss, the selected peer is retried with
bounded backoff and no new pairing. A seamless-authorized peer does not need a
fresh Allow action; an opted-out peer does. Use **Disconnect** or **Forget** to
clear the reconnect intent. The emergency shortcut or the receiver's
**Return keyboard, mouse, and trackpad to [M5 Mac]** action ends an active or waiting
remote-control request before restoring the local display and input. If
the bootstrap screen reports an identity/keychain mismatch, use its
explicit reset action, relaunch, and pair both Macs again.

Before testing, macOS may ask for local-network access. Pairing metadata and
Bonjour names are visible on the LAN, while established control-session payloads
are encrypted; see [`SECURITY.md`](SECURITY.md).
