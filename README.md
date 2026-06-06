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

We're at Phase 0, and here's what that means in practice. The app **launches** on
Linux with the Linux helper wired in, the UI renders, and text injection is
validated on KDE Plasma Wayland. Packaging is partway there: **`.rpm` builds
today**; `.deb` and AppImage are stubbed (in progress); Nix is deferred. I list
the validated environments in
[`docs/compatibility.md`](docs/compatibility.md), and the design rationale lives
in [`docs/decisions.md`](docs/decisions.md).

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
./build.sh --build rpm --exe ~/Downloads/"Wispr Flow Setup-v1.5.619.exe"
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
