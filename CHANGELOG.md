# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Semantic versioning applies to the wrapper (`REPO_VERSION`); the bundled Wispr
Flow app version is tracked separately by the `+wispr{X.Y.Z}` suffix.

## [Unreleased]

This entry documents the parity work that brought the repo up to the
`claude-desktop-debian` governance and tooling surface, on top of the validated
Phase-0 build (the app launches on Linux with the clean-room Rust helper wired
in, UI renders, and the core text-injection path is validated on KDE Plasma
Wayland — this is the baseline).

### Added

- **Global key capture in the helper** (`linux-helper-app/src/capture/`): emits
  the `KeypressEvent` IPC stream the app's keyboard service needs, so
  **push-to-talk and the in-app shortcut recorder now work** — the app has no
  hotkey detection of its own. Two backends, selected per session like
  `backend::detect`: **XInput2** raw key events on a true X11 session (no device
  access needed), and **evdev** (`/dev/input/event*`) on Wayland (and as the X11
  fallback). Both converge on the same VK codes via `keymap::evdev_to_vk` (the
  inverse of `vk_to_evdev`, with a roundtrip test). Adds a `CheckStaleKeys` →
  `StaleKeysResponse` handler answered from live kernel/X state. See
  [`docs/learnings/global-key-monitor.md`](docs/learnings/global-key-monitor.md).
- **Input-access provisioning for push-to-talk**: the deb/rpm/Nix udev rule now
  also grants `/dev/input/event*` read (was uinput-write only), installed and
  triggered by the existing post-install machinery. A new
  `wispr-flow --install-udev-rules` command installs the same rule via
  pkexec/sudo for AppImage / non-NixOS Nix, and `wispr-flow --doctor` gains a
  **Push-to-Talk (input monitor)** section checking `/dev/input` read access. The
  evdev read trade-off is documented in `SECURITY.md`.
- **Top-level `build.sh` orchestrator** dispatching the staging pipeline and the
  per-format packaging makers, with `--build`, `--clean`, and `--doctor` flags
  mirroring `claude-desktop-debian`.
- **Packaging makers** under `scripts/packaging/`: `deb.sh` and `appimage.sh`
  makers added alongside a refactored `rpm.sh`, all sharing the
  `<maker>.sh <dist_dir> <version> <arch>` signature. Run locally to build a
  package on your own machine, or via the gated tag-driven CI pipeline (see
  [`RELEASING.md`](RELEASING.md)).
- **Launcher library** `scripts/launcher-common.sh` (shared by the per-package
  `/usr/bin/wispr-flow` launcher) and **`scripts/doctor.sh`** implementing the
  `wispr-flow --doctor` diagnostic surface (display/session, `/dev/uinput`
  access, clipboard tooling, GNOME extension, AT-SPI, the launcher rename).
- **Test suites**: bats unit tests (`tests/doctor.bats`,
  `tests/launcher-common.bats`, `tests/verify-patches.bats`), per-format artifact
  tests (`tests/test-artifact-{deb,rpm,appimage}.sh` + shared common), and the
  Rust helper test runner (`tests/run-rust-tests.sh`).
- **CI workflows** under `.github/workflows/`: lint (shellcheck, codespell),
  flag-parsing, and bats gates run on every push/PR.
- **Tag-driven release & publish pipeline** (`ci.yml` plus reusable
  `build-amd64.yml` / `build-arm64.yml` / `test-artifacts.yml`, and
  `check-wispr-version.yml`, `apt-repo-heartbeat.yml`, `cleanup-runs.yml`,
  `update-flake-lock.yml`): a `v<repoVer>+wispr<wisprVer>` tag builds
  deb/rpm/AppImage for amd64 + arm64, attaches them to a GitHub Release, and
  publishes to the APT/DNF `gh-pages` tree and the `wispr-flow-appimage` AUR
  package, fronted by the `wispr-flow-linux/worker` Cloudflare Worker at
  `pkg.wispr-flow-linux.dev`. CI resolves and downloads the proprietary
  installer itself and stages the pinned prebuilt helper
  (`scripts/setup/resolve-installer-url.sh`, `scripts/setup/fetch-helper-bin.sh`).
  The chain runs on a `v*` tag push; see [`RELEASING.md`](RELEASING.md).
- **Nix flake** (`flake.nix`, `nix/wispr-flow.nix`, `nix/fhs.nix`) packaging the
  helper and the wrapped app.
- **Documentation tree** under `docs/` (building, configuration, troubleshooting,
  decisions, learnings deep-dives, and bash/docs style guides), indexed from
  `docs/index.md`.
- **Project governance / meta**: this `CHANGELOG.md`, `CONTRIBUTING.md`,
  `SECURITY.md`, the synced `AGENTS.md` / `CLAUDE.md` agent guide, GitHub issue
  templates (`.github/ISSUE_TEMPLATE/`), and `.github/CODEOWNERS`.

### Changed

- **`scripts/` restructured** into `setup/`, `patches/`, `packaging/`, and shared
  `_common.sh`, separating host detection / download, the app patches
  (`helper-resolver.sh`, `mac-gates.sh`, the V8 14.8 sqlite compat patch),
  and the per-format packaging makers.
