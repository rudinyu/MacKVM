[繁體中文](UNINSTALL.zh-TW.md)

# Uninstall MacKVM

For ordinary removal, quit MacKVM and double-click **Uninstall MacKVM.command**
in the mounted release image. The helper removes only a validated
`/Applications/MacKVM.app`; it preserves pairing trust, the identity key,
preferences, and macOS privacy permissions. You can also move `MacKVM.app` from
Applications to the Trash in Finder.

If **Launch MacKVM at Login** is enabled, remove MacKVM from **System Settings
> General > Login Items**. macOS may also retain Local Network, notification,
and firewall entries for manual review.

## Explicitly erase saved data

The optional purge permanently removes this account's MacKVM trust and
preferences, the exact identity Keychain item, and supported TCC permissions.
After reinstalling, other devices still retain their old pairing pins; use
**Forget** on those devices and pair again. This cannot be undone by reinstalling.

To review the purge actions first, keep the release image mounted, open
Terminal, and run these commands from the image's root folder:

```sh
./scripts/uninstall-app.sh --purge --dry-run
./scripts/uninstall-app.sh --purge
```

The purge asks for a separate confirmation unless `--yes` is supplied. Do not
run the whole script with `sudo`; preferences, Keychain items, and permissions
belong to the signed-in user. See [INSTALL.md](INSTALL.md) for the full removal
scope and remaining macOS cleanup steps.
