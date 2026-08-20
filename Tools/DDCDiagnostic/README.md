# Native DDC diagnostic tool

[繁體中文說明](README.zh-TW.md)

`ddc-diagnostic` is a standalone, read-first diagnostic program for the
native DDC/CI bridge used by MacKVM. It is useful when a monitor reports a
successful I2C transaction but does not actually switch inputs, or when the
same input connector has different VCP values on different monitor firmware.

It reports:

- macOS version/build, hardware model, runtime architecture, and the
  architecture used to compile the tool;
- the native display selector, EDID manufacturer/product/serial/name, and
  checksum status;
- whether the display was reached through Apple Silicon `IOAVService` or
  Intel `IOFramebuffer`/`IOI2C`;
- the current/max/type response for VCP `0x60` (Input Source), when the
  display supports DDC/CI reads.

## Build

Build the tool on a Mac with the repository checkout:

```sh
./scripts/build-ddc-diagnostic.sh --arch arm64
./scripts/build-ddc-diagnostic.sh --arch x86_64
./scripts/build-ddc-diagnostic.sh --arch universal
```

The executables are written to `dist/ddc-diagnostic-arm64`,
`dist/ddc-diagnostic-x86_64`, and `dist/ddc-diagnostic-universal`. The
universal binary can be copied to either Mac.

## Read-only report

Run the architecture-matched binary and save the output for troubleshooting:

```sh
./dist/ddc-diagnostic-arm64 > arm64-ddc-report.txt 2>&1
./dist/ddc-diagnostic-x86_64 > x86_64-ddc-report.txt 2>&1
```

Use `--display 1` when more than one external display is listed. Use
`--vcp 0x10` (or another numeric code) to inspect a different VCP feature.
The report contains local display/system metadata only; it does not read
MacKVM identities, private keys, passwords, or network credentials.

## Find an input mapping

Writing VCP `0x60` and checking the readback is more reliable than trusting a
successful write result. A monitor can acknowledge an I2C write and silently
ignore a value it does not implement. The opt-in scan tests common input
values, reports `accepted=yes` only when the monitor reads the candidate back,
prints a final `input_scan.mapping` summary, and restores the value observed
before the scan:

```sh
./dist/ddc-diagnostic-universal --display 1 --scan-inputs \
  --values 15,16,17,18,19,27
```

Only run a scan when it is safe for the physical display to change inputs.
If the initial VCP value cannot be read, the tool does not claim that a value
is supported. If a display cannot read VCP replies, a successful write is
reported as transport evidence, not as a confirmed mapping. The diagnostic
write API is limited to VCP `0x60`; other VCP features can be inspected with
`--vcp` but are never changed by this tool. Ctrl-C or SIGTERM stops the
candidate loop and still attempts to restore the input observed before the
scan.

For the BenQ MA270U tested with this project, the observed mapping is HDMI 1
`17 (0x11)` and USB-C `19 (0x13)`. Other monitor models and firmware may use
different values; use the scan output as the evidence before changing the
application mapping.

## Native paths

The source is one architecture-aware program. On Apple Silicon it exercises
the same `IOAVService` path as the app. On Intel it exercises the same
`IOFramebuffer` + `IOI2CInterface` path. Build both architectures from the
same checkout so reports are directly comparable.

## Related project documentation

- [MacKVM installation guide](../../INSTALL.md)
- [MacKVM architecture](../../ARCHITECTURE.md)
- [Two-Mac acceptance test](../../MANUAL_TEST.md)
- [Security status](../../SECURITY.md)
