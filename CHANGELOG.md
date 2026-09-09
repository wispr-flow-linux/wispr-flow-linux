# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Semantic versioning applies to the wrapper (`REPO_VERSION`); the bundled Wispr
Flow app version is tracked separately by the `+wispr{X.Y.Z}` suffix.

## [Unreleased]

### Fixed

- On X11 the Hub window opened as an unmanaged (override-redirect) window:
  pinned above every other window, missing from Alt+Tab, and impossible to
  move, minimize, or maximize. Upstream creates the window with `focusable:!1`
  on every platform and only macOS restores focus later, so Linux inherited
  Electron's override-redirect treatment of non-focusable windows. The new
  `linux-hub-focusable.sh` patch rewrites the Hub config so `focusable` is
  true on Linux only, leaving the shipped macOS and Windows behavior
  untouched. (#36)

## [v1.0.3] - 2026-06-11

### Fixed

- `wispr-flow --doctor` reported `Helper binary: present and executable` (and
  an overall pass) for a helper that aborted on startup, because the check
  only stat-ed the file. The doctor now execs the binary (`--version` probe
  with stdin at EOF, 5s timeout, fd 3 discarded) and surfaces the captured
  stderr — e.g. the loader's `GLIBC_2.39 not found` — on failure. (#16)
- Local builds failed at packaging with `Linux helper not staged` because the
  prebuilt helper was only fetched in CI; staging now auto-fetches the release
  pinned in `helper-version.txt` when `HELPER_BIN` is unset. An explicit
  `HELPER_BIN` (e.g. a local helper build) is still honored and never fetched
  over. (#15)
- `build.sh` emitted `readonly variable` errors when dispatching staging:
  `APP_VERSION`/`ELECTRON_VERSION` are readonly, so the command-prefix env
  assignments were rejected and `build-linux.sh` silently fell back to its own
  defaults. The version constants are now exported instead. (#15)
- A previously fetched helper in `helper-bin/` was reused forever, so bumping
  `helper-version.txt` silently kept shipping the stale binary in local builds.
  `fetch-helper-bin.sh` now stamps the fetched tag (`helper-bin/.tag`) and
  staging refetches when the stamp disagrees with the pin. A manual pre-drop
  (no stamp) and an explicit `HELPER_BIN` are still used as-is.

### Changed

- Helper pin bumped to `v0.1.2`: the helper now supports a `--version` flag,
  the launch probe `wispr-flow --doctor` uses to catch binaries that abort on
  startup (wispr-flow-linux/helper#3, groundwork for #16).
- Helper pin bumped to `v0.1.1`: the helper binaries are now built on Ubuntu
  22.04 (glibc 2.35 floor), so they no longer abort on startup with
  `GLIBC_2.39 not found` on Ubuntu 22.04-era distros (wispr-flow-linux/helper#1).
- The prebuilt native sqlite addons now build and release from their own repo
  (`wispr-flow-linux/native-modules`) instead of this one, mirroring the helper —
  so these CI-consumed artifacts no longer inflate the main project's Release
  download counts. `fetch-native-bin.sh` pulls from the new repo (pin unchanged
  in `native-modules-version.txt`); the local from-source rebuild is now opt-in
  via `WISPR_NATIVE_REBUILD=1` (was an automatic fallback) and never runs by
  default or in CI.
- `build.sh` now downloads the Wispr Flow installer from Wispr's official
  endpoint by default (resolving it via `resolve-installer-url.sh`, the same path
  CI uses), so `--exe` is no longer required. Pass `--exe <path>` to build
  against a local installer instead. The auto-download verifies the resolved
  version matches the pinned `APP_VERSION` and aborts on a mismatch.

## [v1.0.2] - 2026-06-07

### Fixed

- Package shipped `resources/` and its subdirectories as `0700` root-only, so a
  non-root user couldn't traverse them to reach `app.asar` or the helper and the
  app crashed on launch. All three makers now force directories to `0755` after
  staging; artifact tests assert `resources/` is other-traversable. (Regression
  from the `%defattr(-, root, root, -)` change in v1.0.1.)

## [v1.0.1] - 2026-06-07

### Added

- End-user install documentation: `docs/installation.md` plus a README
  Installation section (APT, DNF, AUR, AppImage, manual).
- AppImage auto-update metadata: CI embeds `gh-releases-zsync` update info and
  emits a companion `.AppImage.zsync`.
- `wispr-flow --doctor` install-integrity checks: chrome-sandbox setuid,
  Electron runtime, desktop entry, and free disk.

### Changed

- README opening rewritten in declarative style; Status and Supported-environments
  sections removed.
- rpm spec hardened: `%defattr` default and explicit `%global debug_package %{nil}`.
- `verify-patches.sh` dropped `set -e` per the bash styleguide.

### Fixed

- rpm could ship a non-setuid / missing chrome-sandbox; the setuid `4755` bit is
  now baked into the FHS tree and the build fails on "File listed twice".
- `build.sh --clean` was a no-op; it now prunes intermediates while keeping the
  package and `downloads/`.
- `build-linux.sh` staged a stale version (`APP_VERSION` default `1.5.619` →
  `1.5.695`).

## [v1.0.0] - 2026-06-07

Initial release — unofficial Linux repackaging of Wispr Flow (1.5.695) as
`.deb` / `.rpm` / AppImage for amd64 and arm64, with the clean-room Rust helper
(text injection, clipboard, global key capture), the Linux platform-gate
patches, Nix flake, docs tree, and the tag-driven release/publish pipeline.

[Unreleased]: https://github.com/wispr-flow-linux/wispr-flow-linux/compare/v1.0.3+wispr1.5.751...HEAD
[v1.0.3]: https://github.com/wispr-flow-linux/wispr-flow-linux/compare/v1.0.2+wispr1.5.751...v1.0.3+wispr1.5.751
[v1.0.2]: https://github.com/wispr-flow-linux/wispr-flow-linux/compare/v1.0.1+wispr1.5.695...v1.0.2+wispr1.5.695
[v1.0.1]: https://github.com/wispr-flow-linux/wispr-flow-linux/compare/v1.0.0+wispr1.5.695...v1.0.1+wispr1.5.695
[v1.0.0]: https://github.com/wispr-flow-linux/wispr-flow-linux/releases/tag/v1.0.0+wispr1.5.695
