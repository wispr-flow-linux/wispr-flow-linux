# PR triage plan — September 2026

Working plan for clearing the 17 open PRs, unbreaking the build against Wispr
1.6.897, and adopting the pipeline practices that claude-desktop-debian
outgrew this repo on. Reviewed 2026-09-21 against `main` at `a08df87`.

```
Phase 0  approve CI on fork PRs                (5 min, no risk)
Phase 1  audit 1.6.897 locally, fix drift      (blocks everything else)
Phase 2  pin the installer, land the resolver  (turns the bump bot back on)
Phase 3  merge the clean PRs, close the dupes  (one afternoon)
Phase 4  contributor round-trips               (parallel with 3)
Phase 5  pipeline hardening from cdd           (after the first clean bump)
Phase 6  pill strategy + helper v0.1.3         (needs a decision first)
```

## State on 2026-09-21

- Wispr's `latest` redirect lands on an unversioned bootstrapper stub, so
  `scripts/setup/resolve-installer-url.sh` fails, every `./build.sh` without
  `--exe` fails, and `check-wispr-version.yml` has failed nightly since
  2026-09-14. Main pins 1.6.7; upstream is 1.6.897 (the third segment is a
  build counter: 1.6.7 → 1.6.531 → 1.6.774 → 1.6.827 → 1.6.897).
- Direct installer URL and sha256 are published in
  `https://dl.wisprflow.com/wispr-flow/win32/latest.json`; the Squirrel
  `RELEASES` manifest and the full nupkg in the same directory also resolve.
- No patch on main has been re-audited against a 1.6.7xx+ bundle. #55 reports
  `helper-env.sh` is a silent no-op on 1.6.774+ (anchor moved into a factory),
  so injection falls to the `stub` backend. Today that patch hard-fails on its
  anchor count, which is the only thing keeping the bot from shipping an
  unaudited build once the resolver works.
- `check-wispr-version.yml` commits and pushes a `v*` tag with no human gate;
  `ci.yml` then builds, releases, and publishes to APT/DNF/AUR. The APT job
  removes the previous package from the index before adding the new one.
- No CI has run on any fork PR: every run is `action_required` awaiting
  first-time-contributor approval. All 17 PRs have maintainer edits enabled.
- crafteraadarsh's pill PRs depend on five stacked, unmerged extension PRs in
  `wispr-flow-linux/helper` (#16–#20). Helper latest tag is v0.1.2.
- Only 1.5.789 is staged locally in `build-linux/stage/`; anchors below were
  checked against that bundle unless noted.

## Per-PR verdicts

| PR | Author | Verdict | Notes |
|---|---|---|---|
| #55 | khamsakamal48 | cherry-pick | 4 commits, one per fix. Author silent since Sept 6. Take helper-env re-anchor, resolver, appdata icon; drop the version-bump hunk. |
| #70 | crafteraadarsh | keep open, redirect | Ask for RELEASES + direct nupkg fetch verified by the manifest sha1 as the fallback path; credit #55. |
| #59 | nihalebr | close | Stale one-line bump to 1.6.827; bot handles this. |
| #40 | Anirudh-K96 | edit + merge | Bump `rev`/`version` to helper v0.1.2 and re-derive the hash, or make nix read `helper-version.txt`. |
| #39 | jaikr-dev | merge as-is | Hub `focusable` gate. Dev-string anchor, count=1, marker, tests, changelog, 3 community confirmations. Closes #36 #56 #72. |
| #45 | Techyid613 | close, credit | Byte-identical to #39. |
| #74 | vascode2 | close, credit | Same fix; minified-identifier anchor matches 0 sites on 1.5.789; no tests/marker. |
| #51 | jcartu | edit + merge | Early singleton lock. Root cause and lock-path parity verified. Trim changelog entry, add attribution. |
| #69 | crafteraadarsh | round-trip | Autostart shim. Needs bats, changelog, troubleshooting entry, doctor line. Silent first-launch enable is upstream parity; say so. Check GNOME no-tray case. |
| #66 | crafteraadarsh | edit + merge | Disable pill drag. Wrap one 130-col comment, add changelog. |
| #67 | crafteraadarsh | drop | 200x110 on all Linux clips toasts for X11 users; moot once #78 lands. |
| #68 | crafteraadarsh | round-trip | Global `screenX` replace, 49px dock guess, wrong off GNOME. Fix main-side from the window's own bounds. |
| #78 | crafteraadarsh | hold | Right approach; blocked on helper #19/#20 + v0.1.3. Rebase off #68's commit. |
| #73 | vascode2 | round-trip | See "#73 diagnostic ask" below. |
| #77 | vascode2 | close, credit | Context menu has no alpha poll and is full-work-area by design; carries #74's commit. |
| #42 | caio-passos | edit + merge | Soften the "Mutter has no data-control" sentence (contradicts `wayland-injection.md`). |
| #37 | rajivranjanmars | merge as-is | Accurate against `doctor.sh` and the learnings. |

Merge order for the clean set: #39 → #37 → #42 → #51 → #66 → #40. #51 and
#66/#69 all append to the same three hunks (`build-linux.sh` patch block,
`MARKERS=(` in `verify-patches.sh`, `MARKER_SAMPLES` in
`tests/verify-patches.bats`); rebase each on the previous.

