[< Back to learnings](index.md)

# Electron 42 / V8 14.8 — the better-sqlite3 ABI patch

Hey! Here's a wall I ran into: Wispr Flow pins Electron 42, which ships **V8
14.8 / Node 24.15**. `better-sqlite3-multiple-ciphers@12.5.0` (the encrypted-DB
engine the app uses) **does not compile against V8 14.8 unpatched**. Upstream
fixes this with a pinned yarn patch. So the port ships a clean-room equivalent
written independently from the documented V8 API changes.

**Source files:**

- [`scripts/patches/v8-14.8-better-sqlite3-multiple-ciphers.patch`](../../scripts/patches/v8-14.8-better-sqlite3-multiple-ciphers.patch)
- [`scripts/build-linux.sh`](../../scripts/build-linux.sh) — Step 4 (native rebuild)

## Overview

The Electron 42 ABI is 146. `sqlite3@5.1.7` rebuilds clean against it with no
patch. `better-sqlite3-multiple-ciphers@12.5.0` doesn't, and the reason is its
native C++ uses three V8 APIs that changed shape in V8 13/14. I apply the patch
to a pristine 12.5.0 checkout (`patch -p1`) **before** `@electron/rebuild` runs.

## The three V8-API changes

All three are version-guarded, so the patch is a no-op on V8 versions that don't
need it:

1. **`External::New()` / `External::Value()`** now take a mandatory
   `ExternalPointerTypeTag`. The patch passes a default tag, which is
   behaviour-identical to the old untagged form.
2. **`PropertyCallbackInfo::This()`** was removed on V8 13+ → replaced with
   `HolderV2()`.
3. **`SetNativeDataProperty`** — the new overload set makes a literal `0`
   ambiguous. So the patch passes `nullptr` instead.

## Rebuild recipe

This is now automated — `scripts/rebuild-native-modules.sh` does exactly the
steps below (lockfile-pinned `npm ci`, the patch on a pristine checkout,
isolated electron-gyp headers so node-gyp can't grab system Node headers, then
verifies the output). The manual equivalent:

```bash
npm i better-sqlite3-multiple-ciphers@12.5.0 sqlite3@5.1.7 @electron/rebuild@4.0.4
( cd node_modules/better-sqlite3-multiple-ciphers \
    && patch -p1 < scripts/patches/v8-14.8-better-sqlite3-multiple-ciphers.patch )
npx @electron/rebuild -v 42.3.0 -f \
    -w better-sqlite3-multiple-ciphers -w sqlite3 --arch=x64
```

The rebuilt `.node` files are staged into `app.asar.unpacked`. The patched
12.5.0 native pairs ABI-correctly with the 12.5.0 JS wrapper that's webpacked
into the main bundle, so the versions line up on both sides.

## How it's shipped (the artifact model)

Don't rebuild these in the packaging pipeline — a `.node`'s glibc floor is set
by where it's built, so a CI-runner rebuild fails to load on older distros.
Instead they're built **once** per arch on an old-glibc base
(`manylinux_2_28`, glibc 2.28) by the Build Native Modules workflow in the
dedicated `wispr-flow-linux/native-modules` repo (split out, like the helper, so
these CI-consumed assets don't inflate the main project's Release download
counts), validated under real Electron 42 (ABI 146 + an encrypted-DB round-trip
via `scripts/native-modules/smoke-test.sh`), and published there as pinned,
checksummed release assets. The build consumes them through
`scripts/setup/fetch-native-bin.sh`, which checks SHA-256 **and** a provenance
stamp (`native-modules.lock`: the asset's `patch_sha256` must equal this
checkout's patch, ABI must be 146) before staging — ELF magic alone can't tell a
stale wrong-ABI binary from a correct one. Pinned tag:
`native-modules-version.txt`. See
[decisions.md D-009](../decisions.md#d-009--native-sqlite-addons-as-pinned-prebuilt-assets-not-a-build-time-rebuild).

## Validation

I runtime-validated this under Electron 42. It opens an encrypted SQLCipher DB,
runs queries, all three patched getters return correct values, and a wrong key
is rejected. Skip the rebuild and the app still launches, but every DB-backed
feature breaks.

> [!NOTE]
> This is **independent** of the "no such table" failure, which is a *migrations*
> problem caused by the launcher name, not the native module. See
> [ispackaged-rename.md](ispackaged-rename.md).

## References

- [decisions.md D-007](../decisions.md#d-007--clean-room-v8-148-patch-for-better-sqlite3-multiple-ciphers),
  [building.md](../building.md#native-sqlite-rebuild-against-the-v8-148-patch).
