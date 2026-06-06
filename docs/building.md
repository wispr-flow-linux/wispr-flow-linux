[< Back to docs index](index.md)

# Building from Source

You build a local Wispr Flow for Linux package from a Wispr Flow Windows
installer you supply yourself.

```bash
# Build for your distro's native format (you supply the installer):
./build.sh --build rpm --exe "/path/to/Wispr Flow Setup-v1.5.619.exe"
```

## Prerequisites

Hey! Before you reach for a package manager, `./build.sh` already checks for
these. On Debian/Ubuntu (apt) and Fedora/RHEL (dnf) it offers to install them
for you via `scripts/setup/dependencies.sh`. Here are the logical deps:

| Command | Package (Debian / Fedora) | Used for |
|---|---|---|
| `7z` | `p7zip-full` / `p7zip p7zip-plugins` | extract the Squirrel `.exe` → `.nupkg` → app payload |
| `wrestool`, `icotool` | `icoutils` | pull icons out of the Windows resources |
| `convert` | `imagemagick` / `ImageMagick` | icon resize/convert to Linux sizes |
| `rsync` | `rsync` | stage the resources tree |
| `node`, `npx` | `nodejs`, `npm` | `@electron/asar` pack/unpack + `@electron/rebuild` |
| `cargo` *(optional)* | `cargo` | only to build the helper yourself from [its repo](https://github.com/wispr-flow-linux/helper); not needed for this repo's packages |
| `wget` **or** `curl` | `wget` / `curl` | download the Linux Electron runtime |

Format-specific (only the one you build):

| Command | Package | For |
|---|---|---|
| `dpkg-deb` | `dpkg-dev` / `dpkg` | `--build deb` |
| `rpmbuild` | `rpm` / `rpm-build` | `--build rpm` |

You also need a **Rust toolchain** (`rustc` + `cargo`) for the helper. The
native sqlite rebuild pulls `@electron/rebuild` via `npx` at build time, so
that one isn't a system package you install ahead of time.

## Obtaining the installer

This repo never downloads or commits the proprietary installer. You grab
`Wispr Flow Setup-v<version>.exe` from [wisprflow.ai](https://wisprflow.ai) and
pass it with `--exe`. The pinned version is **1.5.619** (set in `build.sh` as
`APP_VERSION`). I'd start there. A different installer version can drift the
patch anchors, so it may need updates before it builds clean.

## Building

`--exe` is required. The build never fetches the proprietary installer, so you
always point it at the one you supplied.

```bash
# Auto-detect format from your distro:
./build.sh --exe "/path/to/Wispr Flow Setup-v1.5.619.exe"

# Or specify the format explicitly (still pass --exe):
EXE="/path/to/Wispr Flow Setup-v1.5.619.exe"
./build.sh --build deb      --exe "$EXE"   # Debian/Ubuntu .deb
./build.sh --build rpm      --exe "$EXE"   # Fedora/RHEL .rpm
./build.sh --build appimage --exe "$EXE"   # distribution-agnostic AppImage
./build.sh --build nix                     # prints flake instructions (built via flake, not build.sh)
```

`build.sh` is a thin orchestrator over the validated staging engine
(`scripts/build-linux.sh`) and the per-format makers
(`scripts/packaging/<fmt>.sh`). It handles flag parsing, host detection,
dependency install, the installer resolve/extract dispatch, and packaging
dispatch. It doesn't reimplement staging itself. So if you're tracing a
problem, the real work lives in those two layers underneath.

### Flags

| Flag | Values | Meaning |
|---|---|---|
| `-b`, `--build` | `deb` `rpm` `appimage` `nix` | Output format. Defaults to your distro's native format. |
| `--arch` | `amd64` `arm64` | Target architecture (overrides host detection). |
| `-e`, `--exe` | path | Path to the Wispr Flow installer .exe you supply (**required**). |
| `-c`, `--clean` | `yes` `no` | Remove intermediate build files when done (default `no`). |
| `-r`, `--release-tag` | string | Optional tag embedded in the package version. |
| `--test-flags` | — | Parse + print the resolved flags, then exit **without** building. |

`--test-flags` is the safe way to confirm what a build *would* do. I reach for
it whenever I'm not sure a flag combo resolves the way I expect:

```bash
./build.sh --build appimage --arch arm64 --test-flags
```

### Architecture support

`x86_64`/`amd64` is the fully validated target. That's where the VM sweep ran,
so it's the one I'd trust first. `aarch64`/`arm64` is wired through every arch
global (`arch`, `arch_deb`, `arch_rpm`, `electron_arch`) and Electron ships
arm64 Linux artifacts, **but the arm64 build is not hardware-validated** — treat
it as best-effort. Validation ran on x86_64; see
[compatibility.md](compatibility.md).

## How it works

Wispr Flow is an Electron 42 / electron-forge app shipped as a Squirrel Windows
installer. That's the same packaging stack as Claude Desktop, which I maintain a
build script for, so the extract/repack half transfers cleanly. The hard part is
unique to Wispr Flow. Its text-injection "Helper" process exists only as macOS
(Swift) and Windows (C#) binaries, with no Linux variant and no source. A
clean-room Rust helper
([github.com/wispr-flow-linux/helper](https://github.com/wispr-flow-linux/helper))
reimplements it. This build no longer compiles the helper. It downloads the
prebuilt binary pinned in `helper-version.txt`, staged via the `HELPER_BIN` env
var, and patches the app to load it on Linux.

Here's what the staging pipeline (`scripts/build-linux.sh`) does:

1. **Extract** the Squirrel `.exe` with `7z` → `*-full.nupkg` → app payload under
   `lib/net45/` (`resources/app.asar`, native modules, `Release/`, `*.pak`).
2. **Unpack** `app.asar` with `@electron/asar`.
3. **Patch the main bundle** — `scripts/patches/helper-resolver.sh` adds a
   `'linux'` branch to the helper-path resolver so the app loads
   `<resourcesPath>/Release/wispr-flow-linux-helper`;
   `scripts/patches/mac-gates.sh` gates the macOS "move to Applications" guard to
   `darwin` so it no-ops on Linux. See
   [scripts/README.md](../scripts/README.md) for the exact edits.
4. **Rebuild native modules** for the Linux Electron 42 ABI (`sqlite3@5.1.7`
   builds clean; `better-sqlite3-multiple-ciphers@12.5.0` needs the V8 14.8
   patch — see below).
5. **Drop `win-ca`/`crypt32`** (Windows cert store; Linux uses the system CA
   bundle); keep the Jabra Linux ELF (already cross-platform).
6. **Stage Linux Electron 42**, repack `app.asar`, and stage the full resources
   tree (migrations, assets, the helper).
7. **Package** as `.deb`/`.rpm`/`.AppImage` via `scripts/packaging/<fmt>.sh`.

`scripts/verify-patches.sh` static-greps the repacked `app.asar` for the Linux
patch markers, so a half-patched bundle fails the build instead of shipping
broken. I added that gate after getting burned by a silently-incomplete patch.

## Manual / network-dependent steps

Two steps need network + toolchain, so they can't run fully offline:

### Linux Electron download

The build fetches **Electron 42.3.0** for `linux-x64` (or `linux-arm64`) from
the upstream releases. `scripts/setup/fetch-electron-binary.js` drives this, so
you don't pick the runtime by hand.

### Native sqlite rebuild against the V8 14.8 patch

Electron 42 ships **V8 14.8 / Node 24.15**, and that combo is where this gets
fiddly. `better-sqlite3-multiple-ciphers` **does not compile** against V8 14.8
unpatched. You apply the clean-room compat patch before rebuilding:

```bash
npm i better-sqlite3-multiple-ciphers@12.5.0 sqlite3@5.1.7 @electron/rebuild@4.0.4
( cd node_modules/better-sqlite3-multiple-ciphers \
    && patch -p1 < scripts/patches/v8-14.8-better-sqlite3-multiple-ciphers.patch )
npx @electron/rebuild -v 42.3.0 -f \
    -w better-sqlite3-multiple-ciphers -w sqlite3 --arch=x64
```

The patch makes three version-guarded V8-API fixes (External tag, `HolderV2()`,
`SetNativeDataProperty` ambiguity). I wrote up the why in
[learnings/electron42-v8-sqlite.md](learnings/electron42-v8-sqlite.md) if you
want the full story. And don't skip the rebuild to save time. The app still
launches, but every DB-backed feature breaks.

### The mandatory `electron` → `wispr-flow` rename

**The Electron binary MUST be renamed off `electron`** (to `wispr-flow`). This
one cost me real time, so I want it loud. Electron sets `app.isPackaged=false`
when the launcher is literally named `electron`, so the app resolves the *dev*
migrations path (which doesn't exist), runs 0 migrations, and every DB query
fails with **"no such table"**. Renaming flips `isPackaged=true`, all
92 migrations run, and the errors vanish. The packaging makers do this rename
automatically. The launcher also exports `ELECTRON_FORCE_IS_PACKAGED=true` as
belt-and-braces (see `scripts/launcher-common.sh`). I put the full write-up in
[learnings/ispackaged-rename.md](learnings/ispackaged-rename.md).

## Troubleshooting

Hit a build or runtime problem? Start with
[troubleshooting.md](troubleshooting.md), and run `wispr-flow --doctor` on the
installed package. The doctor surface usually points you at the cause faster
than reading logs by hand.
