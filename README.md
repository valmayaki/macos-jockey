# MountJockey

MountJockey is an open-source macOS menu-bar application that keeps SMB shares
mounted when their servers become reachable. Connectivity is transport-neutral:
it works over Tailscale, WireGuard, OpenVPN, ordinary LANs, and other routed
networks.

This project is an MIT-licensed fork of
[othyn/macos-jockey](https://github.com/othyn/macos-jockey).

## Features

- Multiple independently configured SMB shares
- Menu-bar status, mount, unmount, enable/disable, and Finder controls
- Passwords stored only in the macOS login Keychain
- Passwords never included in SMB URLs, process arguments, configuration, or logs
- DNS and TCP port 445 readiness checks before mounting
- Automatic retries after login, network changes, sleep/wake, and disconnects
- Serialized mount operations to prevent duplicate attempts
- Configurable user-owned or `/Volumes` mount points
- Rotating log at `~/Library/Logs/mountjockey.log`
- Native Apple Silicon and Intel support
- macOS Ventura 13 or newer

## Default share

The first launch creates this editable configuration:

```text
Host:        nas.taila7f773.ts.net
Share:       data
Username:    ubani
Mount point: ~/Volumes/data
```

Open Preferences from the menu-bar icon and enter the SMB password. MountJockey
stores it in Keychain and starts mounting after `nas.taila7f773.ts.net:445`
becomes reachable.

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

Enable **Launch MountJockey at login** in Preferences.

## Build and test

```bash
swift test
./scripts/build-release.sh
```

The release archive is written to `build/MountJockey.zip`.

## Security model

- Share configuration contains no password field.
- Passwords use a generic-password item in the login Keychain.
- NetFS receives credentials directly in process memory.
- The SMB URL contains only host and share.
- Reachability uses a direct TCP connection to port 445.
- The application has no telemetry, analytics, or external API calls.
- Hardened Runtime is enabled for release builds.

The public release is ad-hoc signed rather than Apple-notarized. macOS may require
explicit approval in **System Settings → Privacy & Security** after downloading.
Do not grant Full Disk Access; MountJockey does not require it.

### Custom mount paths on newer macOS versions

macOS 26.4 and newer may show a system confirmation when an application mounts a
network share outside `/Volumes`. If unattended mounting at `~/Volumes/data` is
blocked, configure `/Volumes/data` and create it once:

```bash
sudo mkdir -p /Volumes/data
sudo chown "$USER":staff /Volumes/data
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
specific VPN command. A successful TCP/445 connection proves that the route and
SMB service are available.

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

## License

MIT. Original copyright remains with Ben Tindall. Fork modifications are
copyright © 2026 Valentine Ubani Mayaki.
