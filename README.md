# Wispr Flow for Ubuntu

[![License: Unlicense](https://img.shields.io/badge/license-Unlicense-blue.svg)](UNLICENSE)

Build scripts to run **Wispr Flow** voice-dictation on Ubuntu. Repackages the Windows installer and pairs it with a clean-room Rust helper that injects transcribed text into your focused application.

**Compatible with Ubuntu only (amd64 and arm64).**

## Installation

```bash
curl -fsSL https://pkg.wispr-flow-linux.dev/KEY.gpg | sudo gpg --dearmor -o /usr/share/keyrings/wispr-flow.gpg
echo "deb [signed-by=/usr/share/keyrings/wispr-flow.gpg arch=amd64,arm64] https://pkg.wispr-flow-linux.dev stable main" | sudo tee /etc/apt/sources.list.d/wispr-flow.list
sudo apt update && sudo apt install wispr-flow
```

Updates arrive with your regular `sudo apt upgrade`.

## Building from source

```bash
# Downloads the Wispr Flow installer automatically
./build.sh --build deb

# Or point it at an installer you already have
./build.sh --build deb --exe ~/Downloads/"Wispr Flow Setup-v1.5.695.exe"
```

See [`docs/building.md`](docs/building.md) for full build details.

## Configuration

See [`docs/configuration.md`](docs/configuration.md) for env vars, uinput udev rule, clipboard deps, and GNOME Shell extension setup.

## Troubleshooting

```bash
wispr-flow --doctor
```

See [`docs/troubleshooting.md`](docs/troubleshooting.md) for symptom-keyed fixes.

## Documentation

- [Building](docs/building.md)
- [Configuration](docs/configuration.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Compatibility](docs/compatibility.md)
- [Changelog](CHANGELOG.md)
