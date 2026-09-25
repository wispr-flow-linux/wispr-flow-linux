[< Back to learnings](index.md)

# Test methodology and coverage

How the shell test suite is written so a green run actually means something.
The through-line is one claim: **a passing test proves nothing until you prove
it fails when the code it guards is broken.** Most of the traps below are tests
that shipped green while pinning nothing. The methodology was accumulated in
the sibling project (claude-desktop-debian, largely by its tests/doctor
subsystem owner) across a year of test and doctor PRs; this page carries the
lessons over and grounds them on this repo's suite.

**Source files:**

- [`tests/doctor.bats`](../../tests/doctor.bats) — `scripts/doctor.sh`
  helpers; its `setup()` is the host-isolation template
- [`tests/launcher-common.bats`](../../tests/launcher-common.bats) —
  `scripts/launcher-common.sh`
- [`tests/linux-patches.bats`](../../tests/linux-patches.bats) — each bundle
  patch against a hermetic minified-JS fixture
- [`tests/verify-patches.bats`](../../tests/verify-patches.bats) — the
  omit-one marker matrix for `scripts/verify-patches.sh`
- [`tests/test-artifact-common.sh`](../../tests/test-artifact-common.sh) —
  `run_launch_smoke_test`, the shared headless launch harness
- [`tests/test-artifact-common.bats`](../../tests/test-artifact-common.bats)
  — the harness driven through PATH shims: the CI-only `pkill` sweep and the
  backend assert
- [`tests/test-artifact-{deb,rpm,appimage}.sh`](../../tests/) — per-format
  structural and launch smoke tests
- [`tests/test-patch-stage.sh`](../../tests/test-patch-stage.sh) — the real
  patch stage over the real pinned bundle, run locally before a patch ships
- [`.github/workflows/tests.yml`](../../.github/workflows/tests.yml) — runs
  `bats tests/*.bats` on every push and PR
- [`.github/workflows/test-artifacts.yml`](../../.github/workflows/test-artifacts.yml)
  — the per-format artifact matrix that gates the release job

## Overview

Three test surfaces:

| Surface | Runs | Covers |
|---|---|---|
| **bats unit tests** (`tests/*.bats`) | seconds, every push/PR | pure-shell helpers in `launcher-common.sh` and `doctor.sh`; patch scripts against fixtures; the marker verifier |
| **Artifact tests** (`tests/test-artifact-*.sh`) | per built package, on a tag | deb/rpm/AppImage structure, `--doctor`, headless launch to helper-ready |
| **Manual VM matrix** ([`tests/README.md`](../../tests/README.md), [`.claude/memory/`](../../.claude/memory/README.md)) | human sweeps | GUI behaviour bats cannot reach: the pill, injection into a real app, PTT |

The unit suite is fast and standalone on purpose: a red "BATS Tests" check
means *your code broke a test*, not *the build fell over before tests ran*.
The artifact matrix gates the release job, so a launch regression cannot ship.
Nothing in CI exercises the real Wispr bundle; `linux-patches.bats` runs the
patch scripts against fixtures copied from shipped bytes.
[`tests/test-patch-stage.sh`](../../tests/test-patch-stage.sh) is the local
bridge: it sources `build-linux.sh` and runs its real unpack and patch steps
over the pinned pristine asar, asserts no `[WARN]` from any patch, a
byte-identical second pass, no packed `*.orig`, `node --check` on every
`.webpack/` file of the repacked asar, and every marker. Run it before a
patch ships and on every bump; a version bump still needs the semantic
re-audit in [platform-gates.md](platform-gates.md), since a matching anchor
is not correctness.

