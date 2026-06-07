# Documentation

Hey! This is the build, configuration, and operations manual for the unofficial
[Wispr Flow for Linux](../README.md) port. The README out front is the
storefront. This is where I keep the manual.

```bash
# If you're here because text injection broke:
wispr-flow --doctor
# Then check troubleshooting.md below.
```

My advice after a lot of broken sessions: start with `--doctor`, then jump to
the page that matches what you're actually trying to do. If you want the *why*
behind a decision, the [decision log](decisions.md) has it. Validated
environments live in [compatibility.md](compatibility.md). And the helper's wire
protocol — the contract everything else hangs off — is in
[`reference/ipc-contract.md`](reference/ipc-contract.md).

## Installation & building

- [**Building from source**](building.md) — `./build.sh`, format flags, the
  Electron download, the native sqlite rebuild, the mandatory launcher rename
- [**Configuration**](configuration.md) — env vars, where state lives, the
  uinput udev rule, clipboard deps, the GNOME Shell extension, AT-SPI
- [**Troubleshooting**](troubleshooting.md) — symptom-keyed fixes, reading
  `--doctor` output
- [**Compatibility**](compatibility.md) — validated compositors / display
  servers and the access requirements per backend

## Releasing & distribution

- [**Releasing**](../RELEASING.md) — the tag scheme, the one-time prerequisites
  (vars, secrets, `gh-pages`, AUR, Worker), and what CI does on a tag push
- [**APT/DNF + redirect Worker**](learnings/apt-worker-architecture.md) — how
  binaries reach users without hitting GitHub's 100 MB push cap

## Project direction

- [**Decision log**](decisions.md) — ADR-format record of what we ship and why
  (Rust helper, in-process uinput, clipboard paste, AT-SPI, the launcher rename)

## How the port works — subsystem deep-dives

This is the stuff I learned the hard way building the Linux helper and the
packaging pipeline — the things you can't get from reading the code alone. Read
the relevant one before you go poking at a subsystem; it'll save you the same
afternoon it cost me. Each deep-dive walks through one non-obvious mechanic and
the ways it bites.

- [**Learnings overview**](learnings/index.md) — index of the deep-dives below
- [**KWin / zbus / tokio**](learnings/kwin-zbus-tokio.md) — the async-zbus-on-tokio
  dispatch deadlock that left KDE active-app empty, and the fix
- [**GNOME Shell extension**](learnings/gnome-shell-extension.md) — install,
  relogin requirement, the MRU focus fallback, the Introspect pivot
- [**Electron 42 / V8 14.8 / sqlite**](learnings/electron42-v8-sqlite.md) — the
  V8 14.8 ABI patch that lets `better-sqlite3-multiple-ciphers` compile
- [**The isPackaged / launcher rename**](learnings/ispackaged-rename.md) — why an
  `electron`-named launcher silently breaks DB migrations ("no such table")
- [**Wayland injection**](learnings/wayland-injection.md) — in-process `/dev/uinput`
  virtual keyboard + `ext-data-control` clipboard

## Testing

- [**Testing overview**](../tests/README.md) — bats unit tests, artifact tests,
  the Rust helper suite, and the manual VM-matrix validators

## Style guides

- [**Bash style guide**](styleguides/bash_styleguide.md) — the project's shell
  conventions (forked from YSAP)
- [**Docs style guide**](styleguides/docs_styleguide.md) — how to write and
  organize docs (start here if you're adding a page)

## Reference

- [**IPC contract**](reference/ipc-contract.md) — the stdin/fd-3
  protocol the helper speaks: command surface, wire framing, message shapes,
  keycodes (with companion `keycodes.json` / `commands.json`)
- [**scripts/README.md**](../scripts/README.md) — the Phase-0 packaging pipeline
  step-by-step
