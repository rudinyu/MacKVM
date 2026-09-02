# MacKVM debugging guide

[繁體中文說明](DEBUGGING.zh-TW.md)

This guide describes how to collect useful diagnostics from both sides of a
MacKVM session. Use it when pairing, Secure Connect, keyboard/mouse control,
or monitor input switching does not behave as expected.

## Before collecting a report

- Reproduce one failure at a time and record the local time and time zone.
- Verify the exact MacKVM/WindowsKVM version and architecture on both hosts.
- Do not use `--yes` for a normal pairing or control test. It bypasses the
  local consent decision and can hide a consent or notification problem.
- Never publish private keys, `identity.json`, passwords, access tokens, or
  unredacted IP addresses. MacKVM's unified logs intentionally omit private
  keys, verification codes, and wire payloads. Windows console output can
  include a six-digit pairing code, peer IDs, device names, and endpoints;
  redact those fields before sharing a report.

## macOS

### Verify the installed build

The Mac UI shows the version and build in its header. The bundle metadata is a
machine-readable source of truth:

```sh
plutil -p /Applications/MacKVM.app/Contents/Info.plist \
  | grep -E 'CFBundleShortVersionString|CFBundleVersion|CFBundleIdentifier'
```

### Capture pairing, Secure Connect, and monitor logs

MacKVM writes unified logs through three public categories: `pairing`,
`secure-session`, and `monitor`. Start the live stream before reproducing the
failure:

```sh
log stream --style compact --level debug \
  --predicate 'subsystem == "app.mackvm.MacKVM" AND (category == "pairing" OR category == "secure-session" OR category == "monitor")' \
  | tee "$HOME/Desktop/MacKVM-live-$(date +%Y%m%d-%H%M%S).log"
```

Stop it with `Control-C` after the failure. To collect events that already
exist in the unified log, use:

```sh
log show --last 30m --style compact --info --debug \
  --predicate 'subsystem == "app.mackvm.MacKVM" AND (category == "pairing" OR category == "secure-session" OR category == "monitor")' \
  > "$HOME/Desktop/MacKVM-last-30m-$(date +%Y%m%d-%H%M%S).log"
```

Important stages include `phase=pairing.*`, `phase=handshake.*`,
`phase=transport.*`, `phase=input.*`, and `phase=monitor.*`. The log records
short request/peer identifiers and outcomes, not the six-digit verification
code or encrypted payload.

### Capture public support information

Use **Copy support information** in the MacKVM window and save the result with
the log. It contains public version, OS, hardware, display, and pairing
metadata only. Still review the text before posting it publicly because names,
short IDs, and network details can identify a machine.

### Test native DDC separately

When the failure is monitor input switching, first capture a read-only report:

```sh
./scripts/build-ddc-diagnostic.sh --arch universal
./dist/ddc-diagnostic-universal \
  > "$HOME/Desktop/MacKVM-ddc-$(date +%Y%m%d-%H%M%S).log" 2>&1
```

For a deliberate mapping test (the display will change inputs temporarily):

```sh
./dist/ddc-diagnostic-universal --display 1 --scan-inputs \
  --values 15,16,17,18,19,20,21,22,23,24,25,26,27
```

Only run the scan when it is safe to change the monitor input. See the
[native DDC guide](Tools/DDCDiagnostic/README.md) for the Apple Silicon
`IOAVService` and Intel `IOFramebuffer`/`IOI2CInterface` paths.

### Check discovery and physical connections

Use these read-only commands when a Mac cannot find its peer:

```sh
dns-sd -B _mackvm._tcp local
dns-sd -B _mackvm-secure._tcp local
system_profiler SPDisplaysDataType
ifconfig
```

Confirm that both Macs are on the same trusted network, the app has Local
Network permission, and the MA270U cable path exposes the expected USB-C or
HDMI input. A successful DDC write alone is not proof that the monitor
accepted the selected input; use the readback/scanning report.

## Windows

### Why the console mode is preferred for debugging

The Windows UI shows live status and native consent dialogs, but it detaches
from the console during startup. The Windows app currently has no persistent
file logger or Event Viewer provider. Run the same receiver in console mode to
retain the detailed pairing, mDNS, TCP, handshake, and input messages.

