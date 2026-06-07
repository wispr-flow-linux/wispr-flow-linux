[< Back to docs index](index.md)

# Installing Wispr Flow for Linux

Install a prebuilt, signed package for your distro — `.deb`, `.rpm`, and AppImage
ship for **amd64 and arm64** on every release.

```bash
# Debian/Ubuntu, the short version:
curl -fsSL https://pkg.wispr-flow-linux.dev/KEY.gpg | sudo gpg --dearmor -o /usr/share/keyrings/wispr-flow.gpg
echo "deb [signed-by=/usr/share/keyrings/wispr-flow.gpg arch=amd64,arm64] https://pkg.wispr-flow-linux.dev stable main" | sudo tee /etc/apt/sources.list.d/wispr-flow.list
sudo apt update && sudo apt install wispr-flow
```

> [!NOTE]
> These packages bundle the proprietary Wispr Flow app, downloaded from Wispr's
> official endpoint at build time. Wispr Flow is a trademark of its owners; this
> is an unofficial community port. To supply the installer yourself instead, see
> [building.md](building.md).

## Choose a channel

| Distro family | Channel | Auto-updates |
|---|---|---|
| Debian / Ubuntu | [APT repository](#apt-debianubuntu) | yes — `apt upgrade` |
| Fedora / RHEL | [DNF repository](#dnf-fedorarhel) | yes — `dnf upgrade` |
| Arch | [AUR `wispr-flow-appimage`](#aur-arch-linux) | yes — AUR helper |
| Any | [Manual `.deb` / `.rpm` / `.AppImage`](#manual-download) | no — re-download |

The repository channels are the recommended path: they pin the signing key and
pull new versions with your normal system updates. Architecture is auto-selected
(amd64 or arm64).

## APT (Debian/Ubuntu)

```bash
# 1. Pin the repository signing key
curl -fsSL https://pkg.wispr-flow-linux.dev/KEY.gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/wispr-flow.gpg

# 2. Add the repository
echo "deb [signed-by=/usr/share/keyrings/wispr-flow.gpg arch=amd64,arm64] https://pkg.wispr-flow-linux.dev stable main" \
  | sudo tee /etc/apt/sources.list.d/wispr-flow.list

# 3. Install
sudo apt update && sudo apt install wispr-flow
```

Updates arrive with your regular `sudo apt upgrade`.

## DNF (Fedora/RHEL)

```bash
# 1. Add the repository (the .repo file pins the signing key)
sudo curl -fsSL https://pkg.wispr-flow-linux.dev/rpm/wispr-flow.repo \
  -o /etc/yum.repos.d/wispr-flow.repo

# 2. Install
sudo dnf install wispr-flow
```

Both `gpgcheck` and `repo_gpgcheck` are on, so DNF verifies the package and the
repository metadata against the key at
`https://pkg.wispr-flow-linux.dev/KEY.gpg`. Updates arrive with
`sudo dnf upgrade`.

## AUR (Arch Linux)

The [`wispr-flow-appimage`](https://aur.archlinux.org/packages/wispr-flow-appimage)
package wraps the AppImage build and tracks each release.

```bash
yay -S wispr-flow-appimage
# or
paru -S wispr-flow-appimage
```

## Manual download

Grab a `.deb`, `.rpm`, or `.AppImage` for your architecture from the
[Releases page](https://github.com/wispr-flow-linux/wispr-flow-linux/releases),
then:

```bash
# Debian/Ubuntu
sudo apt install ./wispr-flow_*_amd64.deb

# Fedora/RHEL
sudo dnf install ./wispr-flow-*.x86_64.rpm

# AppImage — mark executable and run
chmod +x ./wispr-flow-*-x86_64.AppImage
./wispr-flow-*-x86_64.AppImage
```

The `.deb` / `.rpm` postinst installs the `/dev/uinput` udev rule for you. The
AppImage cannot run a root postinst, so install the rule once:

```bash
./wispr-flow-*-x86_64.AppImage --install-udev-rules
```

## After installing

Run the built-in diagnostic first — it checks the display server / session,
`/dev/uinput` access, clipboard tooling, the GNOME extension, AT-SPI,
push-to-talk input access, and the launcher rename:

```bash
wispr-flow --doctor
```

Text injection needs write access to `/dev/uinput` (granted by the bundled udev
rule via the logind `uaccess` ACL, with the `input` group as a fallback);
push-to-talk additionally needs read access to `/dev/input/event*`. Group changes
take effect on your next login. The full list of env vars, state locations, the
udev rule, clipboard dependencies, the GNOME Shell extension, and AT-SPI is in
[configuration.md](configuration.md); symptom-keyed fixes are in
[troubleshooting.md](troubleshooting.md).

## Updating

- **APT / DNF:** new releases install with your normal `sudo apt upgrade` /
  `sudo dnf upgrade`.
- **AUR:** re-run your AUR helper (`yay -Syu`).
- **Manual:** download the new asset and reinstall it.

## Uninstalling

```bash
sudo apt remove wispr-flow      # Debian/Ubuntu
sudo dnf remove wispr-flow      # Fedora/RHEL
yay -R wispr-flow-appimage      # Arch

# Also remove the repository channel if you added one:
sudo rm /etc/apt/sources.list.d/wispr-flow.list /usr/share/keyrings/wispr-flow.gpg   # APT
sudo rm /etc/yum.repos.d/wispr-flow.repo                                             # DNF
```

User state (config, logs) lives under the paths documented in
[configuration.md](configuration.md); remove those separately if you want a clean
slate.

## How distribution works

`pkg.wispr-flow-linux.dev` is a Cloudflare Worker that serves the APT/DNF metadata
and 302-redirects package downloads to the matching GitHub Release asset, so the
package bytes never hit GitHub's 100 MB push cap. The mechanics are in
[learnings/apt-worker-architecture.md](learnings/apt-worker-architecture.md); the
tag-driven publish flow is in [RELEASING.md](../RELEASING.md).

## See also

- [building.md](building.md) — build a package yourself from an installer you
  supply (no proprietary bytes bundled)
- [compatibility.md](compatibility.md) — validated compositors and per-backend
  access requirements
- [troubleshooting.md](troubleshooting.md) — `--doctor` output and symptom-keyed
  fixes
