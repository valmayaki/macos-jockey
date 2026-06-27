# MountJockey

MountJockey is an open-source macOS menu-bar application that keeps SMB shares
mounted when their servers become reachable. Connectivity is transport-neutral:
it works over Tailscale, WireGuard, OpenVPN, ordinary LANs, and other routed
networks.

This project is an MIT-licensed fork of
[othyn/macos-jockey](https://github.com/othyn/macos-jockey).

## Features

- Multiple independently configured SMB shares
- Menu-bar status, mount, unmount, pause/resume auto-mount, enable/disable, and Finder controls
- Passwords stored only in the macOS login Keychain
- Passwords never included in SMB URLs, process arguments, configuration, or logs
- DNS and TCP port 445 readiness checks before mounting
- Automatic retries after login, network changes, sleep/wake, and disconnects
- Serialized mount operations to prevent duplicate attempts
- Debounced sleep/wake recovery to avoid mount churn while networking settles
- Stable mount-point recovery with stale and busy mount detection
- Configurable absolute mount points, with safety checks for dangerous paths
- Rotating log at `~/Library/Logs/mountjockey.log`
- Native Apple Silicon and Intel support
- macOS Ventura 13 or newer

## Default share

The first launch starts empty. Add your SMB share from Preferences:

```text
Host:        <your SMB host>
Share:       <share name>
Username:    <your username>
Mount point: ~/Volumes/data
```

Open Preferences from the menu-bar icon, add the share details, and enter the
SMB password. MountJockey stores it in Keychain and starts mounting after the
configured host:445 becomes reachable. Unmounting a share pauses auto-mount
until you explicitly resume it from the menu bar or Preferences.

If you previously launched an older build, the legacy default NAS entry is
removed automatically on first launch so you can enter the correct share in the
UI.

## Install from source

Requirements:

- macOS Ventura 13 or newer
- Xcode or Xcode Command Line Tools
- Access to the SMB server

```bash
git clone https://github.com/valmayaki/macos-jockey.git
cd macos-jockey
./install.sh
```

The installer builds a universal, ad-hoc-signed application and installs it at:

```text
~/Applications/MountJockey.app
```

It opens the app after install. Enable **Launch MountJockey at login** in
Preferences if you want it to start automatically for your user session.

## Build and test

```bash
swift test
./scripts/build-release.sh
```

The release artifacts are written to `build/MountJockey.zip` and
`build/MountJockey.dmg`.

To install from the DMG, open `build/MountJockey.dmg` and drag MountJockey to
`Applications` if you want a system-wide install, or to `~/Applications` for a
user-local install.

## Security model

- Share configuration contains no password field.
- Passwords use a generic-password item in the login Keychain.
- NetFS receives credentials directly in process memory.
- The SMB URL contains only host and share.
- Reachability uses a direct TCP connection to port 445.
- The default `mount_smbfs` backend uses `soft,nobrowse` and a forced new SMB session.
- The application has no telemetry, analytics, or external API calls.
- Hardened Runtime is enabled for release builds.
- Log files are created with owner-only permissions.
- Removing a share prompts for confirmation.

The public release is ad-hoc signed rather than Apple-notarized. macOS may require
explicit approval in **System Settings → Privacy & Security** after downloading.
Do not grant Full Disk Access; MountJockey does not require it.

### Mount point rules

Mount points must be absolute paths. The app rejects `/`, `/Volumes`, dangerous
system locations such as `/Library` or `/System`, symlinks, and non-empty
existing directories.

If you want an explicit system mount path, use a dedicated child directory such
as `/Volumes/data` and create it once if needed:

```bash
mkdir -p /Volumes/data
```

No root daemon is installed or used.

## Troubleshooting

```bash
nc -vz nas.taila7f773.ts.net 445
tailscale ping nas.taila7f773.ts.net
mount | grep smbfs
tail -f ~/Library/Logs/mountjockey.log
security find-generic-password -s com.valmayaki.mountjockey.smb
```

MountJockey intentionally checks the SMB endpoint rather than requiring a
specific VPN command. A successful TCP/445 connection proves that the route is
available and that something is listening on the SMB port; the actual mount step
still verifies SMB authentication and the mount table.

For terminal workflows, keep each share configured to one stable mount path such
as `~/Volumes/data`. MountJockey remounts to that same path and avoids replacing
a stale mount while another process is still using it. If a shell was already
inside the share during a real SMB disconnect, macOS may still require you to
`cd` back into the same path so the shell resolves a fresh filesystem handle.

## Uninstall

```bash
./uninstall.sh
```

Preserve configuration, logs, and Keychain credentials by default, or remove
configuration and logs:

```bash
./uninstall.sh --purge
```

Review or delete retained credentials in Keychain Access.
If you want the app to stop starting at login, disable the toggle in Preferences
or remove the login item in System Settings.

## Validation

These checks show the expected runtime state after a successful mount. If you
use Tailscale, the first command is a useful connectivity sanity check:

```bash
launchctl list | grep tailscale
mount | grep /Volumes/data
tailscale ping nas.taila7f773.ts.net
```

## License

MIT. Original copyright remains with Ben Tindall. Fork modifications are
copyright © 2026 Valentine Ubani Mayaki.
