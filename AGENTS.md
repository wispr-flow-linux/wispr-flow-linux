# AGENTS.md

<!--
  This file is read by AI tools that support the agents.md vendor-neutral
  standard. The content below is duplicated in CLAUDE.md (read by Claude
  Code) so that contributors using either receive the same instructions
  without needing to cross-reference. Keep CLAUDE.md and AGENTS.md
  byte-identical below the H1 title (the sync-policy comment above is the
  one place they intentionally differ) — if you edit one, edit the other.
-->

## Required reading

These documents are the source of truth. If anything in this file conflicts with
them, they win. Read them before opening a non-trivial issue or PR.

- [`docs/reference/ipc-contract.md`](docs/reference/ipc-contract.md) — the IPC
  contract the clean-room helper implements: command surface, wire framing,
  message shapes, keycodes (with companion `keycodes.json` / `commands.json`).
  The technical source of truth for helper behaviour.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — what we accept, what goes upstream to
  Wispr, the bash + Rust style requirements, the AI-attribution policy.
- [`docs/index.md`](docs/index.md) — entry point for the operator/contributor
  docs (building, configuration, troubleshooting, decisions, learnings).
- [`docs/styleguides/bash_styleguide.md`](docs/styleguides/bash_styleguide.md) —
  shell conventions (forked from YSAP). Tabs, 80 cols, `[[ ]]`, no `set -e`.
- [`SECURITY.md`](SECURITY.md) — vulnerability reporting; what's in scope vs.
  what belongs to Wispr.

This file is a fast reference for the highest-leverage rules and the project's
accumulated conventions. New policy goes in the style guides or CONTRIBUTING.md.

## Project overview

This is an **unofficial** Linux port of the proprietary **Wispr Flow**
voice-dictation app (an Electron 42 / electron-forge app shipped as a Squirrel
Windows installer). It is two things:

1. A **repackaging pipeline** (`scripts/`, `build.sh`) that extracts the app,
   patches its bundle for Linux, rebuilds native modules, stages a Linux
   Electron, and produces `.deb` / `.rpm` / AppImage packages.
