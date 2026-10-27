# Maintaining

This is the operating manual for whoever keeps the `wispr-flow-linux` org
running, human or agent: how the four repos fit, how issues and PRs are
triaged, how each repo releases, and what always waits for a maintainer's yes.

```
wispr-flow-linux/wispr-flow-linux  build scripts, app patches, packaging, publish chain
wispr-flow-linux/helper            clean-room Rust helper (prebuilt, pinned here)
wispr-flow-linux/native-modules    prebuilt Linux sqlite addons (pinned here)
wispr-flow-linux/worker            Cloudflare Worker in front of pkg.wispr-flow-linux.dev
```

Contributor-facing rules live in [`CONTRIBUTING.md`](CONTRIBUTING.md); release
mechanics for this repo live in [`RELEASING.md`](RELEASING.md). This page links
to both rather than repeating them.

## How the repos fit

```
helper ── v* tag ──> Release assets ──┐
                                      │ helper-version.txt (+ nix rev/hash)
native-modules ── manual dispatch ──> native-v* assets ──┐
                                      │                  │ native-modules-version.txt
                                      v                  v
            wispr-flow-linux ── v* tag ──> GitHub Release + gh-pages (APT/DNF) + AUR
                                                  │
            worker ── push to main = deploy ──> pkg.wispr-flow-linux.dev
                      (metadata from gh-pages, 302 to Release assets)
```

| Repo | Stack | CI on PRs | What publishes | Trigger |
|---|---|---|---|---|
| wispr-flow-linux | bash, bats, Nix | shellcheck, codespell, flag tests, bats | `.deb`/`.rpm`/AppImage, APT, DNF, AUR | `v*` tag (the nightly bump tags on its own) |
| helper | Rust | `cargo fmt`, `clippy -D warnings`, `cargo test` | x86_64 + aarch64 binaries, glibc 2.35 floor | `v*` tag |
| native-modules | bash, node-gyp, Electron | build + validate when the rebuild inputs change | `.node` addons, glibc 2.28 floor | `workflow_dispatch` with `publish=true` |
| worker | JS, wrangler | none | the Worker itself | push to `main` |

Users file bugs in **this** repo, whatever the root cause. Injection, shortcut
and focus bugs are usually fixed in `helper`, but the user-facing issue stays
here and links the helper PR. Issues in `helper` are for code-level work on
the helper itself.

## What always waits for a maintainer's yes

Everything below is visible to users or hard to undo. An agent working these
repos prepares it and asks; it never does it on its own.

- Merging to `main` in any repo. In `worker`, a merge **is** a production
  deploy.
- Pushing a tag, dispatching the native-modules publish, or editing a Release.
- Repo settings, branch protection, secrets and Actions variables
  (`REPO_VERSION`, `WISPR_FLOW_VERSION`).
- Closing someone else's issue or PR, and posting reviews or comments on their
  behalf.

The one thing that ships without a human is the nightly upstream bump
(`check-wispr-version.yml`, see [D-011](docs/decisions.md)). It only tags after
bats and the patch-stage test pass on the new installer.

## Triage

A new issue gets a type label, an area label, and one state label within a few
days. The rules, in order:

