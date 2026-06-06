# Contributing

Hey! Thanks for helping with the unofficial **Wispr Flow for Linux** port. A
couple minutes here saves a round-trip later. Match your task to the right
channel:

- **Found a bug?** File an
  [issue](https://github.com/wispr-flow-linux/wispr-flow-linux/issues/new/choose)
  with the bug template. Paste full `wispr-flow --doctor` output; include
  distro, desktop, and session type (Wayland/X11). See
  [Filing an issue](#filing-an-issue).
- **Have a fix in hand?** PRs that fix existing behaviour, restore parity with
  the macOS/Windows helper, or improve packaging are always welcome. Open the
  PR; an issue isn't strictly required if the fix is small.
- **Want a net-new feature?** Open an issue or discussion first. We're a
  repackager plus a clean-room helper — see [What we accept](#what-we-accept).
- **Security concern?** Don't file a public issue. Use [SECURITY.md](SECURITY.md)
  — GitHub Security Advisories route to @aaddrick privately.

## Where to find what

I've scattered the docs across a few files. Here's the map:

- [CLAUDE.md](CLAUDE.md) / [AGENTS.md](AGENTS.md): development guide for AI
  agents and contributors (byte-identical below the H1; `CLAUDE.md` for Claude
  Code, `AGENTS.md` for other tools).
- [docs/index.md](docs/index.md): full docs entry point.
- [docs/building.md](docs/building.md): local build setup.
- [docs/styleguides/bash_styleguide.md](docs/styleguides/bash_styleguide.md):
  bash style ([style.ysap.sh](https://style.ysap.sh)). Tabs, 80 cols, `[[ ]]`,
  no `set -e`.
- [docs/styleguides/docs_styleguide.md](docs/styleguides/docs_styleguide.md):
  page anatomy and naming if you're adding a doc.
- [docs/learnings/index.md](docs/learnings/index.md): subsystem deep-dives. Read
  the relevant entry first.
- [docs/decisions.md](docs/decisions.md): architectural choices (ADR format).
- [docs/reference/ipc-contract.md](docs/reference/ipc-contract.md): the IPC contract the helper implements.
- [CHANGELOG.md](CHANGELOG.md): change history ([Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format).
- [SECURITY.md](SECURITY.md): private vulnerability reporting.
- [.github/CODEOWNERS](.github/CODEOWNERS): auto-review routing.

## What we accept

This repo is a **repackager** of the proprietary Wispr Flow Electron app. It
pairs with a **clean-room Rust helper** that reimplements the one native
capability Wispr Flow ships only for macOS/Windows — text injection into the
focused app. The helper now lives in its own repo
([github.com/wispr-flow-linux/helper](https://github.com/wispr-flow-linux/helper));
this repo consumes it as a prebuilt binary pinned in `helper-version.txt` and
staged via the `HELPER_BIN` env var. Both sides welcome:

- Bug fixes against existing behaviour (packaging, launcher, helper, patches).
- **Parity** with the macOS/Windows helper behaviour — closing gaps where the
  Linux helper diverges from the documented IPC contract (`docs/reference/`).
- Packaging, launcher, and `--doctor` fixes (new distro/compositor support,
  better diagnostics).
- Docs, tests, CI improvements.

Net-new application *features* default to no. We don't own Wispr Flow's product
direction, and anything we add we'd have to carry across every re-minified
upstream release. That's a real maintenance cost, so open an issue before you
invest in one.

**Not accepted: package-hosting, release, or publishing infrastructure.** This
repo is local-build-only by design — it ships no built packages, no APT/DNF
repo, no GitHub Releases, and no publish workflows. Don't open PRs that
reintroduce any of that.

## What goes upstream, not here

We patch the app's minified bundle and supply a Linux helper. We don't fix logic
inside the proprietary app itself. So if a bug reproduces in Wispr Flow on
macOS/Windows, it's an upstream bug — report it to
[Wispr Flow](https://wisprflow.ai), not here.

| File here                                   | File upstream (Wispr)              |
|---------------------------------------------|------------------------------------|
| `.deb`/`.rpm`/AppImage won't install        | Transcription accuracy / model     |
| Text injection broken on Wayland/X11        | Account, login, or billing flow    |
| `wispr-flow --doctor` reports wrong state   | Dictation hotkey logic in the app  |
| Native sqlite rebuild / launcher rename      | Audio capture / mic selection      |

## Filing an issue

1. Use the issue template, not freeform.
2. Paste full `wispr-flow --doctor` output. This is the most-skipped step, and
   it's the one I lean on most — it captures session type, `/dev/uinput` access,
   clipboard tooling, the GNOME extension, and AT-SPI in one shot.
3. Include distro, desktop, and session type (Wayland/X11). In my experience
   most Linux-only bugs trace to one of these.
4. Text-injection bugs: note your compositor (KDE Plasma, GNOME, wlroots, X11).
   Each one uses a different helper backend.

## Patches against the app

App patches live in `scripts/patches/*.sh`, one per concern
(`helper-resolver.sh` adds the `'linux'` helper-path branch; `mac-gates.sh`
gates the macOS-only Applications-folder guard to darwin; the
`v8-14.8-*.patch` makes `better-sqlite3-multiple-ciphers` compile on Electron
42's V8). `scripts/verify-patches.sh` static-greps the repacked bundle for the
Linux markers, so a half-patched build fails loudly instead of shipping broken.
Before you edit a patch, read the relevant
[`docs/learnings/`](docs/learnings/index.md) entry. I learned most of these the
hard way.

One priority rule: a build broken by an upstream Wispr Flow release beats new
work. Always.

## Code style

### Bash

All shell scripts follow the
[Bash Style Guide](docs/styleguides/bash_styleguide.md): tabs for indentation,
lines under 80 chars (URLs/regex exempt), `[[ ]]` for conditionals, `$(...)` for
substitution, `local` in functions, **no `set -e`**, no `eval`. Run `shellcheck`
before you push, and fix the underlying issue rather than suppressing it. A
per-line `# shellcheck disable=SCXXXX` with a why-comment is the last resort.

### Rust (the helper)

The helper's code and its cargo gates (`cargo fmt`, `cargo clippy -D warnings`,
`cargo test`) live in
[github.com/wispr-flow-linux/helper](https://github.com/wispr-flow-linux/helper).
Helper changes — new injection backends, IPC-contract parity, bug fixes — go
there, and that repo's CI runs the Rust gates. In this repo the helper is
consumed as a prebuilt binary pinned in `helper-version.txt` and staged via the
`HELPER_BIN` env var. To bump it here, point `helper-version.txt` at a released
helper tag.

### Markdown

Wrap prose at ~80 chars, matching the bash column rule. Tables, code blocks,
URLs, and alt text can run over when breaking them hurts readability.

## Before submitting a PR

- Run `shellcheck` + `actionlint` on touched scripts/workflows. Helper changes
  (and their `cargo fmt` + `cargo clippy` + `cargo test` gates) go to the
  [helper repo](https://github.com/wispr-flow-linux/helper), not here.
- For packaging/launcher/patch changes, build locally and run the artifact's
  `wispr-flow --doctor`. See [docs/building.md](docs/building.md). **Do not run
  `scripts/build-linux.sh` blindly** — its step 2 does `rm -rf build-linux/`,
  which destroys the validated staged tree. I've nuked mine that way more than
  once.
- Branch: `fix/123-description` or `feature/123-description`.
- PR body links the issue: `Fixes #123` or `Refs #123`.
- AI-assisted? Add the attribution block below.

## Letting maintainers edit your PR

Leave **Allow edits by maintainers** checked when you open the PR — GitHub
ticks it by default on cross-fork PRs. Here's why I ask. Sometimes a patch is
95% there and the rest is a one-line tweak: a typo, a rebase, an 80-col wrap, a
nudge to match the style guide. With that box checked I can just push the fix to
your branch and merge it, instead of leaving a comment and waiting a day for the
round trip. It's quicker for both of us.

I won't rewrite your work behind your back. I'll keep it to small mechanical
edits, and anything bigger I'll raise in a comment first. The box does need to
stay on, though. If maintainer edits are off, the PR gets an automatic comment
and is closed — flip **Allow edits by maintainers** back on and reopen it, and
we pick right back up where we left off.

## AI-assisted contributions

I'm fine with AI-assisted PRs, as long as you disclose. PR descriptions:

```
---
Generated with [Claude Code](https://claude.ai/code)
Co-Authored-By: Claude <model-name> <noreply@anthropic.com>
XX% AI / YY% Human
Claude: <what AI did>
Human: <what human did>
```

Use the real model name (e.g., "Claude Opus 4.8"). Keep the split honest. Those
breakdown lines make the ratio auditable against the diff.

Commits: `Co-Authored-By: Claude <claude@anthropic.com>`.

Issues/comments:
`Written by Claude <model-name> via [Claude Code](https://claude.ai/code)`.