2. A **clean-room Rust helper** that reimplements the one native capability Wispr
   Flow ships only for macOS (Swift) and Windows (C#): injecting transcribed text
   into the focused application. It is built from the documented IPC contract
   (`docs/reference/`) and contains **no Wispr Flow code**. The helper
   lives in its own repo
   ([github.com/wispr-flow-linux/helper](https://github.com/wispr-flow-linux/helper));
   this repo consumes its prebuilt binary, pinned in `helper-version.txt` and
   staged via the `HELPER_BIN` env var.

## Repo layout

- `build.sh` — top-level orchestrator: dispatches the staging pipeline and the
  per-format packaging makers (`--build deb|rpm|appimage`, `--clean`,
  `--doctor`).
- `scripts/`
  - `setup/` — host detection, dependency install, Wispr Flow / Electron
    download helpers.
  - `patches/` — the app patches: `helper-resolver.sh` (adds the `'linux'`
    helper-path branch), `mac-gates.sh` (gates the macOS Applications-folder
    guard to darwin), and the V8 14.8 `better-sqlite3-multiple-ciphers` compat
    patch. `verify-patches.sh` static-greps the repacked bundle for the markers.
  - `packaging/` — `deb.sh`, `rpm.sh`, `appimage.sh` makers; shared signature
    `<maker>.sh <dist_dir> <version> <arch>`.
  - `launcher-common.sh` — the runtime `/usr/bin/wispr-flow` launcher library.
  - `doctor.sh` — the `wispr-flow --doctor` diagnostic surface.
  - `build-linux.sh` — the Phase-0 staging pipeline (see safety rules below).
- the clean-room Rust helper now lives in a separate repo
  ([github.com/wispr-flow-linux/helper](https://github.com/wispr-flow-linux/helper));
  this repo consumes its prebuilt binary, pinned in `helper-version.txt` and
  staged via the `HELPER_BIN` env var.
- `docs/reference/` — the documented stdin/fd-3 IPC protocol (`ipc-contract.md`
  + `keycodes.json` / `commands.json`).
- `tests/` — bats unit tests, per-format artifact tests, the Rust test runner,
  and the manual VM-matrix validators.
- `docs/` — building / configuration / troubleshooting / decisions / learnings /
  style guides.
- `nix/`, `flake.nix` — Nix packaging.
- `.github/workflows/` — CI gates only (shellcheck, codespell, test-flags,
  bats). No package-build, release, or publish workflows; packaging is
  local-only and hosting/publishing infra was removed.

## Code style

### Bash

All shell scripts follow the
[Bash Style Guide](docs/styleguides/bash_styleguide.md):

- Tabs for indentation, lines under 80 chars (exception: URLs and regex).
- `[[ ]]` for conditionals, `$(...)` for substitution.
- Single quotes for literals, double quotes for expansions.
- Lowercase variables; UPPERCASE only for constants/exports.
- `local` in functions. **No `set -e`** (it interacts badly with `$(...)`
  capture and function returns — check status explicitly: `cmd || handle_err`).
  No `eval`. No POSIX `[ ... ]`. No backticks.

Lint with `shellcheck` (and `actionlint` for workflows) before pushing. Fix the
underlying issue; a per-line `# shellcheck disable=SCXXXX` with a why-comment is
the last resort.

### Rust

The helper's code and its `cargo fmt` / `cargo clippy --all-targets -- -D
warnings` / `cargo test` gates live in its own repo
([github.com/wispr-flow-linux/helper](https://github.com/wispr-flow-linux/helper)).
This repo consumes the prebuilt binary pinned in `helper-version.txt`.

### Docs / CHANGELOG

- One declarative sentence then a code block or list at the top of every doc
  page — no "In this guide we will…" preamble.
- Lowercase kebab-case filenames in `docs/`. Order lives in `docs/index.md`.
- Troubleshooting headings are the literal symptom, not editorialized prose.
- `CHANGELOG.md` follows [Keep a Changelog
  1.1.0](https://keepachangelog.com/en/1.1.0/): bullets under
  Added/Fixed/Changed/etc.

## ⚠️ Safety rules — read before running anything

- **NEVER run `scripts/build-linux.sh` blindly.** Its step 2 does
  `rm -rf build-linux/`, which **destroys the validated staged tree**. Use
  `build.sh` with the appropriate flags, or scope to a single step, when you
  just want to inspect or rebuild part of the pipeline.
- **NEVER commit the proprietary payload.** The Wispr Flow installer `.exe`, the
  extracted `index.js`, and the `build-linux/` / `extract/` scratch trees are
  gitignored. This pipeline repackages a binary **you** supplied — it never
  fetches, bundles, commits, or uploads any proprietary Wispr Flow binary.

## Learnings

The [`docs/learnings/`](docs/learnings/index.md) directory holds hard-won
technical knowledge from building the port — things not obvious from the code
alone. Consult the relevant entry before working on a subsystem; add a new entry
when you discover something non-obvious that would save the next contributor
(human or AI) significant time.

- [`kwin-zbus-tokio.md`](docs/learnings/kwin-zbus-tokio.md) — the async-zbus-on-
  tokio dispatch deadlock that left KDE active-app empty, and the fix.
- [`gnome-shell-extension.md`](docs/learnings/gnome-shell-extension.md) — install,
  relogin requirement, MRU focus fallback, the Introspect pivot.
- [`electron42-v8-sqlite.md`](docs/learnings/electron42-v8-sqlite.md) — the V8
  14.8 ABI patch that lets `better-sqlite3-multiple-ciphers` compile.
- [`ispackaged-rename.md`](docs/learnings/ispackaged-rename.md) — why an
  `electron`-named launcher silently breaks DB migrations ("no such table").
- [`wayland-injection.md`](docs/learnings/wayland-injection.md) — in-process
  `/dev/uinput` virtual keyboard + `ext-data-control` clipboard.

## GitHub / CI workflow

- Use the `gh` CLI for GitHub interactions.
- Branch off issue numbers: `fix/123-description` or `feature/123-description`.
- Reference issues in commits/PRs with `#123` or `Fixes #123`.
- CI gates (`.github/workflows/ci.yml`): shellcheck, codespell, flag-parsing,
  and bats. That is the whole of CI — there are **no** package-build, release,
  or publish workflows. Packaging is local-only (`build.sh --build …`); hosting
  and publishing infra must not be reintroduced.

### Attribution

For PR descriptions, include full attribution:

```
---
Generated with [Claude Code](https://claude.ai/code)
Co-Authored-By: Claude <model-name> <noreply@anthropic.com>
<XX>% AI / <YY>% Human
Claude: <what AI did>
Human: <what human did>
```

Use the actual model name (e.g., `Claude Opus 4.8`); keep the split honest. For
issues/comments use the simplified form
`Written by Claude <model-name> via [Claude Code](https://claude.ai/code)`. For
commits, include a `Co-Authored-By: Claude <claude@anthropic.com>` trailer.