### #73 diagnostic ask

- The alpha-threshold patch anchors on `(e,t=0)=>{const n=new r.eu`, which
  does not exist in the 1.6.7 bundle: the poll there has no threshold
  parameter. Their "threshold active" evidence came from a 1.5.x build.
- Threshold 10 makes upstream's `rgba(0,0,0,0.004)` hover bridge
  click-through, so the pointer drops out of the hover chain between the pill
  and its globe. #78 describes the same gap independently.
- Force-passthrough on every `mouseDown` leaves the window click-through until
  the cursor moves (the poll only re-calls `setIgnoreMouseEvents` when
  `getCursorScreenPoint()` changes), so a repeat click on the same button
  falls to the app underneath.
- `lastAlphaCheck: null` in their logs is airtight for "no capture ever
  completed" but does not explain the swallowed click by itself; the poll is
  the only path that turns capture on. The open question is why creation-time
  click-through stopped holding right after monitor hotplug.
- Ask: log `powerMonitor.getSystemIdleState(600)` and `xwininfo -shape` on the
  status window before/after hotplug on their hardware (XWayland,
  `--ozone-platform=x11`). Candidate fix: re-assert `setIgnoreMouseEvents(!0)`
  after any bounds change on Linux and drop the `systemState!=="active"`
  early-out. One patch, dev-string anchor, `[\w$]+` identifiers, marker,
  verify entry, bats.

## Phases

### Phase 0 — approve CI

Approve the pending workflow runs on every fork PR from the Actions page.
Authors get shellcheck and bats results without maintainer time.

### Phase 1 — audit 1.6.897 before the bot can ship it

1. `./build.sh --exe` with the direct URL from `latest.json`. Do not merge a
   resolver fix first; that re-arms the nightly tag push.
2. Note every patch that fails its anchor assertion, then hand-check the ones
   that still match for semantic drift (a match is not correctness).
3. Fix all drift in one PR. Known: `helper-env.sh` needs the `{sentryDSN:`
   anchor from #55. Each loosened regex follows
   `docs/learnings/patching-minified-js.md` (quote class, callee-indirection
   prefix, bounded `[^{}]` prelude, developer-literal terminus) and gets a
   near-miss fixture in `tests/linux-patches.bats` that the old regex would
   have matched wrongly.
4. In the same PR, make `run_launch_smoke_test` fail when the helper reports
   the `stub` backend (a second grep on `launcher.log` after the readiness
   marker). This is the assert that would have caught the helper-env silent
   no-op; it must be in place before the bump bot is re-armed.
5. Run the three artifact tests and a real desktop smoke test on the result.

### Phase 2 — pin the installer, land the resolver

**Status (2026-09-21): built and verified in PR #84, unmerged.** Merge
re-arms the nightly tag push; the publish-gate decision below is the
maintainer's call before merging (or merge and dispatch by hand at once).
#59 closed with credit; #70 redirected to the `RELEASES`+nupkg fallback.

