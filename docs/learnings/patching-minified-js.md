[< Back to learnings](index.md)

# Patching minified JavaScript

Hard-won rules from maintaining a long-lived patch suite against an actively
re-minified Electron bundle. Each section names a failure mode and the fix. The
rules are upstream-agnostic; the examples and the verification recipes are
grounded in this repo's patches (`scripts/patches/*.sh`) and toolchain
(`resolve-installer-url.sh`, `7z` nupkg extraction, `.webpack/main/index.js`,
`build.sh --build …`).

Wispr Flow's main bundle is webpack output at
`.webpack/main/index.js` (renderers at `.webpack/renderer/<name>/index.js`); the
patches are Python `re` + `sed` keyed on it. See
[platform-gates.md](platform-gates.md) for re-auditing a bundle after a Wispr
version bump (and the `prettier --ignore-path /dev/null` beautify trick).

## Capturing identifiers: `\w` doesn't match `$`

JS identifiers allow `$` and `_`; minifiers freely emit names like
`$e`, `C$i`, `g$x`. The character class `\w` is `[A-Za-z0-9_]` — it
does not match `$`. A `(\w+)` against `$e` captures the suffix `e`
and returns a name that doesn't exist in the file. The failure is
silent: regex matches, downstream sed runs against a truncated name,
asar ships broken JS.

Use `[\w$]+` (repo convention; `[$\w]+` is equivalent). Strict superset of
`\w+`, so pre-`$` versions still match. Every patch in `scripts/patches/` keys
on it — e.g. `helper-resolver.sh:119` captures both the `fs` module and the
path variable out of the resolver's existence guard:

```python
r'(?P<guard>if\(!(?P<fs>[\w$]+)\(\)\.existsSync\((?P<var>[\w$]+)\)\))'
```

With `\w+` a minified `if(!$e().existsSync($t))` would capture `e`/`t` and the
rewrite would reference identifiers that aren't in the file.

## The beautified false-negative trap

Testing a regex against a beautified copy of the bundle is not verification. The
prettier-beautified text has whitespace and parens the minified bytes don't, so
a pattern can pass one and fail the other.

Shipped minified bytes:

```js
await new Promise(n=>setTimeout(n,g$x))
```

Beautified copy:

```js
await new Promise((n) => setTimeout(n, g$x))
```

`await new Promise\(([\w$]+)=>\s*setTimeout\(\1,\s*([\w$]+)\)\)` fails the
beautified version on the parens and the spaces around `=>`. Beautify to *read*
and locate the site (see [platform-gates.md](platform-gates.md)), but always
close the loop against the shipped minified bytes the patch actually runs on.

## Whitespace tolerance: `\s*` vs `[ \t]*`

`\s` matches newlines. A `\s*`-padded pattern is a license to span
across structural boundaries the original line layout meant to
keep apart — usually fine on minified bytes (no newlines to span),
much looser on beautified.

Use `[ \t]*` when the intent is "spaces but stay on this line."
Reserve `\s*` for crossing structural boundaries on purpose. The
`scripts/patches/` suite mixes both — `\s*` where the surrounding context is
bounded enough that newline-spanning is harmless, and literal token sequences
(`"win32"===process.platform`, `titleBarStyle:"hidden"`) where stricter
adjacency is the whole point of the anchor.

## Quote style: `"` is not stable either

Whitespace tolerance assumes the *tokens* hold still and only the spacing
moves. The sibling project (claude-desktop-debian) had that assumption broken
by a bundler swap: every short string literal flipped from `"` to backticks in
one release (46,526 double-quoted literals became 3,050; backticked went from
429 to 44,701). Four of its ten anchors matched on a `"`-delimited literal and
went to zero. The build-fatal ones failed the build, which is what the guards
are for, but the diagnosis cost a triage cycle because "anchor not found" reads
as "upstream deleted the feature" and the feature was untouched.

Wispr's webpack bundle emits `"` today (`"win32"===process.platform`,
`titleBarStyle:"hidden"`), so every anchor in `scripts/patches/` pins the
delimiter. **Never write a bare quote in a new anchor.** Build the class once
in the Python heredoc and concatenate it:

```python
Q = r'[`"\']'                       # any JS string delimiter
anchor = re.compile(
    Q + r'win32' + Q + r'===process\.platform')
