[< Back to docs index](../index.md)

# Docs Style Guide

How docs are organized and written in the Wispr Flow for Linux repo. The patterns
here are adapted from the claude-desktop-debian docs conventions this project
mirrors. If you're adding a page, read **Page anatomy** before you start.

## Structure

- **Flat `docs/`**, **lowercase kebab-case** filenames (`troubleshooting.md`, not
  `TROUBLESHOOTING.md`; `building.md`, not `BUILDING.md`). Order belongs in the
  index, not filenames.
- One entry point: **[`docs/index.md`](../index.md)**. It's the GitHub-browsable
  landing page and the link target from every other doc.
- **Subdirectories only when a topic grows past ~5 pages.** Current subdirs:
  - [`docs/learnings/`](../learnings/) — subsystem deep-dives.
  - [`docs/reference/`](../reference/) — interface specs (the IPC contract +
    its JSON data tables).
  - `docs/styleguides/` — meta-docs about how to write docs and shell scripts.
- **Repo-root auxiliary files stay at the root** so GitHub auto-detects them:
  `README.md`, `UNLICENSE`. Don't move them under `docs/`.
- **The IPC contract is an interface spec, not an operator doc.** It lives in
  [`docs/reference/ipc-contract.md`](../reference/ipc-contract.md) alongside its
  machine-readable companions (`keycodes.json`, `commands.json`). Cross-link to
  it; don't copy its contents into how-to pages.

## Page anatomy

Three skeletons recur. Pick one before starting a page.

### Setup / how-to page

Used for `building.md`, `configuration.md`.

```
<one declarative sentence: what this page is for>
<one code block showing the minimum working command>
## Prerequisites          -> short list; assume Linux + git unless stated
## <Step 1>               -> one short paragraph + code block
## <Step 2>
## Common variations      -> distro / flag / compositor quirks
## Troubleshooting        -> link out to troubleshooting.md, don't duplicate
```

Open with the minimum command, not the prerequisites table. Readers skim to the
code block first.

### Troubleshooting / FAQ page

Used for `troubleshooting.md`.

```
<one declarative sentence: what kind of problem this page solves>
## <Symptom verbatim>     -> one ### Fix per symptom, with a code block
## <Next symptom>
```

The headings are **the symptom users type into search.** Don't editorialize
("Wayland troubles" is wrong — `## Paste does nothing` is right). If a symptom
needs explanation, prose goes under the fix, not in the heading.

### Subsystem deep-dive (a "learning")

Used for everything in `docs/learnings/`.

```
<one paragraph: what subsystem this covers, when it runs, why it's non-obvious>
**Source files:** bullet list of links to the relevant source files
## Overview                -> 2–3 paragraphs of context
## <Mechanic>              -> for each non-trivial mechanic, prose + a table when it has near-synonyms
## <Failure mode>          -> repro + diagnosis + fix path
## References              -> back to decisions.md, related learnings, issues
```

Deep-dives can be long. They serve repeat readers hunting for a specific fact,
not first-timers.

### Decision record (ADR)

Used for entries in `docs/decisions.md`.

```
## D-NNN — <short title>
- **Status:** Accepted / Superseded / Proposed
- **Decided:** YYYY-MM-DD
- **Owner:** @handle
### Context   ### Decision   ### Rationale   ### Consequences   ### References
```

Don't delete superseded decisions — mark them and link forward.

## Content rules

1. **Open every page with one declarative sentence, then a code block or list.**
   No "In this guide we will explore…" preamble.
2. **Imperative, second-person, present tense.** "Run the build." Not "users may
   wish to consider running the build."
3. **Domain nouns.** This is a packaging + helper project — use `the helper`,
   `the launcher`, `app.asar`, `the main bundle`, `uinput`, `the KWin bridge`,
   `the resolver patch`. Don't use `foo`/`bar` in end-to-end recipes.
4. **Defaults first, then the override.** "Electron auto-detects Wayland. To
   force it, set `WISPR_USE_WAYLAND=1`."
5. **Warnings in alert blocks**, not paragraphs: `> [!NOTE]`, `> [!WARNING]`,
   `> [!IMPORTANT]`. GitHub renders them.
6. **Source-file blocks on deep-dives.** Bulleted links to the actual source
   files. Don't bury source references in prose.
7. **Cross-link liberally.** Every page should link to 2–4 others, and
   [`docs/index.md`](../index.md) should link to every page in `docs/`.
8. **One file per topic.** Don't paste the same config block into three pages.
   Show it once (e.g. the uinput udev rule in `configuration.md`); excerpt
   subsections elsewhere with a link back.
9. **Rationale lives in `decisions.md` or a learning**, not in how-to pages. If
   you write "we did this because…" in a how-to page, it belongs in a learning or
   `decisions.md`.

## Honesty rules (specific to this port)

- **Don't claim hardware validation the project doesn't have.** The whole VM
  sweep ran on **x86_64**; `arm64` is wired through but not hardware-validated —
  say so (see [building.md](../building.md#architecture-support)).
- **Distinguish "built but not validated" from "validated."** When a path was
  proven component-by-component but not end-to-end (e.g. Fedora-49 GNOME paste,
  blocked by a headless-focus limitation, not a defect), state the caveat
  honestly rather than rounding up to a green checkmark.
- **Never invent features.** Wispr Flow's launcher is deliberately scoped — it has
  no menu-bar / titlebar / IBus overrides. Don't document overrides that don't
  exist.

## Antipatterns

- **Duplicating the quickstart in three places.** The README is the storefront
  (pitch + link to docs); real build steps live in `building.md`, configuration
  in `configuration.md`.
- **`docs/` without an `index.md`** — GitHub renders an alphabetical file list and
  contributors get lost.
- **Uppercase / SHOUTY filenames** (`TROUBLESHOOTING.md`). Lowercase kebab-case
  throughout.
- **Free-form FAQ prose** ("Q: …? A: Well, you might…"). Use `## <symptom>` →
  `### Fix` → code instead.

## What stays in README vs. `docs/`

| In README | In `docs/` |
|---|---|
| Elevator pitch (1–3 sentences) | Full prose docs |
| Supported-compositor summary | Per-subsystem deep-dives |
| Link to `docs/index.md` | Everything else |

The README is the project's storefront. `docs/` is the manual. Once a topic
exists in `docs/`, the README links out — don't duplicate.
