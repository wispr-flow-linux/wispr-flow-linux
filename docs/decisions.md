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
| [D-009](#d-009--native-sqlite-addons-as-pinned-prebuilt-assets-not-a-build-time-rebuild) | 2026-06-06 | Accepted | Native sqlite addons as pinned prebuilt assets, not a build-time rebuild |
| [D-010](#d-010--the-installer-is-pinned-in-tree-not-resolved-at-build-time) | 2026-09-21 | Accepted | The installer is pinned in-tree, not resolved at build time |
| [D-011](#d-011--the-publish-chain-is-ungated-and-fails-closed) | 2026-09-22 | Accepted | The publish chain is ungated and fails closed |
| [D-012](#d-012--pull-requests-duplicates-close-with-credit-silence-yields-to-a-cherry-pick) | 2026-09-22 | Accepted | Pull requests: duplicates close with credit, silence yields to a cherry-pick |

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

- Producer: the **Build Native Modules** workflow in the dedicated
  `wispr-flow-linux/native-modules` repo builds on `manylinux_2_28` (glibc 2.28
  floor) via `scripts/rebuild-native-modules.sh` (lockfile-pinned `npm ci`, the
  V8 patch on a pristine checkout, isolated electron-gyp headers), validates
  under real Electron 42 (ABI 146 + encrypted-DB round-trip), and publishes to
  the tag pinned in `native-modules-version.txt`. The build lives in its own repo
  (like the helper) so these CI-consumed assets don't inflate the main project's
  Release download counts.
- Consumer: `scripts/setup/fetch-native-bin.sh` (`NATIVE_REPO` →
  `wispr-flow-linux/native-modules`) verifies SHA-256 + the
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
- `build-linux.sh` keeps an **opt-in** local from-source rebuild (host glibc,
  `WISPR_NATIVE_REBUILD=1`) for dev convenience only; the default never rebuilds
  and CI never does. `rebuild-native-modules.sh` + `scripts/native-modules/` +
  the V8 patch stay vendored here (the patch is also the consumer's provenance
  anchor) and are kept in sync with the `native-modules` repo's canonical copy.

### References

- [learnings/electron42-v8-sqlite.md](learnings/electron42-v8-sqlite.md),
  [building.md](building.md#native-sqlite-modules-prebuilt-with-an-opt-in-local-rebuild).

---

## D-010 — The installer is pinned in-tree, not resolved at build time

- **Status:** Accepted
- **Decided:** 2026-09-21
- **Owner:** @aaddrick

### Context

Until this decision every build, local or CI, asked upstream what "latest" was
(`scripts/setup/resolve-installer-url.sh` followed Wispr's stable redirect) and
downloaded whatever came back. A version constant in `build.sh` was the only
guard: the build aborted when the resolved version differed from it. Two things
broke that model at once in August 2026. Wispr repointed the redirect at a
versionless web-bootstrap stub with no payload, so the resolver died and every
`./build.sh` without `--exe` failed ([#83](https://github.com/wispr-flow-linux/wispr-flow-linux/issues/83)).
And [#55](https://github.com/wispr-flow-linux/wispr-flow-linux/pull/55) showed
that `helper-env.sh` had been a silent no-op on 1.6.7xx+ bundles, which is the
class of drift a live resolve exists to ship. The nightly bump workflow pushes
a `v*` tag with no human gate, so a working resolver alone would have re-armed
the publish chain against a bundle nobody had re-audited.

The sibling project (claude-desktop-debian) had already moved to a pinned
artifact: `official-deb.sh` holds version, pool path and SHA-256 per arch, the
build downloads exactly that, and only its bump workflow queries the index.

### Decision

The upstream installer is **pinned in-tree** in
[`scripts/setup/installer-pin.sh`](../scripts/setup/installer-pin.sh): version,
download URL and SHA-256, one assignment per line. `build.sh` sources it for
`APP_VERSION`; `download.sh` downloads exactly the pinned URL and refuses the
file unless its digest matches; CI does the same. `--exe` remains the local
override and is never rejected, only warned about when its digest is not the
pin's. Nothing in the build path resolves "latest".

Only `check-wispr-version.yml` looks upstream, via the JSON manifest the
bootstrapper itself reads (`latest.json`: versioned full-installer URL plus a
published SHA-256). It rewrites the pin through
`scripts/setup/write-installer-pin.sh`, which validates every field and refuses
a partial write, then bumps the Nix version, commits, and tags. A manifest that
publishes no digest never bumps.

### Rationale

- **A build is reproducible from the tree alone.** The version, URL and digest
  are in git, so a checkout builds the same bytes next month, and a bump is a
  commit someone can read, revert, or bisect to.
- **Fail closed on tampering and re-publishes.** The redirect never published a
  hash; the manifest does. A corrupted or replaced download stops the build
  instead of shipping.
- **The audit gate is structural, not procedural.** A new upstream version
  cannot reach a package without first moving the pin, and moving the pin is
  the moment the patch suite gets re-audited (the marker gate in
  `verify-patches.sh` and the fixtures in `tests/linux-patches.bats` fail on
  drift; the stub-backend assert in the artifact smoke test catches the silent
  kind).
- **One writer.** Version, URL and digest move together through one validated
  script, so the pin can never be internally inconsistent.

### Alternatives considered

- **Fix the resolver, keep resolving at build time** (#55's shape). Simplest
  diff, but leaves every build tracking upstream's publish cadence and keeps
  the version constant as the sole guard. Rejected.
- **Pin the version only, resolve the URL and digest live.** Still trusts
  whatever the manifest says that day for the bytes; a re-published same-version
  installer would slip through. Rejected.
- **Squirrel `RELEASES` + nupkg as the primary source.** Works today and is the
  natural fallback if `latest.json` disappears
  ([#70](https://github.com/wispr-flow-linux/wispr-flow-linux/pull/70)); the
  manifest is preferred because it is what upstream's own installer reads and it
  publishes a SHA-256 rather than a SHA-1.

### Consequences

- `./build.sh` without `--exe` works again and builds the audited version.
- Merging a working pin to `main` re-arms the nightly bump workflow; whether
  the publish chain gets a human gate (a GitHub environment with a required
  reviewer, or a bot-opened PR instead of a tag) is a separate decision.
- A stale `extract/` tree from another version is refused rather than reused
  under the pinned label.
- `docs/building.md` and `RELEASING.md` describe the pin and the manual bump
  (`resolve-installer-url.sh | write-installer-pin.sh`).

### References

- [#83](https://github.com/wispr-flow-linux/wispr-flow-linux/issues/83),
  [#55](https://github.com/wispr-flow-linux/wispr-flow-linux/pull/55) (the
  manifest resolver, by @khamsakamal48),
  [learnings/patching-minified-js.md](learnings/patching-minified-js.md#end-to-end-verification-post-build),
  [learnings/test-methodology.md](learnings/test-methodology.md).

---

## D-011 — The publish chain is ungated and fails closed

- **Status:** Accepted
- **Decided:** 2026-09-22
- **Owner:** @aaddrick

### Context

[D-010](#d-010--the-installer-is-pinned-in-tree-not-resolved-at-build-time)
left one question open: once the pin is in and the nightly
`check-wispr-version` workflow is re-armed, it pushes a `v*` tag with no human
between it and the APT, DNF and AUR repos. The chain in
[`ci.yml`](../.github/workflows/ci.yml) builds both architectures, runs the
artifact tests, creates the Release and publishes, all from that one tag push.
The candidates for a gate were a GitHub environment with a required reviewer
on the publish jobs, a bot-opened pull request instead of a tag, or nothing.

The sibling project (claude-desktop-debian) runs the same shape with no gate
and has for months: its bump bot tags, the chain publishes, and a red job is
the only thing that stops a release.

### Decision

**No gate.** The chain stays automatic from the bump workflow's tag push to
the package repos, and it fails closed. What already makes it fail closed:

- `release` needs `build-amd64`, `build-arm64` and `test-artifacts`; the
  three publish jobs need `release`. A red job anywhere ships nothing.
- Each build downloads the pinned installer and refuses it on a SHA-256
  mismatch.
- Every bundle patch asserts its anchor count and aborts on drift.
- `verify-patches.sh` greps the shipped asar for every marker after repack.
- The launch smoke test fails when the helper reports the `stub` injection
  backend.

The manual look-first path is a **release-candidate tag**: an `-rc` suffix on
the wrapper version (`v1.0.4-rc.1+wispr1.6.897`) builds, tests and creates a
GitHub pre-release with the assets the final tag would ship, and the APT, DNF
and AUR jobs skip it. The bump workflow never produces rc tags. A bad release
that shipped is marked pre-release and followed by a new tag, never deleted
([`RELEASING.md`](../RELEASING.md)).

**Amended 2026-09-24 (issue #103).** The bump workflow runs the bats suite
and `tests/test-patch-stage.sh` over the newly pinned installer before it
commits, and pushes the commit and the tag only on green. A red pre-check
leaves `main` and the tags untouched and opens or bumps a `bump-failure`
issue that the next green run closes. This is the same machine check the
tag build would run, moved ahead of the push; it is not a human gate. The
1.6.937 bump had landed red on `main` with no issue filed, and the workflow
had failed nightly for a week before that without a signal.

### Rationale

- **One maintainer.** A gate that waits on a person is a daily click with
  nothing new to look at, and the click stops happening. Bumps then pile up
  and the port drifts from upstream, which is the failure the bot exists to
  prevent.
- **Every failure that matters is already a red job.** Wrong bytes, a moved
  anchor, a missing marker and the silent stub backend are all machine checks.
  The one class a human gate would have caught, semantic drift behind a
  matching anchor, is caught by the fixture tests and the smoke test, not by
  someone eyeballing a diff of minified JS.
- **The rc path keeps the option.** When a bump does deserve a look (a new
  Electron major, a patch cluster landing), a hand-pushed rc tag gives the
  full build and a pre-release to inspect without touching the repos.
- **Proven shape.** The sibling has run it without incident.

### Alternatives considered

- **GitHub environment with a required reviewer on the publish jobs.**
  Blocks the three repo jobs until approved. Rejected: the approval has no
  evidence to weigh beyond the green run that already exists, and an
  unapproved run leaves a Release with assets that no repo serves.
- **Bot-opened pull request instead of a tag.** Turns the bump into a
  reviewable diff. Rejected: the diff is three lines of pin plus a Nix
  version, the review would still rest on the same CI checks, and the merge
  would then need its own path to a tag.
- **Hold the bump until a manual audit.** This is what the rc tag is for on
  the occasions it is wanted; as the default it is the gate above with worse
  ergonomics.

### Consequences

- Merging a working pin to `main` re-arms the bot, and the first tag it
  pushes ships if it is green. That is the intended outcome.
- Every new bundle patch must carry its `MARKERS` entry in
  `verify-patches.sh`, its `MARKER_SAMPLES` twin in
  `tests/verify-patches.bats` and its apply / idempotent / bail fixtures in
  `tests/linux-patches.bats`. With no human gate, those tests are the audit.
- `ci.yml` gates the three publish jobs on `!contains(github.ref_name,
  '-rc')`, marks rc Releases `prerelease`, and skips pre-releases when
  choosing the previous tag for release notes. `build.sh` drops the `-rc.N`
  from the package version.
- A red run leaves no partial publish; the fix goes to `main` and a new tag
  (`+rebuild.N` if upstream has not moved) re-runs the chain.

### References

- [D-010](#d-010--the-installer-is-pinned-in-tree-not-resolved-at-build-time),
  [`RELEASING.md`](../RELEASING.md),
  [`.github/workflows/ci.yml`](../.github/workflows/ci.yml),
  [#84](https://github.com/wispr-flow-linux/wispr-flow-linux/pull/84).

## D-012 — Pull requests: duplicates close with credit, silence yields to a cherry-pick

- **Status:** Accepted
- **Decided:** 2026-09-22
- **Owner:** @aaddrick

### Context

The September 2026 triage found 17 open pull requests, several of them
fixing the same bug from different forks (three for the Hub focusable gate
alone), a stack of four that depended on an unmerged helper release, and
authors who had gone quiet after a review. Every one was a first-time
contributor whose CI runs sat unapproved. There was no written rule for
which duplicate lands, what happens to a PR nobody answers for, or how a
stacked PR announces itself, so each close had to argue its own case.

### Decision

The policy is written into [`CONTRIBUTING.md`](../CONTRIBUTING.md) under
"Pull request policy":

- Duplicates close with credit to the earliest mergeable PR; a used diagnosis
  or diff is credited by handle in the commit body.
- A PR with no author response for 30 days may be finished under the
  maintainer-edits policy (the author's commit kept, the maintainer's
  changes in a second commit) or closed, and can be reopened.
- First-time contributors get CI approved on request, every push.
- A stacked PR says so in its first line and names its base.
- A PR names the Wispr bundle its patch was verified against; the pin is
  what ships.

### Rationale

- **One maintainer, many forks.** The rules turn each close into a link to
  the policy instead of a paragraph of justification, and they make the
  cherry-pick path legitimate rather than something done quietly.
- **Credit is the cost of closing.** A closed duplicate still cost its author
  the work; the commit body credit is what makes the close fair.
- **Thirty days is long enough to be silence.** Shorter and a busy
  contributor is cut off; longer and the fix drifts past the next upstream
  bump and has to be redone anyway.

### Alternatives considered

- **First PR opened wins.** Rejected: the earliest PR is often the one with
  the wrong anchor or no test, and landing it would mean rewriting it.
- **Never cherry-pick, only close.** Rejected: it throws away working fixes
  over a missing reply, and the maintainer-edits checkbox already grants the
  permission.
- **No time limit.** Rejected: open PRs against a re-minified bundle rot;
  a stale one is more work to review than to redo.

### Consequences

- Close comments cite the policy and name the surviving PR.
- Credit lives in commit bodies. An `ACKNOWLEDGMENTS.md` file kept
  alongside it was dropped on 2026-09-24: it needed a follow-up on every
  merge and duplicated the commit credit.
- The 30-day clock is measured from the maintainer's last review comment;
  the cherry-pick keeps the author's commit and adds a second one.

### References

- [`CONTRIBUTING.md`](../CONTRIBUTING.md),
  [D-011](#d-011--the-publish-chain-is-ungated-and-fails-closed).