```

Two related shifts tend to land with a bundler swap, so treat it as a class of
breakage rather than one delimiter change:

- **Callee indirection.** `X.spawn(` becomes `(0,ye.spawn)(`. Wispr's bundle
  already emits this shape as the default (the hub window config reads
  `(0,N.Pv)(d.RA.prefs?.user.email||"")`, the alpha-poll sites read
  `(0,l.Bi)(`), so a call-site anchor wants
  `(?:\(0,\s*[\w$]+(?:\.[\w$]+)*\)|[\w$]+)` in front of the paren, not a bare
  identifier. This is also why PR #74's anchor on the literal
  `(0,N.Pv)(d.RA.prefs?...` text matches zero sites on the next release: the
  `N`/`d` are the churn, the `(0,…)(` shape is the constant.
- **Syntax level.** Optional chaining (`?.`) is preserved rather than
  downleveled, and `let` replaces most `const`/`var`. `(?:const|let|var)` beats
  any one of them.

When concatenation is re-emitted as interpolation, a message that was one
contiguous literal becomes a template with a `${...}` hole in the middle, so an
anchor spanning that hole breaks even though the delimiter class is right.
Anchor on the *stable prefix* before the first variable, not the whole
sentence. `linux-disable-pill-drag.sh` (PR #66) does this: it anchors on
`[Drag Overlay]: Setting drag overlay state to` and stops before the value.

## Replacement-string escaping: `\1`, `&`, `$1`

A regex can match correctly and still produce corrupted output
because the *replacement string* has its own metacharacters. Match
debugging shows green; the asar still ships broken bytes. Three
flavors:

**sed `&`** — the entire match. `sed 's/foo/&_suffix/'` is fine
(`foo_suffix`). `sed 's/foo/literal_&_dollar/'` accidentally
interpolates the match (`literal_foo_dollar`). Escape with `\&` if
you want a literal ampersand:

```bash
sed 's/foo/literal_\&_dollar/'   # → literal_&_dollar
```

**sed `\1`** — backreferences in the replacement work as expected in BRE/ERE.
The footgun is the *pattern* side: in BRE, `$` is the end-of-line anchor, so a
literal `$` in the search pattern needs `\$`. This bites here because the suite
captures identifiers as `[\w$]+` and a minified name is routinely `$e` / `C$i`;
feed that name back into a sed pattern unescaped and the `$` reads as the
end-anchor. Escape it before interpolating:

```bash
var_re="${var//\$/\\$}"   # $e -> \$e  before use in a sed pattern
```

**JS `String.prototype.replace`: `$1`, `$&`, `$$`** — the JS
replacement DSL is its own thing. `$&` is the whole match; `$1..$9`
are capture groups; `$$` is a literal `$`. Plain `$` followed by an
unrelated char is left alone, but `$&` and `$N` get interpolated:

```js
code.replace(/foo/g, '$cost')   // → '$cost' (safe, no special)
code.replace(/foo/g, '$&_x')    // → 'foo_x' ($& = match)
code.replace(/foo/g, '$$cost')  // → '$cost' (escaped)
```

If the replacement is an injected JS snippet that happens to
contain `$1` or `$&` (template literals, regex source, a captured
`$`-name), JS will eat them. Use `$$` to escape, or build the string with
concatenation so `$` never sits next to a digit or `&`.

## Idempotency: a re-run must be byte-identical

Without it, CI re-runs and partial builds layer mutations until
something breaks visibly. The suite uses three patterns:

**Inject a marker comment, guard on it.** Every patch writes a unique
`WISPR_LINUX_*` marker into its insertion and short-circuits if it's already
there. `helper-resolver.sh:78-80`:

```bash
LINUX_MARKER="WISPR_LINUX_HELPER_BRANCH"
if grep -q "$LINUX_MARKER" "$BUNDLE"; then
  echo "Already patched ($LINUX_MARKER present in $BUNDLE) - nothing to do."
```

**Key the marker inside the widened predicate.** `linux-window-frame.sh` injects
its `WISPR_LINUX_FRAMELESS` marker *inside* the widened window-config predicate,
so the idempotency grep and the per-site match count both key on the same
insertion — a second run sees its own output and the count stays honest.

**Distinguish "already applied" from "anchor missing."** `mac-gates.sh:40-42`
checks for the darwin gate sitting immediately before the `getAppPath()` call,
and treats that as done — separate from the anchor-not-found path, so the build
log says which one happened.

## Anchor selection: prefer literals over identifiers

The above sections cover making a patch work on first run. This one
covers keeping it working release after release. A patch can apply
cleanly today and silently no-op next month.

Minified identifiers churn every release. Developer strings —
property names, log messages, IPC channel names — survive
minification untouched (true for Wispr's webpack bundle; a
`--mangle-props` build would invalidate property-name anchors).
Anchor on those. A hardcoded minified name silently no-ops the next
release; the build log still says "patched."

Two patterns from the suite:

- **Literal → derived identifier (two stages).** `helper-resolver.sh:110`
  anchors on the developer log string `"Running packaged Windows Helper
  service"`, then captures the surrounding minified logger identifier
  (`([\w$]+)\(\)\.info\(…)`) as the actual target. Stable literal locates the
  site; the dynamic capture supplies the churning name.
- **Literal-shape anchor + captured var.** `linux-window-frame.sh` pins the
  window-config site on the `"win32"===process.platform` /
  `Object.assign(<var>,{titleBarStyle:"hidden",autoHideMenuBar:!0})` literal
  shape and captures only `<var>` as `[\w$]+`. (It used to also anchor on a
  `titleBarStyle:"hiddenInset"` mac branch; 1.5.695 dropped `hiddenInset`, so
  the anchor was narrowed to the still-unique win32-predicate + hidden-assign
  pair — see the re-audit note below.)

The lesson is about finding stable points to anchor on, not about what gets
patched. Even literal anchors aren't immortal: `linux-window-frame.sh` no-oped
on Wispr 1.5.695 because the window-config *shape* itself moved — the mac branch
dropped `titleBarStyle:"hiddenInset"`, and the lone surviving three-way win32
site shifted from the Hub window (now a two-way switch whose else branch already
frames Linux) to the meeting_recorder window. The re-audit narrowed the anchor
to the win32-predicate + hidden-title-bar `Object.assign` pair (still unique).
This is why a version bump means a re-audit ([platform-gates.md](platform-gates.md)),
and why the count assertion below turns that no-op into a loud failure instead of
a silent one.

## Multi-site coordinated patches: surface partial application

Site 1 patches, site 2 misses, the asar ships half-wired. Two layers guard this.

Per patch: assert the expected match count and bail otherwise.
`linux-window-frame.sh` declares how many sites of the shape *should* exist and
refuses to widen an unknown count:

```python
if len(matches) != EXPECTED:
    sys.exit(
        f"ERROR: expected exactly {EXPECTED} frameless window-config site(s), "
        f"found {len(matches)}. Bundle layout may have changed; re-audit …")
```

For a patch applied across many files — `linux-renderer-treat-as-windows.sh`
runs over every `.webpack/renderer/*/index.js` — the driver in
`build-linux.sh` Step 3 grep-filters to the renderers that actually read
`platform?.isWindows`, so a renderer that doesn't is skipped (not failed), and
one that should match but doesn't surfaces as a missing marker.

Across the whole suite: `scripts/verify-patches.sh` static-greps the *shipped*
asar for each patch's marker, so the half-patched state fails the build even
when individual patches each logged "applied." (That gate is exactly what caught
the 1.5.695 window-frame regression: `MISSING window-frame: linux frameless
window branch`.)

## Disambiguating non-unique anchors: assert the count, narrow the region

A string anchor can appear in source maps, dead exports, or chunk-merged
duplicates alongside the live code. Picking the first match (`re.search` /
`indexOf`) may be wrong.

The suite's defense is to **assert the count and bail** rather than guess: the
`EXPECTED`-count check above fails loudly the day upstream reintroduces the
anchor shape in onboarding text or sample data far from the live site, instead
of silently patching the wrong one.

When an anchor genuinely isn't unique, narrow the search region first.
`helper-resolver.sh` scopes its rewrite to the `if(!…existsSync(…))` guard
region rather than the whole file, so duplicate sub-strings elsewhere can't be
hit.

## Anchors carry unstated assumptions: adjacency, terminus, survival

Stopping an anchor before the part that churns leaves it holding assumptions it
never states. The sibling project lost the same patch to each of these in
turn; Wispr's suite has already met the first.

**Adjacency.** An anchor that spans two tokens assumes they stay next to each
other. PR #73's always-on-top watchdog anchors on `performance.now();if(`; the
1.5.789 bundle reads `performance.now();var t;if(`. One inserted statement,
zero matches. The sibling's version of this was a function head glued to its
first destructure until upstream put an `await` in front, which cost four
consecutive upstream bumps with no release. Leave a bounded prelude between
the tokens you span, and fence it on braces rather than on `.`:

```python
r'performance\.now\(\);[^{}]{0,80}if\('
```

`[^{}]` cannot cross a nested block or leave the function body, so the budget
buys a couple of simple statements and nothing structural, where `.{0,80}`
would happily reach past an `if(e){t()}` into an unrelated site. Loosening
buys back the match at the cost of the uniqueness the tight version got for
free, so pay for it twice: keep a discriminator past the loosened joint (a
developer string, a distinctive call) and assert exactly one match.

**Terminus.** The end of an anchor is an assumption too. The sibling's patch
ended on a `();return` statement shape; the next release moved the value into
a helper call and the shape dissolved while the function's developer log
string sat untouched in its body. Statement shapes are the minifier's to
rearrange; end on a developer literal instead, cut before any interpolation
so a template re-emission cannot split it. `helper-resolver.sh` already has
this shape: it locates the site by `"Running packaged Windows Helper service"`
and captures the churning logger name around it.

A body budget generous enough for the real function is also generous enough
to absorb the patch's own injected code on a re-run. Brace the injected gate
(`if(…){return!1}`) so a `[^{}]` fence cannot swallow it, and keep the
idempotency test: when a mutation on defensive code comes back green, ask what
else is covering for it.

**Survival.** A patch that locates its own site has a second job: the anchor
must still match *after* the patch has run, or a second pass fails at
resolution before the idempotency guard ever executes. Six of the sibling's
first ten self-resolving anchors failed this. Pick a resolution anchor
adjacent to the edit rather than through it, or teach it to tolerate the
patch's own marker. `linux-window-frame.sh` keys its `WISPR_LINUX_FRAMELESS`
marker *inside* the widened predicate for exactly this reason. Test it
explicitly: run the whole patch stage twice against one tree and assert the
second run is a no-op and the repacked asar is byte-identical
(`linux-patches.bats` does this per patch on fixtures; nothing does it yet
against the real bundle).

## Resolve the target file, don't name it

Wispr's main process is one file, `.webpack/main/index.js`, and every main
patch hardcodes that path. The sibling's main process was one file for years
too, until upstream code-split it into an entry stub plus content-hashed
chunks whose names change every release. Every patch anchored on the old path
silently missed; the fatal ones failed the build, the warn-only ones shipped
an under-patched asar. Two releases later the split deepened and "resolve one
main file, hand it to every patch" stopped working as well.

The durable shape is per-anchor resolution: grep the whole bundle tree for the
anchor's stable literal, assert exactly one file carries the *full anchor
shape* (not just the distinctive string, which can recur in a decoy chunk),
patch that file. `linux-renderer-treat-as-windows.sh` is already there for the
renderer side: `build-linux.sh` grep-filters `.webpack/renderer/*/index.js`
for the renderers that read `platform?.isWindows` rather than naming them. If
`.webpack/main/` ever grows a second file, do the same for main.

Two mechanical footnotes. Resolve with `grep -lPz`, not `grep -lP`: bare `-P`
is line-oriented, so a `\s*` cannot cross a newline and a beautified copy
reports the anchor missing (the beautified false-negative trap, now in the
resolver). And confirm uniqueness *within the resolved file*, not across the
tree: a literal unique in one 8 MB file can recur across chunks in source-map
tails and dead re-exports.

## Verifying a hypothesis before shipping a fix

Resolve the current installer URL, download, extract without beautifying, and
test the regex against the minified bytes the patch will actually run on:

```bash
scripts/setup/resolve-installer-url.sh > resolved.txt
url=$(grep '^URL=' resolved.txt | cut -d= -f2-)
mkdir -p /tmp/verify && cd /tmp/verify
curl -fSL -o setup.exe "$url"

7z x -y setup.exe -o exe
nupkg=$(find exe -name 'WisprFlow-*-full.nupkg' | head -1)
7z x -y "$nupkg" -o nupkg
npx @electron/asar extract nupkg/lib/net45/resources/app.asar app

node -e '
  const fs = require("fs");
  const code = fs.readFileSync(
    "app/.webpack/main/index.js", "utf8");
  const re = /Object\.assign\(([\w$]+),\{titleBarStyle:"hidden",autoHideMenuBar:!0\}\)/;
  const m = code.match(re);
  console.log(m ? `MATCH: ${m[0]}` : "NO MATCH");
'
```

`NO MATCH` means the regex is wrong for the current bundle. Note Wispr's
`resolve-installer-url.sh` tracks the upstream `latest` redirect and does **not**
pin a SHA-256 (the build logs `No SHA-256 hash … skipping verification`), so
"the current bytes" is whatever `latest` resolves to right now — re-pull before
testing rather than trusting a stale local extract. Since September 2026 that
redirect lands on an unversioned bootstrapper stub and the resolver fails;
until the pin-file rework lands, take the direct `Setup-v<ver>.exe` URL and
its sha256 from `https://dl.wisprflow.com/wispr-flow/win32/latest.json` and
pass it with `--exe`.

## End-to-end verification (post-build)

Four layers: build log, syntactic validity, asar markers, runtime.

1. Watch the build log for partial-application warnings:

   ```bash
   ./build.sh --build appimage --clean no 2>&1 | tee build.log
   grep -E 'WARNING:|MISSING|expected exactly' build.log
   ```

   Any `WARNING:`, a `MISSING` marker, or a count-assertion `ERROR:` is a
   half-patched asar — `build-linux.sh` already hard-fails on the marker check,
   but grep the log when iterating locally.

2. `node --check` on the patched bundle — catches malformed replacements that
   serialize but don't parse:

   ```bash
   node --check build-linux/app.asar.contents/.webpack/main/index.js
   ```

3. Static-grep the shipped asar for every patch marker.
   `scripts/verify-patches.sh` automates this (its `MARKERS` array pairs a human
   label with a fixed/Perl pattern) and runs in CI on the deb build via the
   `Verify Linux patches in shipped asar` step in
   `.github/workflows/build-amd64.yml`.

4. Launch the package and check runtime state — the strongest layer. The
   headless smoke test in `tests/test-artifact-common.sh` boots the app under
   Xvfb + a private D-Bus session and polls `launcher.log` for the helper
   readiness marker:

   ```bash
   grep -F 'Helper service is ready: true' \
     "${XDG_CACHE_HOME:-$HOME/.cache}/wispr-flow/launcher.log"
   ```

   Reaching it proves the asar loaded, the patched helper-resolver took the
   Linux branch, the renamed Electron binary set `isPackaged=true` (migrations
   ran), and the helper IPC handshake completed — far more than a structure
   check.

## One gate, multiple consumers: a marker can't catch a re-armed sibling

A single minified predicate is often read by several independent code paths.
Patching it at the source flips all of them, some you want and some you don't,
and a marker check won't catch the ones you didn't because nothing is
*missing*: the regression is behavioural.

Two live examples from the September 2026 PR queue:

- **The right way.** `"win32"===process.platform` has roughly 79 reads in the
  main bundle. It gates the shortcut defaults Linux needs, and it also gates
  registry access, `%LOCALAPPDATA%` paths and Windows exit-code semantics.
  PR #55's shortcuts patch widens the flag only inside the shortcuts module
  (eight reads, each a `win?:mac` ternary) and fails closed if any read there
  is not a ternary. Flipping the flag globally would have "worked" for the
  symptom and armed every Windows-only OS call behind it.
- **The wrong way.** PR #73's alpha-threshold patch changes the *default
  parameter* of the shared click-through poll from 0 to 10. Every consumer of
  the poll gets the new threshold. Upstream's status renderer deliberately
  paints its hover bridge at `rgba(0,0,0,0.004)` (alpha 1 of 255) so the poll
  keeps the pill's hover-only controls reachable; at threshold 10 that bridge
  becomes click-through and the pointer drops out of the hover chain. The
  marker is present, `node --check` passes, verify-patches is green, and the
  pill's globe button stops working.

The sibling's case study was worse: flipping a support evaluator to
`supported` for Linux un-greyed a tab and simultaneously re-armed a multi-GB
VM download that a previous patch had disabled, because both read the same
predicate. Its marker checker was green throughout. The fix was not to
un-flip the evaluator but to re-block the now-reachable consumers
individually, and to add a positive marker for the counter-patch so the
restored invariant had a fingerprint that could go red.

Two rules:

- **Before flipping a shared gate, grep every read of the predicate.**
  Enumerate the consumers and decide per site which should follow the flip.
  A patch that works against the symptom you were chasing can arm a sibling
  you weren't looking at.
- **Markers verify structure; only a runtime launch verifies behaviour.** When
  a patch changes a value other code branches on, the post-build launch and a
  log tail for side effects are not optional. The static layers are blind to
  a re-armed consumer. See [test-methodology.md](test-methodology.md) for the
  headless launch smoke test and what it can and cannot prove.

## Cross-references

- [test-methodology.md](test-methodology.md) — the same discipline on the
  test side: exactly-one assertions, near-miss fixtures, idempotent re-runs,
  the mutation check, and the launch smoke test that is the only layer to see
  a behavioural regression.
- claude-desktop-debian `docs/learnings/patching-minified-js.md` — the
  sibling project's copy of this page. The quote-style, adjacency/terminus/
  survival, file-resolution and shared-gate sections above were ported from
  it in September 2026 and regrounded on this repo's patches; its examples
  (a code-split bundle, a bundler swap, a cowork gate) are the ones this
  suite has not met yet.
- [platform-gates.md](platform-gates.md) — the darwin/win32 carve-outs Linux
  falls through, the three gate-shape rules, and how to re-audit (and beautify)
  a new Wispr version's bundle. The natural companion when an anchor no-ops.
- [learnings/index.md](index.md) — the rest of the hard-won subsystem notes.
