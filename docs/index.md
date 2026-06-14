# Documentation

Build, configuration, and operations manual for Wispr Flow for Ubuntu.

```bash
# If you're here because text injection broke:
wispr-flow --doctor
# Then check troubleshooting.md below.
```

Start with `--doctor`, then jump to the page that matches what you're trying to do. Validated environments live in [compatibility.md](compatibility.md). The helper's wire protocol is in [`reference/ipc-contract.md`](reference/ipc-contract.md).

## Installation & building

- [**Installing**](installation.md) — APT repository setup, updating, and uninstalling
- [**Building from source**](building.md) — `./build.sh`, the Electron download, the native sqlite rebuild, the mandatory launcher rename
- [**Configuration**](configuration.md) — env vars, where state lives, the uinput udev rule, clipboard deps, the GNOME Shell extension, AT-SPI
- [**Troubleshooting**](troubleshooting.md) — symptom-keyed fixes, reading `--doctor` output
- [**Compatibility**](compatibility.md) — validated compositors / display servers and the access requirements per backend

## Project direction

- [**Decision log**](decisions.md) — ADR-format record of what ships and why

## Subsystem deep-dives

- [**Learnings overview**](learnings/index.md) — index of deep-dives
- [**KWin / zbus / tokio**](learnings/kwin-zbus-tokio.md) — the async-zbus-on-tokio dispatch deadlock and the fix
- [**GNOME Shell extension**](learnings/gnome-shell-extension.md) — install, relogin requirement, MRU focus fallback
- [**Electron 42 / V8 14.8 / sqlite**](learnings/electron42-v8-sqlite.md) — the V8 14.8 ABI patch
- [**The isPackaged / launcher rename**](learnings/ispackaged-rename.md) — why an `electron`-named launcher breaks DB migrations
- [**Wayland injection**](learnings/wayland-injection.md) — in-process `/dev/uinput` virtual keyboard + `ext-data-control` clipboard

## Testing

- [**Testing overview**](../tests/README.md) — bats unit tests, artifact tests, and manual validators

## Style guides

- [**Bash style guide**](styleguides/bash_styleguide.md)
- [**Docs style guide**](styleguides/docs_styleguide.md)

## Reference

- [**IPC contract**](reference/ipc-contract.md) — the stdin/fd-3 protocol the helper speaks
- [**scripts/README.md**](../scripts/README.md) — the packaging pipeline step-by-step