1. **Upstream.** It reproduces on macOS or Windows, or it is about
   transcription, account, login or billing: label `upstream`, point to
   [wisprflow.ai](https://wisprflow.ai) and close. See "What goes upstream" in
   `CONTRIBUTING.md`.
2. **Duplicate.** Keep the issue with the best reproduction open, close the
   other as a duplicate naming it, and carry over any useful detail in the
   close comment.
3. **Missing information.** No `wispr-flow --doctor` output, or no distro,
   desktop and session type: label `needs-info` and ask for exactly what is
   missing.
4. **Reproduced or clearly diagnosed:** `confirmed`. If a PR exists in either
   repo, link it from the issue.
5. **Stale.** `needs-info` with no reply for 30 days: label `stale` and close
   with a note that it can be reopened.

A `bump-failure` issue (opened by the nightly bump) is always first in line:
a broken upstream bump beats new work (see `CONTRIBUTING.md`).

### Labels

The label set is defined in [`.github/labels.txt`](.github/labels.txt) and
applied to all four repos by `scripts/maint/sync-labels.sh`. The script only
creates and updates labels; it never deletes one.

```bash
scripts/maint/sync-labels.sh --dry-run   # show what would change
scripts/maint/sync-labels.sh             # apply to all four repos
```

| Group | Labels |
|---|---|
| Type | `bug`, `enhancement`, `documentation`, `question` |
| State | `needs-info`, `needs-repro`, `confirmed`, `upstream`, `duplicate`, `wontfix`, `stale` |
| Area | `area:status-pill`, `area:injection`, `area:shortcuts`, `area:packaging`, `area:patches`, `area:ci-release`, `area:audio`, `area:onboarding`, `area:gnome`, `area:kde`, `area:wlroots`, `area:x11`, `area:wayland`, `area:docs` |
| PR state | `ready-for-review`, `changes-requested`, `superseded`, `blocked` |
| Meta | `bump-failure`, `priority:high`, `good first issue`, `help wanted` |

## Pull requests

The PR policy in `CONTRIBUTING.md` is the rule: duplicates close with credit,
thirty days of author silence lets a maintainer finish or close, first-time
contributors need their CI runs approved, stacked PRs say so, and patch PRs
name the bundle they were verified against.

When reviewing, hold patches to
[`docs/learnings/patching-minified-js.md`](docs/learnings/patching-minified-js.md)
and tests to
[`docs/learnings/test-methodology.md`](docs/learnings/test-methodology.md), and
cite the section instead of re-arguing it. A patch is re-checked against the
version pinned in `scripts/setup/installer-pin.sh` before merge.

Cross-repo changes land bottom-up:

1. Merge the `helper` PR, bump `Cargo.toml`, tag `vX.Y.Z` on helper `main`.
2. In this repo, point `helper-version.txt` at the new tag and update the
   `rev` and hash in `nix/wispr-flow.nix` (`nix build` prints the new hash).
3. Then merge the patch PR here that depends on the new helper behaviour.

The same order applies to `native-modules` and `native-modules-version.txt`.

## Releases

- **This repo:** follow [`RELEASING.md`](RELEASING.md). Upstream-tracking
  retags are automatic; a project release bumps `REPO_VERSION`, cuts the
  CHANGELOG and pushes a `v{REPO_VERSION}+wispr{X.Y.Z}` tag. Try an `-rc` tag
  first when the packaging changed.
- **helper:** bump `version` in `Cargo.toml` on a PR, merge, then push the
  matching `v*` tag. `release.yml` builds on Ubuntu 22.04 and fails if the
  binary needs a glibc newer than 2.35. Then bump this repo as above.
- **native-modules:** run **Build Native Modules** with `publish=true` and
  `release_tag=native-vN`, then bump `native-modules-version.txt` here. A PR
  that touches the rebuild inputs runs build and validate without publishing.
- **worker:** merging to `main` deploys. The deploy job probes
  `pkg.wispr-flow-linux.dev` and fails on a 5xx or timeout.

## When the nightly bump fails

`check-wispr-version.yml` opens or bumps a `bump-failure` issue and pushes
nothing. The next green run closes it.

1. Read the failed run. `scripts/check-upstream-tripwires.sh` names the
   upstream literal that moved before any patch anchor can miss.
2. Fix the patch per `docs/learnings/patching-minified-js.md`, update
   `scripts/patches/tripwires.tsv`, and add a near-miss fixture to
   `tests/linux-patches.bats`.
3. Re-audit the new bundle's platform gates per
   [`docs/learnings/platform-gates.md`](docs/learnings/platform-gates.md) and
   record it in `.claude/memory/` the way the 1.6.897 and 1.6.937 audits are.
4. Merging the fix re-arms the bot, which tags and publishes on its next green
   run. Treat that merge as a release decision.

## The recurring watch

A scheduled agent check across the four repos reports only news: something a
maintainer needs to decide, or something that broke.

| Counts as news | Not news |
|---|---|
| A new issue or PR (with a proposed triage) | A bot comment, a label change, an edit |
| A reply on a thread waiting on the maintainer | A reply on a thread waiting on the reporter |
| A `bump-failure` or heartbeat failure issue, or a red run on `main` | A red run on a fork PR branch |
| A PR whose CI just went green and is ready to merge | Dependabot or flake.lock bumps that passed CI |
| A new upstream Wispr Flow version | The bump bot's own green retag |

## Agent sessions

Agents read [`CLAUDE.md`](CLAUDE.md) first and the newest handover in
[`.claude/memory/`](.claude/memory/README.md). Anything an agent posts in
public (issue and PR comments, reviews, PR bodies) ends with a line saying who
is driving it, for example `Driven by Claude Duet on behalf of @aaddrick.`, and
discloses AI assistance the way `CONTRIBUTING.md` asks.
