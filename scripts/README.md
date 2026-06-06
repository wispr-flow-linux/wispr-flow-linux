# Wispr Flow — Linux Phase-0 packaging

A local build pipeline that repackages the proprietary Wispr Flow Windows app
(Electron 42 / electron-forge, Squirrel-packaged) so it launches on Linux with
our clean-room Rust helper attached. I built it the same way I build
[`claude-desktop-debian`](https://github.com/aaddrick/claude-desktop-debian)
(7z extract → patch → swap Electron runtime → rebuild natives → repackage).

## Files in this directory

| File | Purpose |
|---|---|
| `patches/helper-resolver.sh` | The one mandatory app patch: adds a `'linux'` branch to the helper-path resolver in `.webpack/main/index.js`. Surgical, idempotent, keeps a `.orig` backup, verifies with a unique anchor. |
| `patches/mac-gates.sh` | Gates the macOS "/Applications" startup guard to `darwin` so it no-ops on Linux (otherwise a blocking dialog + `app.quit()` kills launch). |
| `build-linux.sh` | The full Phase-0 pipeline. Each step prints `[AUTO]` (runs here) or `[MANUAL]` (network/toolchain needed, documented + stubbed). |
| `verify-patches.sh` | Post-repack safety net: static-greps the shipped `app.asar` for the Linux patch markers and fails the build if any are missing. |
| `packaging/rpm.sh` | Packages the validated Linux tree as an installable `.rpm` (Fedora/RHEL). |
| `patches/v8-14.8-better-sqlite3-multiple-ciphers.patch` | Clean-room V8 14.8 source-compat patch for `better-sqlite3-multiple-ciphers` (applied before `@electron/rebuild`). |
| `README.md` | This file. |

These scripts only **read** `extract/`, the prebuilt helper binary (resolved
via `HELPER_BIN`; the helper lives in its own repo,
`github.com/wispr-flow-linux/helper`, pinned in `helper-version.txt`), and
`docs/reference/`. They write only under `scripts/` outputs and the build work
dir `build-linux/`. I keep the helper binary and `docs/reference/` read-only on
purpose. Nothing here touches them.

## The flow

```
Wispr Flow Setup.exe ──7z──▶ *.nupkg ──7z──▶ lib/net45/{resources/app.asar, Release/, *.pak, Wispr Flow.exe}
   (Step 1, done by Track 1; result in extract/)
                                   │
                                   ▼
   Step 2  unpack app.asar  ──────────────────────────────┐
   Step 3  PATCH main bundle: add 'linux' helper branch    │  ← patches/helper-resolver.sh
   Step 4  REBUILD better-sqlite3-multiple-ciphers+sqlite3 │     for Linux Electron 42 ABI  [MANUAL]
   Step 5  DROP win-ca / crypt32 (Windows-only)            │
   Step 6  STAGE Linux Electron 42 runtime  [MANUAL]       │
   Step 7  COPY in wispr-flow-linux-helper, repack asar    │
   Step 8  PACKAGE .deb/.rpm/.AppImage (or run-in-place)   │  [MANUAL]
                                                           ▼
                                          build-linux/stage/  (resources tree)
```

## The one mandatory app change — the helper-path resolver

Here's the thing I had to fix. The shipped main bundle resolves the native
helper with a **two-way switch and no Linux case**
(`extract/app/.webpack/main/index.js`, ~byte 3663489; `f.tD` = `isMac`,
`_.ZI` = resources root):

```js
const s = isMac
  ? (dev ? "…/swift-helper-app/…/Wispr Flow"        // mac dev
         : "…/swift-helper-app-dist/…/Wispr Flow")  // mac packaged
  : (dev ? "…\\windows-helper-app\\…\\Wispr Flow Helper.exe"   // win dev
         : "${_.ZI}\\Release\\Wispr Flow Helper.exe");          // win packaged
if (!fs.existsSync(s)) { /* "Helper service script path not found" → feature dead */ }
```

On Linux, `process.platform` is neither mac nor win. So it falls into the
Windows branch, builds a `.exe` path with backslashes, `existsSync` fails, and
the whole text-injection feature dies on you.

`patches/helper-resolver.sh` makes **two surgical edits**:
1. `const s` → `let s` (so the override can reassign — `s` is `const` in the
   shipped code; reassigning would otherwise throw *Assignment to constant
   variable*).
2. Inserts a Linux override right before the `existsSync` guard:

```js
if ("linux" === process.platform) { /*WISPR_LINUX_HELPER_BRANCH*/
  const _wlp = require("path").join(process.resourcesPath, "Release", "wispr-flow-linux-helper");
  log.info("Running packaged Linux Helper service", { ... });
  s = _wlp;
}
```

It uses `process.resourcesPath` (which holds up across forge layouts) rather
than the minified `_.ZI` symbol. The patched bundle passes `node --check`. I
leave the mac/win paths untouched, so the patch can't regress those platforms.

### stdio / fd-3 and the exec bit (verified)

- **fd-3 stdio is already correct, no patch needed.** The helper spawn site
  (`spawn(s, { stdio:["pipe","pipe","pipe","pipe"], env:{…} })`, ~byte 3666403)
  is platform-agnostic. The 4-pipe topology (fd 3 = IPC return channel, per
  `docs/reference/ipc-contract.md §1`) applies on Linux for free.
- **The exec bit is NOT set by the app.** The spawn site only checks `X_OK` in
  its `catch` block (post-failure diagnostics). So the staged Linux helper has
  to be executable already. `build-linux.sh` Step 7 stages it `chmod 0755`, and
  packaging has to preserve the mode.

## What works vs. what's blocked

| Step | Status | Notes |
|---|---|---|
| 1. Extract | ✅ done | Result in `extract/` (Track 1). |
| 2. Unpack app.asar | ✅ auto* | *needs `@electron/asar` (npx fetch). The already-unpacked `extract/app/` tree lets you skip the round-trip for a smoke test. |
| 3. Patch resolver | ✅ auto | Verified: passes `node --check`, idempotent, `.orig` backup. |
| 4. Rebuild sqlite natives | ⚠️ MANUAL | `better-sqlite3-multiple-ciphers` + `sqlite3` ship as Windows `.node`; must rebuild for linux-x64 Electron 42 ABI. Complication: bsqlite-mc is pinned to a **yarn patch** in `package.json` — the rebuild must apply it. Without this the app launches but DB-backed features fail. |
| 5. Drop win-ca/crypt32 | ✅ auto | Removes `crypt32-{ia32,x64}.node`; Linux uses the system CA bundle. Jabra Linux ELF is kept (already cross-platform). |
| 6. Stage Linux Electron 42 | ⚠️ MANUAL | One hard network dep. Electron 42 is a normal upstream release with linux-x64/arm64 artifacts, so availability is expected — **verify the exact patch version (42.3.0) is downloadable**. |
| 7. Copy helper + repack | ✅ auto | Helper staged at `Release/wispr-flow-linux-helper` (0755). Repack needs `@electron/asar`. |
| 8. Package .deb/.rpm/.AppImage | ⚠️ MANUAL | electron-forge already declares maker-deb/maker-rpm; or hand-roll like claude-desktop-debian's `scripts/packaging/*`. |

**Real blockers:** none of these are show-stoppers. Two need network or
toolchain though: (a) the Linux Electron 42.3.0 download, and (b) the native
sqlite rebuild (with the yarn patch applied). Everything else runs automated.

After Phase 0 the app launches, the UI renders, audio records, and
transcription likely works. With our Rust helper wired in through the resolver
patch, the core "type it into my focused app" path is live too. I validated
that part separately on KDE Wayland.

## Quick run-in-place smoke test (no packaging)

```bash
# 1. patch the unpacked bundle (keeps a .orig backup)
bash scripts/patches/helper-resolver.sh extract/app/.webpack/main/index.js

# 2. get the prebuilt helper and stage it next to the app's resources.
#    The helper lives in its own repo (github.com/wispr-flow-linux/helper);
#    download the release pinned in helper-version.txt (or build a local
#    checkout) and point HELPER_BIN at it:
export HELPER_BIN=/path/to/wispr-flow-linux-helper   # from the helper repo release
#    place HELPER_BIN where process.resourcesPath/Release resolves for your layout

# 3. launch with a Linux Electron 42 binary
electron extract/app   # add --no-sandbox if your environment needs it
```

One gotcha: `process.resourcesPath` differs between `electron <dir>` (dev) and a
packaged build. For a dev launch, put the helper under the dev
`resourcesPath`/`Release`, or just use a packaged layout instead.

## License

I've released these build scripts into the public domain (Unlicense). The Wispr
Flow application itself stays proprietary and under its own terms.

The clean-room helper (its own repo, `github.com/wispr-flow-linux/helper`,
consumed here as a prebuilt binary via `HELPER_BIN`) is an independent
reimplementation of the documented IPC contract (`docs/reference/`). It contains
no Wispr Flow code.