The rest of this page is the methodology that keeps those green checks
honest. Read [the half-pinned-test failure class](#the-half-pinned-test-failure-class)
before adding or reviewing any shell test.

## The half-pinned-test failure class

Every trap here produced a **green test that did not pin the behaviour it
claimed.** The fix is always the same discipline, the
[mutation check](#the-mutation-check): break the code by hand and confirm a
test goes red. If nothing does, the test is decoration.

### `run helper` subshells away every variable mutation

The single most repeated bug in the sibling's suite. bats' `run` executes its
argument in a **subshell**, so any counter or flag the helper mutates is thrown
away; the assertion after `run` only sees `$status` and `$output`. A doctor
check's whole contribution to the exit code is
`_doctor_failures=$((_doctor_failures + 1))` in `_fail`, and `run_doctor` ends
with `return "$_doctor_failures"`. Assert on `$output` alone and you never pin
whether the FAIL branch actually counted.

`doctor.bats` already has the honest shape: it uses `run` for the output
assertions and then calls the helper a second time directly for the counter:

```bash
_doctor_failures=0
run _doctor_check_clipboard
[[ $output == *"[FAIL]"* ]]
_doctor_check_clipboard >/dev/null
[[ $_doctor_failures -eq 1 ]]
```

Keep that pattern. Any new test asserting a side effect on `_doctor_failures`
or a similar flag must call the helper directly. Use `run` only when you
genuinely need `$status`/`$output` isolation.

### Anchor tests need a near-miss fixture

A grep or regex anchor is only pinned if a fixture sits one character away
from matching. The sibling had a doctor check matching
`^claude-desktop-unofficial ` against the loaded AppArmor profile set; the
test passed, and so did every weakening of it (dropping the suffix, dropping
the `^`, dropping the trailing space), because the fixture's loaded set was
just `firefox (enforce)`. Adding one near-miss line turned a permissive
weakening from "survives all 7 tests" into "fails 3".

The same applies to `linux-patches.bats`. Each fixture carries the exact
anchor the patch keys on, plus the "leaves unrelated sites alone" case. When a
patch's regex is loosened (a `[^{}]{0,80}` prelude, a quote class), add a
fixture that the *old* regex would have matched wrongly and the new one must
not: a second near-identical site, a decoy with the developer string but not
the call shape. Prove it by loosening the anchor further and watching a test
go red.

### A stub that mirrors the production call can't catch a change to that call

If a `stat` stub keys on `$2 == '%a'`, a production typo from `stat -c '%a'`
to `stat -f '%a'` still passes every test, because the stub answers `%a`
regardless of the flags around it. Run **one** FAIL-branch test against the
real tool on a real fixture (a `0644` file, an unreadable `/dev/input`
directory) and keep the stub only for the un-fakeable case (setuid root, a
present `/dev/uinput`). `doctor.bats` shadows tools with `_hide_commands`,
which is the right tool for absence; presence tests should reach the real
binary where one exists.

### `[PASS]` must mean "read and verified", never "failed to read"

A recurring false-green class: a check emits `[PASS]` over a value it never
parsed.

- **Blank presented as success.** `_pass "Password store: $store"` with an
  empty `$store` prints `[PASS] Password store: `. Warn and return early on
  empty.
- **Non-numeric falls through to PASS.** A disk check guarding only for
  *empty* `df` output lets `avail="N/A"` through; the arithmetic errors and
  execution reaches the PASS branch. Guard with `[[ $avail =~ ^[0-9]+$ ]]`
  and `$((10#$avail))` (a leading zero otherwise dies as octal).
- **Unhandled file type.** A `SingletonLock` check that only handles the
  symlink case lets a regular-file lock, which still hard-blocks Electron,
  fall through to `[PASS] no lock file`. `_doctor_check_singleton_lock` is
  the local equivalent; check both shapes.

Better no line than a green PASS on data the check could not read.

### A poll predicate must be identical to the production predicate

A flake-fix poll that grepped a child's cmdline *without* a trailing space
while the reaper's own predicate required one could green-light the reaper
while the reaper still could not see the child, reproducing the exact
starvation the poll existed to kill. Call the production predicate from the
poll so drift is impossible by construction, and fail loudly after the ceiling
rather than falling through silently.

### Negative assertions that don't fail (SC2314)

A bare `! grep …` that is not the **last** command in a bats test does not
fail the test; the negation is silently a no-op mid-body. Write negative
assertions so their exit status is what bats checks:

```bash
run grep -qF -- '-KILL' "$TEST_TMP/kills"
[[ $status -ne 0 ]]
```

## Host-state isolation

Unit tests must read *their* fixtures, never the developer's live machine.
`doctor.bats`'s `setup()` is the template: redirect `HOME`, `XDG_CACHE_HOME`
and `XDG_CONFIG_HOME` to a `mktemp -d`, then `unset` every ambient variable
the production code might consult (`DISPLAY`, `WAYLAND_DISPLAY`,
`WISPR_USE_WAYLAND`, and every `_DOCTOR_*` path override).

Sandboxing `HOME` alone is not enough. GitHub runners export
`XDG_CONFIG_HOME`, so a test that redirects only `HOME` reads the runner's
real config dir and asserts against empty output. That latent failure
surfaced in the sibling the first day bats ran in CI.

### Stub vs. shim: pick by where the call runs

| Technique | Use when | Why |
|---|---|---|
| **Function stub** (`pgrep() { return 1; }`) | the call runs **in the test shell** | function lookup beats `PATH`; `export -f` is a no-op here |
| **PATH shim** (a script in `$TEST_TMP/bin`, prepended to `PATH`) | the call runs in a **subshell or command substitution** | `$(loginctl …)` forks a child where an un-exported function never reaches |

A test using real `pgrep` on a box running the app sees the developer's live
process, takes the production early-return, and fails only on maintainers'
machines while passing in CI. Stub it.

### `pkill` sweeps must match the real exec path, and only in CI

`run_launch_smoke_test` ends with `pkill -KILL -f "$pkill_match"` to reap
children that PAM re-`setsid`s out of the process group under `runuser`. The
sibling guarded the same sweep behind `[[ -n ${CI:-} ]]` after a developer's
Ctrl-C killed their live local AppImage: every caller's pattern (the
`/usr/lib/wispr-flow` install root, the AppImage path) also matches the real
app on a developer's desktop. The harness clears the pattern outside CI in
one place, so the end-of-run sweep and the cleanup trap read the same
decision, and local runs fall back to the process-group kill alone.
[`tests/test-artifact-common.bats`](../../tests/test-artifact-common.bats)
drives the harness with a `setsid` shim that writes the readiness marker and
a `pkill` shim that records its argv, and asserts the sweep is absent with
`CI` unset or empty and present with the pattern under `CI`; each sweep
test first asserts the harness actually reached the sweep (two passes, no
failure), so a missing `pkill` line is never mistaken for a guard that
worked.

## Artifact launch-smoke methodology

Structural asserts ("the files exist") are not enough. The sibling shipped a
Fedora `SyntaxError` from a bad patch anchor that killed the app on launch
while the rpm test stayed green. `run_launch_smoke_test` boots the artifact
and waits for it to reach ready:

- **Reap the whole process group.** Boot via `setsid xvfb-run
  dbus-run-session -- …` in a fresh process group, then reap with
  `kill -- -PGID`. `setsid` is load-bearing: `xvfb-run`'s own EXIT trap leaves
  Xvfb behind when killed by signal, so only a fresh group reaps the whole
  tree.
- **Poll a readiness marker, not a flat sleep.** The harness polls
  `launcher.log` for `Helper service is ready: true` on a 45 s ceiling and a
  0.5 s tick. Each tick checks the marker *first*, then liveness via
  `kill -0`, so a marker written just before exit still passes. Failure output
  distinguishes "did not reach ready state within Ns" (alive, no marker) from
  "exited before reaching ready state (exit: N)" (died early).
- **Drop privileges for rpm.** Electron hard-aborts as root without
  `--no-sandbox`, so the Fedora container drops to a throwaway user, which
  also exercises the real setuid `chrome-sandbox` path.
- **Name the skip.** Namespace-sandbox denial in a container is an environment
  limit, not a defect; `_smoke_sandbox_denied` recognises the signature and
  reports SKIP, not PASS.
- **One shared cleanup trap.** bash keeps one handler per signal, so a trap
  set inside the smoke block silently overrides a script-scope one and leaks
  whatever it forgot. `_launch_smoke_cleanup` is the single script-scope
  handler, each branch guarded so it is safe however far the script got.

What the marker proves and does not prove matters here. Reaching
`Helper service is ready: true` shows the asar loaded, the patched resolver
took the Linux branch, `isPackaged` was true so migrations ran, and the helper
completed its handshake. It does **not** show the helper got a usable session
environment: the [helper-spawn-env](helper-spawn-env.md) bug leaves the app
recording and the helper answering while injection falls to the no-op `stub`
backend, and the readiness marker alone stays green. `_smoke_check_backend`
closes that gap: after the marker it reads the helper's
`::backend] injection:` line out of `launcher.log` and fails on `stub`, and
fails again if no backend line ever appears (a PASS is read from the log,
never inferred from silence). Known residual gaps are flagged, not hidden:
rpm launch stays SKIP
where the container denies the sandbox, and a renderer crash leaves the main
process alive under Xvfb's SwiftShader fallback.

## The doctor-check testability pattern

Lift an inline block out of `run_doctor` into a named `_doctor_check_*`
helper so it is independently unit-testable, prove the move is byte-identical,
and add path-injection hooks (`_DOCTOR_*`) that default to the real system
paths. `doctor.sh` is already structured this way; the review discipline
attached to each new check is the reusable part:

1. **Diff the extracted helper against the inline original** before trusting
   any new test.
2. **Mutation-test every new test**: "swap the Wayland/X11 precedence",
   "`4755` to `0755` breaks exactly 3 tests", "delete the `break` and the
   double-report test fails".
3. **Demand FAIL-branch coverage and counter asserts**, not just the PASS
   path. This is where the `run`-subshell trap keeps reappearing.
4. **Unset each new `_DOCTOR_*` hook in `setup()`** so an exported value from
   the invoking shell cannot leak in.

New checks that insert at the same anchor conflict in `doctor.sh` while the
bats side auto-merges; land them in sequence with keep-both rebases.

## Review heuristics

What to demand when reviewing a fix.

- **The mutation check is mandatory.** Revert or weaken the fix by hand; if
  the suite still passes, the test guards nothing. A green suite over a
  *known* defect proves the coverage hole, not correctness.
- **Claimed verification must ship as a committed test.** Methodology cited
  in the PR body but absent from the diff is changes-requested. A manual
  `shellcheck` or `node --check` run gets codified so the next edit cannot
  regress it.
- **Watch for hollow assertions.** A test that checks the fixture against
  itself (the sed never touches the branch the grep inspects) cannot fail from
  a regression in the fix. A test name that does not match what it validates
  hides an uncovered edge.
- **Name the verification level honestly.** State what ran live and what was
  read. Treat "static-verified-only" as an open gap and add the cheap live
  assert that removes the qualifier. Leave real-hardware confirmation as an
  explicit unchecked item rather than implying it is done. Several PRs in the
  September 2026 queue cite verification against 1.5.695 or 1.5.789 fixtures
  while main ships 1.6.7; say which bundle a regex was run against.
- **Doctor-vs-launch parity.** `--doctor` must observe the exact environment
  the launch will: same config, same env, same helper spawn. The helper-env
  bug is the local instance of this class; a doctor that probes the helper
  with the full session env while the app spawns it with a replacement env
  reports green on a broken install.
- **Shared surfaces stay distro-agnostic; magic numbers get justified or
  overridable.** `doctor.sh` ships in every format, so "reinstall the .deb"
  advice is wrong for AppImage and rpm users. A hard-coded threshold needs a
  rationale comment or an env override.

## The mutation check

Before calling any shell test merge-ready, neuter the code it guards and
confirm a test goes red. Concretely, for a new or reviewed test ask:

1. Does it assert on a **side effect** (a counter, a flag)? Then it must call
   the helper directly, not via `run`.
2. Is there a fixture **one character** away from the anchor it claims to
   pin?
3. Does at least one branch run the **real** external tool, not only the
   stub?
4. Does `[PASS]` only fire on data the check actually **read and parsed**?
5. Does the negative assertion's exit status reach **bats** (last command, or
   via `run` plus `$status`)?
