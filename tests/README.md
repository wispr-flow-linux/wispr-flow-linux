# Tests

Hey! Here's how I test this thing locally. There are two tiers, and I've ordered
them fastest → most environment-dependent (the Rust helper is tested in its own
repo — more on that below).

## 1. bats unit tests (fast, no build needed)

This is where I start, every time. Pure-shell tests of the launcher library and
the diagnostics — no artifact, no display, no root needed.

```bash
bats tests/*.bats
```

| File | Covers |
|------|--------|
| `launcher-common.bats` | `scripts/launcher-common.sh`: logging paths, `check_display`, `detect_display_backend`, `build_electron_args` (sandbox/GPU/Wayland flag selection), `setup_electron_env`, `cleanup_stale_lock`, `wispr_config_dir`. |
| `doctor.bats` | `scripts/doctor.sh`: the `_pass`/`_fail`/`_warn` counter, display/clipboard/helper/singleton-lock checks (driven with stubbed tool presence and temp fixtures), and `run_doctor` exit status. |
| `verify-patches.bats` | `scripts/verify-patches.sh`: PASS when every Linux patch marker is present in a fixture app.asar, exit 1 when any one is omitted (omit-one matrix), exit 2 on bad usage. |
| `linux-patches.bats` | `scripts/patches/linux-{renderer-chrome,window-frame,renderer-treat-as-windows,deeplink}.sh`: each patch applied to a hermetic minified-JS fixture carrying its anchor — asserts the transformation + marker, leaves unrelated sites alone, `node --check`s the result, is idempotent (second run is byte-identical), and bails non-zero when the anchor is absent. |

Don't have bats yet? Grab it: `sudo dnf install bats` / `sudo apt install bats`.

## 2. Artifact tests (inspect built packages; install is CI-only)

This tier looks at an actual built package. Each
`test-artifact-<fmt>.sh <artifact-dir>` runs in two tiers of its own:

- **Inspection** — always runs, no install, safe on any machine: package
  metadata, FHS file placement (`/usr/bin/wispr-flow`,
  `/usr/lib/wispr-flow/{launcher-common.sh,doctor.sh,wispr-flow,chrome-sandbox}`,
  the helper binary, udev rule, desktop file, icons), `wl-clipboard`
  dependency, launcher-script content, and the Linux patch markers in
  `app.asar` (via `scripts/verify-patches.sh`).
- **Install + smoke** — CI containers only, **opt-in via
  `WISPR_ARTIFACT_INSTALL=1` and root**: installs the package, checks
  on-disk files + setuid `chrome-sandbox`, runs `--doctor`, and does a headless
  `xvfb-run` + `dbus-run-session` launch that polls `launcher.log` for the
  helper-ready marker (`Helper service is ready: true`). **Skipped with a clear
  message when not root or when tooling is missing** — so these scripts are
  safe to run locally; they will not system-install.

```bash
# Inspection-only locally (these will NOT install on a non-root box):
tests/test-artifact-rpm.sh       build-linux/rpm/rpmbuild/RPMS/x86_64
tests/test-artifact-deb.sh       build-linux/deb
tests/test-artifact-appimage.sh  build-linux/appimage   # extracts AppImage or uses staged AppDir
```

> One thing I'll keep shouting about: do NOT `sudo rpm -i` / `sudo dpkg -i` the
> package on a dev machine — that would install the proprietary Wispr Flow
> system-wide. The install tier is meant for clean CI containers; locally, only
> the inspection tier ever runs.

If you go digging, the shared assertion lib plus `validate_app_contents` /
`run_launch_smoke_test` all live in `test-artifact-common.sh`.

## 3. Helper tests (separate repo)

You won't find the helper tests here anymore — I moved the clean-room Rust helper
into its own repo,
[github.com/wispr-flow-linux/helper](https://github.com/wispr-flow-linux/helper).
That's where its Rust unit tests (`cargo test` + `fmt --check` +
`clippy -D warnings`) live, along with the Python integration validators (the IPC
harness, the clipboard/focus/injection round-trips, and the libvirt VM matrix).
This repo only ever consumes the helper's prebuilt release binary — pinned by tag
in `helper-version.txt`.
