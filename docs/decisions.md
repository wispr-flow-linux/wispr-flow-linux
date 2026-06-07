[< Back to docs index](index.md)

# Decision Log

Hey! This is where I park the architectural calls that shape the Wispr Flow for
Linux port. What I picked, why I picked it, and what I turned down. It's an
ADR-format log, so each entry stays put.

I don't delete decisions. If I revisit one, I mark it `Superseded` and link
forward to the new one. Every entry carries a stable ID (`D-NNN`), a status, a
decision date, and an owner.

## Index

| ID | Date | Status | Title |
|---|---|---|---|
| [D-001](#d-001--rust-for-the-clean-room-helper) | 2026-06-04 | Accepted | Rust for the clean-room helper |
| [D-002](#d-002--in-process-devuinput-virtual-keyboard) | 2026-06-04 | Accepted | In-process `/dev/uinput` virtual keyboard |
| [D-003](#d-003--clipboard-based-paste-not-per-character-typing) | 2026-06-04 | Accepted | Clipboard-based paste, not per-character typing |
| [D-004](#d-004--at-spi-as-the-universal-active-app--selection-fallback) | 2026-06-04 | Accepted | AT-SPI as the universal active-app / selection fallback |
| [D-005](#d-005--per-compositor-active-app-providers) | 2026-06-04 | Accepted | Per-compositor active-app providers |
| [D-006](#d-006--rename-the-electron-launcher-to-wispr-flow) | 2026-06-04 | Accepted | Rename the Electron launcher to `wispr-flow` |
| [D-007](#d-007--clean-room-v8-148-patch-for-better-sqlite3-multiple-ciphers) | 2026-06-04 | Accepted | Clean-room V8 14.8 patch for `better-sqlite3-multiple-ciphers` |
| [D-008](#d-008--async-zbus-on-tokio-never-zbusblocking-for-services) | 2026-06-04 | Accepted | Async zbus on tokio, never `zbus::blocking` for services |

---

## D-001 — Rust for the clean-room helper

- **Status:** Accepted
- **Decided:** 2026-06-04
- **Owner:** @aaddrick

### Context

Wispr Flow ships its text-injection "Helper" only as macOS (Swift) and Windows
(C#) binaries. No Linux variant, and no source. I looked at the documented IPC
contract ([`reference/ipc-contract.md`](reference/ipc-contract.md)), and it
captures the whole interface. The helper is a thin shim over standard
desktop-automation primitives with **zero proprietary algorithms**. So the Linux
helper had to be written from scratch.

### Decision

I wrote the Linux helper fresh in **Rust** (it started in this repo, now it's its
own repo
[github.com/wispr-flow-linux/helper](https://github.com/wispr-flow-linux/helper)).
I built it against the documented IPC contract (`docs/reference/`), not by
porting the C#.

### Rationale

- **Single static binary, no runtime.** A Rust helper ships as one executable.
  There's no .NET runtime to bundle or version-match.
- **Raw `libc` ioctls for uinput** keep the binary dependency-free. No extra C
  deps, so it stays a single static binary.
- **Clean-room provenance.** I wrote from the documented IPC contract, not from
  the binary, so the helper carries no Wispr Flow code.
- **Mature Wayland/D-Bus/AT-SPI crates** (`wayland-client`, `zbus`, `atspi`)
  cover the hard surfaces.

### Consequences

- The helper is an independent reimplementation. It contains no upstream code.
- There's one ecosystem pin to manage: `atspi 0.22` is pinned to keep a single
  `zbus 4.x` in the tree (see
  [D-008](#d-008--async-zbus-on-tokio-never-zbusblocking-for-services)).

### References

- [`reference/ipc-contract.md`](reference/ipc-contract.md) — the IPC contract;
  [learnings/wayland-injection.md](learnings/wayland-injection.md).

---

## D-002 — In-process `/dev/uinput` virtual keyboard

- **Status:** Accepted
- **Decided:** 2026-06-04
- **Owner:** @aaddrick

### Context

Keystroke injection on Wayland has no XTEST equivalent that reaches native
surfaces. I had a few options. There's `ydotool` (uinput via a daemon, needs
perms), `wtype`, or the `libei`/portal RemoteDesktop path. That last one is the
newest, but compositor support is still uneven.

### Decision

I inject at the **kernel input layer**. The helper creates an **in-process
`/dev/uinput` virtual keyboard** and writes evdev events. libinput → compositor
routes them to the focused surface like a real keyboard. It's **in-process, no
`ydotoold` daemon, no root**.

### Rationale

- **Sidesteps the display-server gap.** Inject below the compositor and you
  reach every native Wayland surface. XTEST can't do that.
- **No daemon, no root.** You only need write access to `/dev/uinput`. The
  active-session user gets it via the logind `uaccess` udev rule, or the `input`
  group as a cross-distro fallback. That's a far smaller ambient capability than
  running a privileged daemon.

### Consequences

- **Accepted trade-off:** the port now leans on a udev rule plus `/dev/uinput`
  access. The packages ship the rule, and `--doctor` checks it. Without access,
  injection is dead. It fails loud, and the fix is clear.
- A ~200 ms settle delay is required so the compositor enumerates the device
  before the first event. Skip it and early keys drop.

### References

- [learnings/wayland-injection.md](learnings/wayland-injection.md).

---

## D-003 — Clipboard-based paste, not per-character typing

- **Status:** Accepted
- **Decided:** 2026-06-04
- **Owner:** @aaddrick

### Context

`PasteText` had two shapes. Either (a) set the clipboard and synth Ctrl+V, or
(b) type the text out character-by-character via synthetic key events. The
documented contract settles which one the upstream app does. It's the clipboard
path.

### Decision

I implemented `PasteText` as **clipboard-based**. The helper owns the clipboard
with `text/plain` + `text/html`, synths a Ctrl+V chord, and optionally restores
the prior clipboard. That matches the Windows helper exactly.

### Rationale

- **Matches upstream.** The Windows helper does `OpenClipboard` (with
  exponential backoff) → set `CF_UNICODETEXT` + `CF_TEXT` → `SendInput` Ctrl+V.
  Replicating it keeps behavior consistent.
- **Robust to text content.** Per-character synthesis has to map every character
  to keysyms and modifiers. Clipboard paste delivers arbitrary Unicode (and rich
  text) atomically.
- **Easier on Wayland.** The in-process clipboard owner via
  `ext_data_control_manager_v1` is focus-free, and it pairs naturally with the
  uinput Ctrl+V chord.

### Consequences

- The helper temporarily owns the clipboard. It restores the prior contents
  where it can (reads still shell out to `wl-paste`).
- Clipboard set replicates the Windows retry/backoff so it survives lock
  contention.

### References

- [`reference/ipc-contract.md`](reference/ipc-contract.md) —
  the `PasteText` mechanism.

---

## D-004 — AT-SPI as the universal active-app / selection fallback

- **Status:** Accepted
- **Decided:** 2026-06-04
- **Owner:** @aaddrick

### Context

`GetSelectedTextViaCopy` originally used a destructive Ctrl+C copy-probe, which
mutates the clipboard. And on Wayland compositors with no KDE/GNOME bridge (Sway,
Hyprland), there's no portable "focused app" protocol at all.

### Decision

I use **AT-SPI2** as the proper, non-destructive selection reader. It reads the
focused accessible's `Text` interface over the a11y bus. It also serves as the
**universal active-app provider for non-KDE/GNOME compositors**. The Ctrl+C
copy-probe stays, but only as a fallback.

### Rationale

- **Non-destructive selection.** AT-SPI reads the selection without touching the
  clipboard or synthesizing keys.
- **Compositor-agnostic.** Where there's no KWin/GNOME bridge, AT-SPI is the only
  thing that exposes window/app identity portably.

### Consequences

- The helper has to call `set_session_accessibility(true)` (it's idempotent) so
  toolkits expose their trees. That includes KDE, where the active-app provider
  is the KWin bridge and nothing else flips the a11y flag.
- **Accepted limit:** apps with no a11y bridge (bare terminals, some Electron)
  won't resolve. Those windows degrade to empty.

### References

- [compatibility.md](compatibility.md) — AT-SPI backend coverage.

---

## D-005 — Per-compositor active-app providers

- **Status:** Accepted
- **Decided:** 2026-06-04
- **Owner:** @aaddrick

### Context

Wayland exposes no portable "which app is focused" API. Each desktop has its own
mechanism, and none of them generalizes to the others.

### Decision

I ship **three active-app/focus providers**, selected by environment:

- **KDE** — a KWin script pushes `windowActivated` / window-list over D-Bus to a
  helper-hosted zbus service.
- **GNOME** — a GNOME Shell extension bridging `org.gnome.Shell.Introspect`.
- **wlroots / other** — AT-SPI (see [D-004](#d-004--at-spi-as-the-universal-active-app--selection-fallback)).
- **X11** — `_NET_*` window properties + XTEST.

Injection, clipboard, and selection are shared across all of them. Only
active-app/focus is per-compositor.

### Rationale

- **There is no single answer.** KWin scripting, GNOME Introspect, and AT-SPI are
  the only reliable per-desktop sources. Force one onto all compositors and it
  fails.
- **GNOME Introspect over AT-SPI on GNOME** because mutter exposes a richer, more
  reliable focus signal there.

### Consequences

- Three bridges to maintain, each with its own install/permission story. The
  GNOME extension needs a relogin, and KDE's KWin `callDBus` can be
  intermittently delayed.
- `detect()` routing has to be careful. For example, treat an empty
  `WAYLAND_DISPLAY` as unset, and route Ubuntu's `ubuntu:GNOME` to the GNOME
  path.

### References

- [learnings/kwin-zbus-tokio.md](learnings/kwin-zbus-tokio.md);
  [learnings/gnome-shell-extension.md](learnings/gnome-shell-extension.md).

---

## D-006 — Rename the Electron launcher to `wispr-flow`

- **Status:** Accepted
- **Decided:** 2026-06-04
- **Owner:** @aaddrick

### Context

I staged a Linux Electron whose launcher was named `electron`, and every DB
query failed with "no such table". The log read "Executed 0 migrations". That
took me a while to track down.

### Decision

I **rename the Electron binary off `electron`** (to `wispr-flow`) in every
packaging path, and I export `ELECTRON_FORCE_IS_PACKAGED=true` from the launcher
on top of that.

### Rationale

- Electron sets `app.isPackaged=false` when the launcher is literally named
  `electron`. The app then resolves the *dev* migrations path (which is absent),
  runs 0 migrations, and every table is missing. Rename the binary and
  `isPackaged` flips to `true`. That gets you the packaged migrations path, and
  all 92 migrations run.
- `ELECTRON_FORCE_IS_PACKAGED=true` is belt-and-braces in case a layout slips the
  rename.

### Consequences

- The makers have to preserve the rename and the exec bit. The helper-path patch
  uses `process.resourcesPath` directly, so the helper works either way. Only
  migrations depend on `isPackaged`.

### References

- [learnings/ispackaged-rename.md](learnings/ispackaged-rename.md).

---

## D-007 — Clean-room V8 14.8 patch for `better-sqlite3-multiple-ciphers`

- **Status:** Accepted
- **Decided:** 2026-06-04
- **Owner:** @aaddrick

### Context

Electron 42 ships V8 14.8 / Node 24.15. `better-sqlite3-multiple-ciphers@12.5.0`
won't compile against V8 14.8 unpatched. Upstream Wispr Flow fixes this with a
pinned yarn patch.

### Decision

I ship a **clean-room equivalent** patch
(`scripts/patches/v8-14.8-better-sqlite3-multiple-ciphers.patch`), applied to a
pristine 12.5.0 before `@electron/rebuild`.

### Rationale

- Three version-guarded V8-API fixes restore compilation:
  `External::New()/Value()` external-pointer tag, `PropertyCallbackInfo::This()`
  → `HolderV2()`, and the `SetNativeDataProperty` `0`→`nullptr` ambiguity.
- I wrote it independently, not copied from upstream's yarn patch, so the
  clean-room provenance holds.

### Consequences

- It's runtime-validated under Electron 42. It opens an encrypted SQLCipher DB,
  all three patched getters come back correct, and a wrong key gets rejected. The
  patch is version-guarded, so it's a no-op on V8 versions that don't need it.

### References

- [learnings/electron42-v8-sqlite.md](learnings/electron42-v8-sqlite.md).

---

## D-008 — Async zbus on tokio, never `zbus::blocking` for services

- **Status:** Accepted
- **Decided:** 2026-06-04
- **Owner:** @aaddrick

### Context

The KDE bridge first hosted a zbus **blocking** service. KWin's `Report` /
`ReportList` callbacks queued up and only flushed at shutdown. So KDE active-app
and running-apps came back empty. That one cost me a real debugging session.

### Decision

I host every zbus **service** on the **async** zbus API inside a dedicated tokio
runtime. **Never** use `zbus::blocking` for a service in this codebase.

### Rationale

- `atspi` enables zbus's `tokio` feature tree-wide, and that disables zbus's
  internal async-io executor thread. A blocking service connection then never
  dispatches *incoming* method calls, except while we make an outgoing blocking
  call. So KWin's callbacks never ran.
- Run on the async API on a live tokio runtime and incoming calls dispatch
  promptly.

### Consequences

- It's a codebase rule now: zbus services run async-on-tokio (mirrors
  `atspi_app.rs`).
- This is the single most load-bearing concurrency invariant in the helper.

### References

- [learnings/kwin-zbus-tokio.md](learnings/kwin-zbus-tokio.md).

---

## D-009 — Native sqlite addons as pinned prebuilt assets, not a build-time rebuild

- **Status:** Accepted
- **Decided:** 2026-06-06
- **Owner:** @aaddrick

### Context

The app ships Windows `.node` for `better-sqlite3-multiple-ciphers` + `sqlite3`;
Linux needs them rebuilt for the Electron 42 ABI (the V8 14.8 patch from
[D-007](#d-007--clean-room-v8-148-patch-for-better-sqlite3-multiple-ciphers)).
The first cut only *documented* the rebuild and swapped in `.node` from a
gitignored dir — empty in CI, so the build shipped Windows `.node` and crashed
at startup. The obvious fix (rebuild inside each package job) is non-reproducible
(no lockfile), a per-build supply-chain + network surface, and — decisively —
bakes the **build runner's glibc** into the binary, so a `.node` built on a new
CI image fails to load on older-but-supported distros.

### Decision

Treat the addons like the clean-room helper: build them **once**, per arch, on an
old-glibc base, and consume them as pinned, checksummed, provenance-stamped
release assets.

- Producer: `.github/workflows/build-native-modules.yml` builds on
  `manylinux_2_28` (glibc 2.28 floor) via `scripts/rebuild-native-modules.sh`
  (lockfile-pinned `npm ci`, the V8 patch on a pristine checkout, isolated
  electron-gyp headers), validates under real Electron 42 (ABI 146 + encrypted-DB
  round-trip), and publishes to the tag in `native-modules-version.txt`.
- Consumer: `scripts/setup/fetch-native-bin.sh` verifies SHA-256 + the
  `native-modules.lock` provenance (asset `patch_sha256` == this checkout's
  patch; ABI 146) before staging. CI hard-fails on fetch failure.

### Rationale

- Reproducible (committed `package-lock.json`, `npm ci`), and the glibc floor is
  a deliberate choice (the build image) instead of an accident (the CI runner).
- The provenance stamp — not ELF magic — is the trust anchor: a stale or
  wrong-ABI `.node` is ELF-valid but provenance-mismatched, and is rejected.
- Mirrors the established `HELPER_BIN` / `helper-version.txt` pattern.

### Consequences

- A new Electron/package bump means re-running the producer workflow and bumping
  `native-modules-version.txt` — a deliberate, reviewable step.
- `build-linux.sh` keeps a local from-source rebuild fallback (host glibc) for
  dev convenience only; it is never used in CI.

### References

- [learnings/electron42-v8-sqlite.md](learnings/electron42-v8-sqlite.md),
  [building.md](building.md#native-sqlite-modules-prebuilt-with-a-local-rebuild-fallback).
