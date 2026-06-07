# Wispr Flow for Linux (unofficial)

[![CI](https://github.com/wispr-flow-linux/wispr-flow-linux/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/wispr-flow-linux/wispr-flow-linux/actions/workflows/ci.yml?query=branch%3Amain)
[![License: Unlicense](https://img.shields.io/badge/license-Unlicense-blue.svg)](UNLICENSE)

Hey! These are build scripts to run the proprietary **Wispr Flow** voice-dictation
app natively on Linux. I wanted Wispr Flow on my Linux machine, so this repo
repackages the Windows installer and pairs it with a **clean-room Rust helper**.
That helper reimplements the one native capability Wispr Flow ships only for macOS
and Windows: injecting transcribed text into your focused application.

**This is an unofficial port.** I'm not affiliated with Wispr. For the official
app and support, see [wisprflow.ai](https://wisprflow.ai). If you hit a
build-script or Linux issue,
[open an issue](https://github.com/wispr-flow-linux/wispr-flow-linux/issues) here.

**Documentation:** full docs at [`docs/index.md`](docs/index.md). Build details
in [`docs/building.md`](docs/building.md). Release history in
[`CHANGELOG.md`](CHANGELOG.md). Contributing: [`CONTRIBUTING.md`](CONTRIBUTING.md).
Security: [`SECURITY.md`](SECURITY.md).

## Status

The app **launches** on Linux with the Linux helper wired in, the UI renders, and
text injection is validated on KDE Plasma Wayland. Packaging now ships **`.deb`,
`.rpm`, and AppImage** for **amd64 and arm64** — signed APT/DNF repos, an AUR
package, and GitHub Release assets all publish on each tag (see
[Installation](#installation)). Nix is wired (`flake.nix`) but not yet a release
target. I list the validated environments in
[`docs/compatibility.md`](docs/compatibility.md), and the design rationale lives
in [`docs/decisions.md`](docs/decisions.md).

> [!NOTE]
> arm64 is built and published but not hardware-validated yet — the helper's
> VM-matrix sweep ran on x86_64 only.

## Installation

Prebuilt packages ship for **amd64 and arm64** with every release. Pick the
channel for your distro; the repo channels update with your normal system
upgrades. Full details — signature verification, uninstall, per-format notes —
are in [`docs/installation.md`](docs/installation.md).

### APT (Debian/Ubuntu)

```bash
curl -fsSL https://pkg.wispr-flow-linux.dev/KEY.gpg | sudo gpg --dearmor -o /usr/share/keyrings/wispr-flow.gpg
echo "deb [signed-by=/usr/share/keyrings/wispr-flow.gpg arch=amd64,arm64] https://pkg.wispr-flow-linux.dev stable main" | sudo tee /etc/apt/sources.list.d/wispr-flow.list
sudo apt update && sudo apt install wispr-flow
```

### DNF (Fedora/RHEL)

```bash
sudo curl -fsSL https://pkg.wispr-flow-linux.dev/rpm/wispr-flow.repo -o /etc/yum.repos.d/wispr-flow.repo
sudo dnf install wispr-flow
```

### AUR (Arch Linux)

```bash
yay -S wispr-flow-appimage   # or: paru -S wispr-flow-appimage
```

### Manual download

Grab a `.deb`, `.rpm`, or `.AppImage` from the
[Releases page](https://github.com/wispr-flow-linux/wispr-flow-linux/releases).

> [!NOTE]
> These published packages bundle the proprietary Wispr Flow app, downloaded from
> Wispr's official endpoint at build time. Wispr Flow is a trademark of its
> owners; this is an unofficial community port. Prefer to supply the installer
> yourself? [Build from source](#building) instead.

## Supported environments

I developed the Rust helper ([its own repo](https://github.com/wispr-flow-linux/helper))
and swept it across a libvirt VM matrix. That sweep ran on x86_64 only, so arm64
is wired through but not hardware-validated yet:

| Environment | Text injection | Active window / focus | Selection |
|---|---|---|---|
| **KDE Plasma (Wayland)** — validated | `uinput` + `wl-clipboard` | KWin script over D-Bus | AT-SPI |
| **GNOME (Wayland)** | shared Wayland backend | `org.gnome.Shell.Introspect` | AT-SPI |
| **wlroots / other Wayland** | `uinput` + `wl-clipboard` | generic Wayland | AT-SPI |
| **X11** | XTEST | `_NET_*` window properties | AT-SPI |

Text injection needs write access to `/dev/uinput`. The bundled udev rule grants
that through the logind `uaccess` ACL, with the `input` group as a cross-distro
fallback. Push-to-talk additionally needs read access to `/dev/input/event*`.

## Building

You supply the Wispr Flow installer, and the repo never bundles or commits it.
Build a package with:

```bash
# Build an .rpm from a Wispr Flow installer you obtained yourself
./build.sh --build rpm --exe ~/Downloads/"Wispr Flow Setup-v1.5.695.exe"
```

`--exe` is required. The pipeline never fetches, bundles, or hosts the
proprietary installer.

Here are the common options (`./build.sh --help` lists all):

- `-b, --build <deb|rpm|appimage|nix>` — package format (default: auto-detected)
- `--arch <amd64|arm64>` — target architecture (default: host)
- `-e, --exe <path>` — path to the installer .exe you supply (required)
- `-c, --clean <yes|no>` — remove intermediate build files when done

I cover prerequisites, the Linux Electron download, the native sqlite rebuild, and
the mandatory launcher rename in [`docs/building.md`](docs/building.md).

## Configuration

I documented the environment variables, state locations, the uinput udev rule,
clipboard dependencies, the GNOME extension, and AT-SPI in
[`docs/configuration.md`](docs/configuration.md).

## Troubleshooting

Run `wispr-flow --doctor` first. It's the built-in diagnostic, and it checks the
display server / session, `/dev/uinput` access, clipboard tooling, the GNOME
extension, AT-SPI, push-to-talk input access, and the launcher rename. When
something breaks, I keep symptom-keyed fixes in
[`docs/troubleshooting.md`](docs/troubleshooting.md).

## License

Build scripts and the Rust helper in this repository are released into the public
domain under the [Unlicense](UNLICENSE). The Wispr Flow application itself is
proprietary and subject to its own terms.