6. If you **revert the fix**, does a test fail?

Question 6 is the one that matters. The rest are the specific ways the answer
to 6 comes out "no" while CI stays green.

## The advisory test review

`scripts/test-review.sh` asks the questions above of every PR, run by
[`test-review.yml`](../../.github/workflows/test-review.yml). It advises; it
never blocks a merge.

```bash
scripts/test-review.sh --base origin/main   # this branch's diff
scripts/test-review.sh --all                # every @test in tests/
scripts/test-review.sh --calibrate tests/fixtures/test-review
```

Two layers:

- **Grep, exact.** A changed script no `tests/*.bats` file names is a FAIL;
  one named only by `tests/*.sh` is a FAIL too, since PRs run only the bats
  suite and the artifact and patch-stage tests run on tags or locally. A
  `scripts/patches/` change with no `linux-patches.bats` change is worth a
  look.
- **Jev, judged.** TypeSafe's Jev answers typed yes/no and choice questions
  with probabilities. Each changed `@test` (with its file's `setup()` and the
  code it calls), each changed function (with the tests that name it, or the
  bats files that run its script) and the PR description go in one call
  each. The questions are mutation-check items 1-5 above plus the
  test-integrity auditor checks: stubs that never drive the guard to fire, a
  test restating a pinned constant, a test grepping the source instead of
  running it, a syntax or marker check offered as behaviour, and host
  dependence (reported as an environment note, not a failure). Item 6 needs
  an execution and is not asked.

