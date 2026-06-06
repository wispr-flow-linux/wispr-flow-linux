[< Back to learnings](index.md)

# isPackaged / launcher rename — the "no such table" trap

Hey! I hit this one head-on. Staging a Linux Electron whose launcher is named
`electron` makes the app run **zero database migrations**, so every query fails
with **"no such table"**. The fix is one rename: the Electron binary must not be
named `electron`.

**Source files:**

- [`scripts/launcher-common.sh`](../../scripts/launcher-common.sh) — `setup_electron_env` (the `ELECTRON_FORCE_IS_PACKAGED` belt-and-braces)
- `scripts/packaging/{deb,rpm,appimage}.sh` — the makers that rename the binary

## Overview

Electron decides `app.isPackaged` partly from the launcher's basename. When the
launcher is literally named `electron`, Electron sets **`app.isPackaged=false`**.
It assumes you're running `electron <dir>` in development.

That one assumption is what broke me. Wispr Flow's main process resolves its
migrations directory off `isPackaged`:

| `app.isPackaged` | Migrations path resolved | Result |
|---|---|---|
| `false` (launcher named `electron`) | `resourcesPath/src/main/db/migrations` (**dev path, absent**) | "Executed 0 migrations" → "no such table" on every query |
| `true` (launcher renamed) | `resourcesPath/migrations` (the 92 staged files) | All 92 migrations run, 0 table errors |

## The fix

**Rename the Electron binary off `electron`** (the makers use `wispr-flow`).
That alone flips `isPackaged=true`. As belt-and-braces, the launcher also exports
`ELECTRON_FORCE_IS_PACKAGED=true` (`setup_electron_env` in
`launcher-common.sh`). So the packaged path still resolves even if a layout
change slips the rename.

```bash
# run-in-place / manual launch — both of these work:
mv electron wispr-flow && ./wispr-flow extract/app
# or:
ELECTRON_FORCE_IS_PACKAGED=true electron extract/app
```

## What does NOT depend on this

The **helper-path patch** uses `process.resourcesPath` directly, so the Rust
helper loads correctly regardless of `isPackaged`. **Only migrations** depend on
the rename. And don't confuse this migrations failure with the native-module
sqlite problem. That one's an Electron-42 ABI issue, covered in
[electron42-v8-sqlite.md](electron42-v8-sqlite.md).

## Live evidence

After the rename, I saw the launch log change to this:

```
Executed 92 migrations:   Pending 0 migrations:     (0 "no such table" errors)
```

> [!WARNING]
> Packaging must **preserve the rename and the exec bit** on the launcher (and
> on the helper at `Release/wispr-flow-linux-helper`). A maker that copies the
> binary back as `electron` silently reintroduces this bug.

## References

- [decisions.md D-006](../decisions.md#d-006--rename-the-electron-launcher-to-wispr-flow),
  [troubleshooting.md](../troubleshooting.md#no-such-table--database-errors).