Transferred from cdd: the build reads a pin file; only the bump workflow
resolves live.

1. Add `scripts/setup/installer-pin.sh` (or equivalent) holding
   `WISPR_VERSION`, `WISPR_INSTALLER_URL`, `WISPR_INSTALLER_SHA256`.
2. `download.sh` fetches by pin and hard-fails on sha256 mismatch (cdd's
   `verify_sha256` in `_common.sh:27`). `--exe` stays as the local override.
3. `check-wispr-version.yml` resolves via `latest.json` (#55's resolver),
   rewrites the pin file, commits, and tags. Keep the Nix version sed.
4. Cherry-pick #55's helper-env and appdata commits with authorship preserved.
5. Dispatch the bump workflow and watch the first 1.6.897 tag build.
6. Close #59. Redirect #70 to the RELEASES/nupkg fallback.

Optional gate: put the `release` and `update-*-repo` jobs behind a GitHub
`environment:` with a required reviewer, or have the bot open a PR instead of
tagging. cdd runs ungated and relies on fail-closed anchors; roughly one in
three of its auto-bumps goes red and ships nothing. The gate matters most for
the first bump after a multi-version jump; drop it after that if it becomes
friction.

### Phase 3 — merge the clean PRs, close the duplicates

- Push the small edits yourself (all PRs allow maintainer edits): #40 pin
  bump, #42 wording, #51 changelog, #66 comment wrap.
- Merge #39, #37, #42, #51, #66, #40 in that order.
- Close #45, #74, #77, #59 with one comment each naming the surviving PR and
  crediting the author. Add each merged external author to a new
  `ACKNOWLEDGMENTS.md` (cdd convention: updated on every merged external PR
  and whenever an issue author's snippet is used).

### Phase 4 — contributor round-trips

- #69: request bats, changelog, troubleshooting entry naming
  `~/.config/autostart/wispr-flow.desktop`, a `--doctor` line reporting it,
  and a check of the stock-GNOME no-tray login start.
- #73: post the diagnostic ask above. Close #77 in the same breath.
- #68: ask for the main-side approach.
- #78: ask for a rebase off #68 once #68's fate is settled; hold for helper.

### Phase 5 — pipeline hardening transferred from claude-desktop-debian

Do these after the first clean auto-bump, each as its own PR.

1. **Upstream tripwires instead of marker grepping.** cdd deleted its
   `verify-patches.sh` in v3.0.0 and replaced it with
   `_check_upstream_tripwires` (`scripts/patches/app-asar.sh:88`), which greps
   the *pristine* bundle for the upstream behaviour each patch depends on. A
   missing marker says the patch didn't apply; a missing tripwire says
   upstream changed the thing the patch exists for. Keep both until the
   tripwires cover every patch, then retire the marker list.
2. **Real-bundle patch-stage test.** Port `tests/test-patch-stage.sh`: run
   the real patch stage against the pinned installer, `node --check` every JS
   file in the repacked asar, assert markers survive repack, assert a second
   pass is byte-identical. Not wired into CI (download size); run before
   every release and in Phase 1.
3. **Guard the smoke test's `pkill` sweep behind `[[ -n ${CI:-} ]]`.** The
   sweep in `tests/test-artifact-common.sh` runs unconditionally today; cdd
   guarded it after a local Ctrl-C killed a developer's live AppImage. (The
   `stub`-backend assert moved to Phase 1.)
4. **Shared patch helper library.** cdd keeps anchor-file resolution (assert
   exactly one file), match-count assertion, marker check, and the
   load-bearing-vs-cosmetic failure split in one place. Eight separate
   status-window scripts across clusters B and C each reimplement this.
   Consolidate to one `linux-status-window.sh` with named sub-patches on the
   cdd model, then re-audit per Wispr bump becomes one file.
5. **Fixture bats with near-miss fixtures.** cdd's `tests/patch-anchors.bats`
   copies shipped minified bytes from two releases and adds near-miss
   fixtures that go red if a regex is loosened. Extend `linux-patches.bats`
   the same way as each patch is touched.
6. **Cross-arch and digest guards in the bump workflow.** Already covered by
   Phase 2's pin file; the cross-arch check does not apply (x64-only
   upstream) but the "resolved version must match the extracted bundle's
   version" warning in `official-deb.sh:191` is worth an equivalent.