Questions, remediation text and which answer fires which check live in
[`scripts/test-review-checks.json`](../../scripts/test-review-checks.json);
thresholds are `TEST_REVIEW_*` variables. A check with an `applies` question
fires only when it applies (≥ 0.5): under 0.3 compliance is FAIL, under 0.7
is "worth a look". A missing or malformed answer, or an API error, makes the
run INCOMPLETE (exit 2), never a PASS.

The key goes in the repository's Actions secrets as `TYPESAFE_API_KEY`.
Without it (and on every fork or Dependabot PR, which GitHub denies secrets)
the grep layer still runs and the report names the skipped Jev layer.
The workflow is plain `pull_request`, never `pull_request_target`, because it
executes the PR's own copy of the script.

**Calibrate before trusting it.** `tests/fixtures/test-review/` holds one
known-bad case per check, built from the failures on this page, and two clean
cases in the repo's honest style. `--calibrate` fails on any case whose fired
checks differ from its `expect` file and prints Jev's raw answers for tuning.
Run it and `--all` after adding the key and after every Jev model change (the
report names the model that answered); keep it advisory until both come back
clean. The PR code goes to TypeSafe's API, which is fine for this public
repo.

## Cross-references

- [patching-minified-js.md](patching-minified-js.md) — the same discipline
  on the patch side: exactly-one assertions, idempotent re-runs, verify
  against real bytes, and why a marker cannot see a behavioural regression.
- [helper-spawn-env.md](helper-spawn-env.md) — the silent-`stub` failure the
  launch smoke test's backend assert exists to catch.
- [platform-gates.md](platform-gates.md) — the per-version re-audit that
  stands in for a real-bundle patch test.
- claude-desktop-debian `docs/learnings/test-methodology-and-coverage.md` —
  the source of this page, with the PR-by-PR history behind each trap.