- **`.codespellrc`** refined: skip list extended to cover the build scratch
  trees (`build-linux/`, `extract/`), vendored `tools/`, lockfiles, the
  proprietary `.exe`, `linux-helper-app/target/`, and the minified `index.js`;
  ignore-words list extended with project false-positives.

### Fixed

- **Injected `Ctrl+V` degraded to a bare `v`** (`linux-helper-app/src/backend/uinput.rs`):
  `UInput::chord` slept 8 ms between the modifier-down and the key-down "to let
  the compositor observe the modifier." On KWin/Wayland that quiescent gap makes
  the compositor *drop* the held modifier before the key arrives, so paste typed
  a literal `v` into the focused field. The chord now emits modifier→key→release
  as one contiguous batch with no inter-event sleep (each event still gets its
  `SYN_REPORT`). Verified with a GTK Wayland observer: 0 ms gap → modifier
  applied and full text pastes (5/5); ≥8 ms → dropped. See
  [`docs/learnings/wayland-injection.md`](docs/learnings/wayland-injection.md).
- **Text injection silently dead while recording worked** (`helper-env.sh`): the
  app spawns the helper with a *replacement* env object (telemetry keys only),
  not a spread of `process.env`, so the Linux helper inherited no
  `WAYLAND_DISPLAY`/`DISPLAY`/`XDG_RUNTIME_DIR`/`DBUS_SESSION_BUS_ADDRESS` and
  its backend detection fell through to the no-op `stub` injector —
  `PasteText failed: no backend available (stub)`. Keypress capture (evdev,
  needs no session env) kept push-to-talk and the recorder working, masking the
  break. A new surgical bundle patch prepends `...process.env,` to the spawn's
  env object; wired into `build-linux.sh` and enforced by `verify-patches.sh`
  (`WISPR_LINUX_HELPER_ENV`). See
  [`docs/learnings/helper-spawn-env.md`](docs/learnings/helper-spawn-env.md).
- **Left side menu shifted right with invisible window controls**
  (`linux-renderer-chrome.sh` + `linux-window-frame.sh`): the renderer adds the
  OS string as an `<html>` class, but every platform CSS rule is `.darwin`/
  `.win32` with **zero `.linux` rules**, so Linux inherited the mac-shaped base
  geometry — a 68px phantom traffic-light inset pushed the sidebar collapse
  toggle ~3-4 icon-widths right and rendered the min/max/close controls with no
  artwork. Linux now adopts the `.win32` stylesheet (class remapped linux→win32)
  and the hub/settings window is made frameless like Windows so the custom
  controls render. Markers `WISPR_LINUX_WIN32_CHROME` / `WISPR_LINUX_FRAMELESS`.
- **Fresh installs seeded macOS shortcut defaults; onboarding skipped permissions**
  (`linux-renderer-treat-as-windows.sh`): renderer shortcut/PTT defaults, glyph
  labels and the onboarding Permissions step are gated `isWindows ? … : …`, and
  `window.electron.platform` exposed no `isLinux`, so Linux took the macOS branch
  (unusable `fn`/⌘ combos) and skipped the permissions step. Each renderer now
  widens the single place it binds `isWindows` into a module-local
  (`…?.platform?.isWindows ?? false` → `(… || "linux" === …?.platform?.os)`),
  deriving the OS from the bridge it already reads. The bridge stays honest —
  `window.electron.platform.isWindows` still reports its real value (`false` on
  Linux) and no preload is touched, so a future `isWindows`-gated site can't
  silently fire. `isMacOS` is left false, keeping keycode/glyph paths on the
  Ctrl/Windows-VK side. Marker `WISPR_LINUX_RENDERER_ISWIN`. (Replaces the
  earlier preload-boolean flip `WISPR_LINUX_AS_WINDOWS`.)
- **Cold-start `wispr-flow:` deep links dropped** (`linux-deeplink.sh`): the
  argv parse that extracts the protocol URL at launch was win32-only (macOS uses
  `open-url`); launching from a link while the app wasn't running lost the URL.
  The guard now includes Linux (the warm-start `second-instance` path already
  worked). Marker `WISPR_LINUX_DEEPLINK`. All four patches are documented in
  [`docs/learnings/platform-gates.md`](docs/learnings/platform-gates.md).

### Removed

- **All package-hosting, release, and publish infrastructure.**
  Deleted the `publish-apt`/`publish-dnf`/`publish-aur`, `apt-repo-heartbeat`,
  `check-version`, `build-amd64`/`build-arm64`, and `test-artifacts` workflows
  (and the release/publish jobs in `ci.yml`); `RELEASING.md` and the
  package-worker learning; the remote `gh-pages` APT/DNF metadata branch; the
  release-pipeline repo variables; and the separate `wispr-flow-linux/worker`
  Cloudflare Worker repo (`pkg.wispr-flow-linux.dev`). Packaging is now
  local-only — `build.sh --build …` on the user's own machine — and CI runs
  only lint + unit-test gates.

[Unreleased]: https://github.com/wispr-flow-linux/wispr-flow-linux/commits/main