7. **Local hooks.** Port `.claude/hooks/pre-pr-lint.sh` (blocks `git push` on
   shellcheck/actionlint failures) and `session-start.sh` (installs jq,
   shellcheck, actionlint, gh). Wire via `.claude/settings.local.json`.
8. **PR policy in CONTRIBUTING.md.** Neither repo has one. Add: duplicates are
   closed with credit to the earliest mergeable PR; PRs with no author
   response for 30 days may be cherry-picked under the maintainer-edits
   policy or closed; first-time contributors get CI approved on request;
   stacked PRs must say so in the first line. This is the cover for Phase 3's
   close comments.
9. **Issue triage automation.** cdd's `issue-triage-v2.yml` plus
   `.claude/scripts/triage/`, `prompts/`, `schemas/` is portable: pinned
   Claude Code CLI, `persist-credentials: false`, seven-day account-age gate,
   prompt-injection scan, deterministic validation, adversarial review,
   public comment + labels. Takes first response off the one maintainer.
   Port after the pipeline work; needs an API key secret.
10. **Decision log entries.** Record in `docs/decisions.md`: installer is
    pinned not resolved at build time; Wayland pill input shaping lives in
    the compositor extension (or not, per Phase 6); PR policy above.

### Phase 6 — pill strategy and helper v0.1.3

Decision required first: accept a GNOME-extension-only story for Wayland
input shaping, leaving KDE/Hyprland (#44) on a fallback?

- Cheap fallback regardless: add `WISPR_USE_X11=1` to `launcher-common.sh`
  (there is a Wayland opt-in but no X11 opt-in). XWayland gives XShape
  click-through today at the cost of HiDPI blur.
- If yes: review helper #16–#20 plus the three competing modifier-leak fixes
  (#6/#11/#14) and #9/#12 that have waited since July; cut helper v0.1.3;
  bump `helper-version.txt`; rebase and merge #78; drop #67; rework #68.
- If no: #78 and #67 close; the X11 opt-in becomes the documented answer and
  a reworked #73 covers the XWayland dead-zone.

## Review evidence index

Per-cluster review notes from 2026-09-21 (agent reviews, verified where
stated):

- Hub focusable: #39/#45 byte-identical; #74 anchor `(0,N.Pv)(d.RA.prefs?...`
  matches 0 sites on 1.5.789 vs #39's regex matching 1. Hub `on("show")`
  already calls `setFocusable(!0)` on every platform; `withHubFocusSuppressed`
  is `isMac`-gated. Only creation-time state changes.
- Singleton: vendor's `requestSingleInstanceLock()` sits at byte 9.96M of
  9.99M. `app.setName("Wispr Flow")` matches `productName`, so lock paths
  agree. Electron short-circuits a second lock request in the primary. All
  three launchers `exec` Electron, so `process.exit(0)` skips nothing.
- Autostart: `wasOpenedAtLogin` gate is `app.isPackaged && ...`; launcher
  exports `ELECTRON_FORCE_IS_PACKAGED=true`; `--hidden` forwarded via `"$@"`.
  New-user hook `!e?.appLastClosedTime && ... setLoginItemSettings({openAtLogin:!0})`
  runs on every platform.
- Pill cluster: `window.electron?.platform?.os` exists in the status
  renderer; no main-bundle `getTitle()` site reads the status window, so
  #78's title channel is safe. Pairwise conflicts are same-block appends only.
- Resolver: `latest.json` → `Wispr Flow Setup-v1.6.897.exe` + sha256;
  `RELEASES` → `WisprFlow-1.6.897-full.nupkg`; HEAD on Setup-v1.6.8 is 404.
- Nix: `nix` not installed on this host; hash for v0.1.2 not computed.
