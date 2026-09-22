# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Semantic versioning applies to the wrapper (`REPO_VERSION`); the bundled Wispr
Flow app version is tracked separately by the `+wispr{X.Y.Z}` suffix.

## [Unreleased]

### Fixed

- `./build.sh` without `--exe` works again. Wispr repointed the stable
  "latest" redirect at a versionless web-bootstrap stub with no payload, so
  `resolve-installer-url.sh` died on every build and the nightly bump workflow
  failed since 2026-09-14 (#83). The resolver now reads the JSON manifest the
  stub itself uses (`latest.json`: versioned full-installer URL plus a
  published SHA-256) and emits `SHA256=` as a third key (#55, by
  @khamsakamal48).
- The AppImage build no longer fails AppStream validation on hosts with
  `appstream-glib` (Arch): the generated metadata dropped the `<icon>`
  element `appstream-util` rejects; the icon resolves from the `.desktop`
  file's `Icon=` key (#55, by @khamsakamal48).
- Fresh Linux profiles were seeded with the macOS shortcut map, so
  push-to-talk landed on keycode `-1` (no such key on Linux): Settings showed
  a blank binding, dictation could not be triggered, and the onboarding
  shortcuts step could not be completed (#33, #46). The renderer already
  showed Windows chords, but the main process writes the profile with its own
  `"win32"===process.platform` flag. The new `linux-main-shortcut-defaults.sh`
  widens that flag only where the shortcuts module reads it (eight ternary
  chord selections on 1.6.897) and fails closed if any read there is not a
  ternary, so the flag's other consumers keep the real platform (#55, by
  @khamsakamal48). Only new profiles are affected; an existing profile keeps
  its `-1` binding until the shortcut is re-recorded in Settings.
- Two bundle patches silently stopped matching the Wispr 1.6.7xx+ main
  bundle, and the marker gate correctly refused to build 1.6.897:
  `helper-env.sh` (upstream hoisted the helper's telemetry-only spawn env
  into a factory, so the `env:{` spawn-site anchor found nothing and the
  helper fell to the no-op `stub` injection backend) now anchors on the
  `{sentryDSN:` object itself, wherever it lives (#55, by @khamsakamal48);
  `linux-window-frame.sh` (upstream inserted `frame:!1` between the two keys
  the anchor spanned) now matches the win32 window config as a brace-fenced
  property bag instead of exact text. Both carry near-miss bats fixtures
  copied from the shipped 1.6.897 bytes.
- On X11 the Hub window opened as an unmanaged (override-redirect) window:
  pinned above every other window, missing from Alt+Tab, and impossible to
  move, minimize, or maximize. Upstream creates the window with `focusable:!1`
  on every platform and only macOS restores focus later, so Linux inherited
  Electron's override-redirect treatment of non-focusable windows. The new
  `linux-hub-focusable.sh` patch rewrites the Hub config so `focusable` is
  true on Linux only, leaving the shipped macOS and Windows behavior
  untouched. (#36)
- Launching a second instance while the app was running crashed with
  `SIGABRT` (`V8 FATAL: Error::ThrowAsJavaScriptException napi_throw`).
  Upstream only requests the single-instance lock at the end of its main
  bundle, so a second launch fully initialised native modules, the database
  and the helper before quitting, and tearing that down aborted. The new
  `linux-early-singleton.sh` patch takes the lock before the webpack IIFE
  and exits at once when it is not acquired; the running primary still gets
  `second-instance` and focuses its Hub, and `--quit-app` and `wispr-flow:`
  deep links still reach it (#51, by @jcartu).
- Dragging the status pill on Wayland never moved it and left a dimming
  overlay that swallowed clicks and scroll until Escape was pressed: the
  drag moves the window to absolute coordinates, which native Wayland
  ignores. The new `linux-disable-pill-drag.sh` patch forces the drag-overlay
  activation flag false on Linux at the one handler that enacts it, so the
  gesture is a no-op and no overlay appears (#66, by @crafteraadarsh).

### Added

- The upstream installer is pinned in-tree: `scripts/setup/installer-pin.sh`
  holds the version, download URL and SHA-256 the build downloads and
  verifies. `build.sh` reads `APP_VERSION` from it, the CI build workflows
  download and `sha256sum -c` it, and a digest mismatch is fatal. `--exe`
  stays the local override (warned about, never rejected, when its digest is
  not the pin's; `WISPR_EXE_SHA256` enforces one). `docs/decisions.md` D-010
  records the decision (#83).
- `scripts/setup/write-installer-pin.sh` rewrites the pin from the resolver's
  `URL=`/`VERSION=`/`SHA256=` output, validating every field and refusing a
  partial write. `tests/installer-pin.bats` covers the pin's shape, the
  writer, the manifest resolver (driven over `file://`), the pinned fetch's
  digest gate and cache, the `--exe` warning, and the `extract/` reuse check.
- `extract_installer` refuses to reuse an `extract/` tree holding a different
  Wispr version than the build wants (read from the nupkg name inside it),
  instead of silently staging the wrong bundle under the pinned label.

- The headless launch smoke test in `tests/test-artifact-common.sh` now reads
  the helper's injection-backend line from `launcher.log` after the readiness
  marker and fails on `stub` (or on no backend line at all). This is the
  assert that would have caught the `helper-env.sh` no-op: the app reached
  helper-ready and recorded fine while nothing was ever typed.

- `docs/learnings/test-methodology.md`: the shell-test discipline ported from
  claude-desktop-debian (the `run`-subshell counter trap, near-miss fixtures,
  real-tool FAIL branches, host-state isolation, launch-smoke blind spots, the
  mutation check), grounded on this repo's bats and artifact suites.

### Changed

- A `-rc` suffix on the wrapper version (`v1.0.4-rc.1+wispr1.6.897`) builds,
  tests and creates a GitHub pre-release, but the APT, DNF and AUR publish jobs
  skip it. The suffix is dropped from the package version so the rc assets are
  the ones the final tag would ship. This is the manual look-first path for a
  publish chain that is otherwise automatic and fails closed (D-011).
- `check-wispr-version.yml` is now the only thing that resolves upstream. It
  reads `latest.json`, rewrites the pin (version, URL, sha256 together) and
  the Nix version, commits, updates `WISPR_FLOW_VERSION`, and tags; it also
  re-pins when upstream re-publishes the same version with new bytes (no
  re-tag) and refuses to bump onto a manifest without a digest. The hardcoded
  `APP_VERSION` constant in `build.sh` is gone; `test-flags.yml` and
  `build-linux.sh`'s standalone default read the pin.
- `docs/learnings/patching-minified-js.md` gains the sibling project's newer
  lessons: quote classes for string anchors, callee-indirection call shapes,
  bounded `[^{}]` preludes (adjacency), developer-literal terminators, anchors
  that survive their own patch, per-anchor file resolution, and the
  shared-gate rule (grep every consumer before flipping a predicate), each
  regrounded on a patch or PR in this repo.

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