### Verify the executable and capture a complete log

Run this from the repository root or change `$exe` to the path of the copied
executable:

```powershell
$exe = ".\dist\windows\arm64\WindowsKVM.exe"
$log = Join-Path $env:USERPROFILE `
    ("Desktop\WindowsKVM-debug-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

& $exe --version
& $exe --pairing-listen --name "Windows ARM64" 2>&1 |
    Tee-Object -FilePath $log
```

Use `dist\windows\x64\WindowsKVM.exe` for Windows x86_64. Keep this window
open while reproducing one Pair and one Connect attempt. Stop the receiver
with `Enter` or `Control-C`. Do not add `--yes` unless the test specifically
needs automatic consent.

The startup output should include the pairing and Secure Connect TCP ports:

```text
Pairing listener ready on TCP ...
Advertised as _mackvm._tcp ...
Secure session listener ready on TCP ...
Advertised as _mackvm-secure._tcp ...
```

### Expected checkpoints

For pairing, look for:

```text
Incoming pairing connection from ...
Verification code: ...
Paired with ...
```

For Secure Connect and control, look for:

```text
Incoming secure-session connection from ...
Secure handshake response sent to ...
Secure session authenticated with ...
Windows control granted for ...
```

Useful failures include `mDNS ... network error`, `Pairing connection timed
out`, `peer is not paired`, `does not support the authenticated disconnect
signal`, and `Secure session connection closed`. Preserve the surrounding
lines; the sequence is usually more useful than a single error string.

### Check Windows network and firewall state

Run these read-only commands while the receiver is running:

```powershell
Get-NetConnectionProfile |
    Format-Table Name,InterfaceAlias,NetworkCategory,IPv4Connectivity,IPv6Connectivity

Get-NetFirewallProfile |
    Format-Table Name,Enabled,DefaultInboundAction,DefaultOutboundAction

Get-NetTCPConnection -State Listen |
    Sort-Object LocalPort |
    Format-Table LocalAddress,LocalPort,OwningProcess,State

ipconfig /all
```

The active network should be `Private` when the standard Windows Defender
Firewall prompt is shown. Allow WindowsKVM on the trusted Private network
only. The receiver prints its randomly selected ports; use those values when
checking a connection from the Mac. Do not create a broad inbound firewall
rule just to make discovery work.

For mDNS visibility, run these on the Mac while WindowsKVM is running:

```sh
dns-sd -B _mackvm._tcp local
dns-sd -B _mackvm-secure._tcp local
```

If no service appears, investigate the VM's network mode, multicast support,
VPN/Little Snitch rules, and the Windows Private-network firewall profile
before changing pairing code.

### Check trust state without exposing private material

```powershell
& $exe --list-paired
```

This prints trusted Mac names, full peer IDs, and public-key fingerprints. The
Windows identity private key is DPAPI-protected under
`%LOCALAPPDATA%\MacKVM`; do not copy or attach `identity.json`. Use
`--forget <peer-id>` only when deliberately revoking a pairing, then Pair
again before Connect.

## Interpreting a cross-platform report

- No Windows `Incoming pairing connection`: discovery, multicast, or firewall
  is failing before the pairing protocol starts.
- Pairing completes but Windows has no `Incoming secure-session connection`:
  the Mac is using a stale endpoint, or the Secure Connect listener is blocked.
- A handshake response is sent but authentication fails: compare versions,
  signed capability support, and the pinned public key on both hosts.
- Authentication succeeds but control is never granted: inspect the local
  consent dialog, the Windows input-admission state, and the Mac permission
  status.
- Monitor switching fails while pairing/control works: attach the native DDC
  report and identify the actual VCP `0x60` mapping for that display.

When reporting an issue, include the exact versions/architectures, the
reproduction steps, the relevant Windows console log and macOS unified-log
excerpt, and any DDC report. Redact verification codes, full IDs, IP
addresses, names, and all credential material before publishing.

## Related documentation

- [Windows build guide](WINDOWS_BUILD.md)
- [Native DDC diagnostic guide](Tools/DDCDiagnostic/README.md)
- [MacKVM architecture](ARCHITECTURE.md)
- [Two-Mac acceptance test](MANUAL_TEST.md)
