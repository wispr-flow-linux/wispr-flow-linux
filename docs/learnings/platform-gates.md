[< Back to learnings](index.md)

# Platform gates — the darwin/win32 carve-outs Linux falls through

Hey! Wispr Flow only ever shipped two desktop targets, macOS and Windows, so the
whole codebase branches on `darwin` vs `win32` and never imagines a third OS.
Linux doesn't get its own branch — it falls into whichever side happens to be
the `else`. Sometimes that's harmless, sometimes it's exactly wrong, and once
(the headline bug below) it leaves the **left-side menu's expand/collapse toggle
shoved ~68px to the right** with the window-control buttons rendered invisible.
This page is the map of where the gates are, the three rules that tell you which
ones bite, and how I beautified a 15 MB minified bundle to find them.

There are **no Wispr Flow source files** for this — the gates live in the
proprietary, gitignored bundle. What *is* ours:

- [`scripts/patches/helper-resolver.sh`](../../scripts/patches/helper-resolver.sh)
  — adds the `'linux'` helper-path branch (one of the two gates already fixed).
- [`scripts/patches/mac-gates.sh`](../../scripts/patches/mac-gates.sh) — gates
  the macOS Applications-folder guard to darwin (the other one).
- [`docs/reference/ipc-contract.md`](../reference/ipc-contract.md) §6 — why the
  keyboard gates landing Linux in the Windows branch is *correct*, not a bug.

## First, the tooling trap that wasted my morning

The bundle is one minified line per renderer (`hub/index.js` is 15 MB on a
single line). To read it you beautify it. The obvious command **silently does
nothing**:

```bash
# WRONG — exits 0, no error, output byte-identical to input
prettier --parser babel extract/app/.webpack/renderer/hub/index.js
```

Prettier 3.x respects `.gitignore` by default, and this repo gitignores both
`/index.js` and `/extract/`. A gitignored file gets passed through **unchanged**
in stdout mode — no warning, no non-zero exit. You stare at minified output
wondering why prettier "ran." Override it:

```bash
# RIGHT — actually formats
prettier --parser babel --ignore-path /dev/null \
	extract/app/.webpack/renderer/hub/index.js > tools/beautified/hub.index.js
```

Beautified copies are proprietary-derived, so they go in `tools/` (gitignored) —
**never commit them**. The `hub` bundle expands to ~94k lines and formats in
~12s. Variable names stay minified to single letters, so you grep for string
literals and trace the minified token, not the human name.

## Two layers of platform detection — they look nothing alike

**Main process + preload** use literal `process.platform` string compares. The
main bundle has 45 `"darwin"`, 68 `"win32"`, and 28 `"linux"` literals — but most
of the darwin/win32 ones are vendored npm noise (`systeminformation`, `fs-extra`,
`env-paths`…) that already handle Linux. Only ~16 are actual Wispr gates. Two
hoisted flags carry the real ones: `tD = ("darwin" === process.platform)` and
`H8 = ("win32" === ...)` (webpack module `137803`/`137804`). Grep for the flags,
not just the literals.

**Renderers** have **zero** literal platform compares. They read the OS through
the preload bridge: `window.electron.platform.{os, isMacOS, isWindows}`. There is
**no `isLinux`** boolean exposed — but `platform.os` is, so a renderer-side linux
check is `"linux" === window.electron.platform.os`. Every renderer gate is one of
two minified booleans (`isMacOS`, `isWindows`), and on Linux **both are `false`**.
That single fact drives every renderer bug below.

Each renderer reads those booleans **exactly once**, near the top of its main
module, into single-letter module locals:

```js
const y = window.electron,                 // y churns per renderer/release
  $ = y?.platform?.isMacOS  ?? !1,         // isMacOS  local
  x = y?.platform?.isWindows ?? !1;        // isWindows local
```

Every `isWindows`-gated site downstream is then `x ? winThing : macThing` — and
`x` is a **bare single-letter local that the minifier reuses in dozens of
unrelated scopes** (React `useRef`/`useMemo`/`useCallback` all land on `x`), with
no developer string adjacent to most consumer sites. So you cannot reliably
widen the consumers one-by-one; the robust lever is the single **bind** site,
anchored on the preserved `?.platform?.isWindows ?? !1` chain.

## The three rules

Once you internalise these you can classify any gate at a glance:

| Gate shape | Linux lands on | Verdict |
|---|---|---|
| `isMac ? macThing : elseThing` | `elseThing` (the Windows/Ctrl path) | **Usually correct** — don't touch it |
| `isWindows ? winThing : macThing` | `macThing` (the macOS path) | **Usually wrong** — Linux gets mac defaults |
| `if (win32) { … }` no else | nothing | **Linux misses** Windows-only functionality |

Rule 1 is why the keycode tables, the Cmd-vs-Ctrl accelerators, and the ⌘/⌥
glyph rendering are all *fine* on Linux — Linux correctly inherits the Windows
behaviour (Ctrl/Alt, Windows VK keycodes), which is exactly what the
[IPC contract](../reference/ipc-contract.md) says the helper expects. Resist the
urge to "fix" these.

## The headline bug — it's CSS, not a JS gate

The left-menu offset everyone notices is **not** a `=== "darwin"` test. The
renderer does this on boot:

```js
document.documentElement.classList.add(window.electron.platform.os)
```

On Linux that adds class **`linux`** to `<html>`. But every platform-specific
CSS rule in the `hub` bundle is written `.darwin …` or `.win32 …` — there are
**zero `.linux` rules**. So Linux matches no platform CSS and inherits the
**unprefixed base** geometry, which is mac-shaped. The base
`buttonsContainer` (the window-control "traffic light" slot) is `width: 52px;
margin: 8px 8px 8px 16px` → **52 + 16 = 68px** reserved on the left. The
`.win32` rule that collapses that to `margin: 0; width: auto` and flips the
controls to the right edge (`flex-direction: row-reverse`) **never fires**. So:

- the sidebar's expand/collapse toggle sits ~68px (3–4 icon widths) too far
  right, and
- the three control divs render with **no background artwork** (the SVGs are
  `.darwin`/`.win32`-only too) — invisible buttons, so it just looks like blank
  reserved space.

**The shipped fix** doesn't add `.linux` CSS at all — the rules ship compiled
with hashed class names (`.dqwmlJtoiCGaDKGr1ngo`), so injecting a `.linux`
selector is fragile. Instead we **remap the class**: patch the
`classList.add(window.electron.platform.os)` call so Linux adds `"win32"`
instead of `"linux"`, and Linux adopts the entire tested `.win32` stylesheet —
collapsed inset, controls on the right, the lot. That pairs with making the
window **frameless** like Windows (`linux-window-frame.sh`) so the custom title
bar's min/max/close controls render correctly instead of doubling up with native
decorations. See [`scripts/patches/linux-renderer-chrome.sh`](../../scripts/patches/linux-renderer-chrome.sh)
(anchor: the preserved property chain `classList.add(window.electron.platform.os)`).

The takeaway that generalises: **Linux matching no platform CSS class is the
real bug pattern here, not any one string test.** Anywhere the layout was carved
out for `.darwin` and `.win32` only, Linux silently inherits the macOS base — and
the cheapest robust fix is to make Linux *be* `.win32` rather than to author and
maintain a parallel `.linux` rule set.

## The gaps — now patched

Each gap below ships as its own surgical patch under `scripts/patches/`, wired
into `build-linux.sh` Step 3 and guarded by a marker that `verify-patches.sh`
greps out of the shipped asar (so a half-patched build fails CI). Every patch
derives its minified symbols from stable developer strings, keeps a `.orig`
backup, `node --check`s the result, and is idempotent (re-run = byte-identical).

| Gap | Patch | Marker |
|---|---|---|
| Menu offset + invisible window controls (remap `<html>` class linux→win32) | [`linux-renderer-chrome.sh`](../../scripts/patches/linux-renderer-chrome.sh) | `WISPR_LINUX_WIN32_CHROME` |
| Chrome window fell to default framed + visible menu bar → make it frameless like win32 (1.5.695: the meeting_recorder window; the Hub/scratchpad windows now self-frame Linux via a two-way else branch) | [`linux-window-frame.sh`](../../scripts/patches/linux-window-frame.sh) | `WISPR_LINUX_FRAMELESS` |
| Fresh installs seeded macOS `fn`/⌘ shortcut defaults + skipped the onboarding Permissions step → widen each renderer's `isWindows` **bind** to also be true on linux (bridge stays honest) | [`linux-renderer-treat-as-windows.sh`](../../scripts/patches/linux-renderer-treat-as-windows.sh) | `WISPR_LINUX_RENDERER_ISWIN` |
| Cold-start `wispr-flow:` deep links dropped (parse was win32-only) → widen the argv-parse guard | [`linux-deeplink.sh`](../../scripts/patches/linux-deeplink.sh) | `WISPR_LINUX_DEEPLINK` |
| Fresh Linux profiles were **seeded** with macOS chords, so push-to-talk landed on keycode `-1` (no Linux key) — blank PTT in Settings, no way past the onboarding shortcuts step (#33, #46) → widen the win32 flag *inside the main bundle's shortcuts module only* | [`linux-main-shortcut-defaults.sh`](../../scripts/patches/linux-main-shortcut-defaults.sh) | `WISPR_LINUX_MAIN_SHORTCUT_DEFAULTS` |

`linux-renderer-treat-as-windows.sh` is the high-leverage one: per renderer it
widens the *one* place `isWindows` is bound into a module-local
(`x = y?.platform?.isWindows ?? !1` → `x = ((y?.platform?.isWindows ?? !1) ||
"linux" === y?.platform?.os)`), so every `x ? winThing : macThing` gate
downstream falls the right way at once. The inner parens are mandatory — JS
forbids mixing `??` with `||` ungrouped. `isMacOS` is deliberately left `false`,
so the keycode/glyph paths (which key off `isMac`) are untouched — Linux stays on
the Ctrl / Windows-VK side, which is what the IPC contract wants.

It deliberately does **not** flip the preload boolean. An earlier version
(`WISPR_LINUX_AS_WINDOWS`) did, making `window.electron.platform.isWindows`
return `true` on Linux — which *lies* on the documented bridge API and would
silently fire any **future** `isWindows`-gated renderer site (correct "Windows"
branding, a Store link, a "Windows key" label). Widening the renderer-internal
local instead keeps the bridge honest while still fixing every *current*
consumer. An audit of the shipped renderer bundles
(`hub/status/scratchpad/meeting_recorder/contextMenu`) confirmed **none** of the
~22 `isWindows` consumer sites is a Windows-only API call, store link,
registry/UAC path, or "Windows" product branding — they are all UI gates
(shortcut/PTT defaults, glyph labels, the onboarding Permissions step gated
`isMac || (isWindows && !windowsHasMicPermission)`, the `windows_mic_permissions`
help asset, plus a recording-start delay and a `voiceProfile` prop) where Linux
correctly wants the Windows branch. The OS-API danger class lives in the **main**
bundle and gates on `process.platform`/`H8`, which this renderer-only patch never
touches.

### The main bundle needed its own, narrower cut

Being renderer-only is also this patch's blind spot. The default shortcut map
lives in a module *shared* by both bundles, and the profile is written by the
**main** process — where the same flag is `"win32"===process.platform`, i.e.
false on Linux. So the renderer showed Windows chords while main persisted the
macOS ones, and a fresh `config.json` came out as
`"shortcuts":{"-1":"ptt","-1+32":"popo",...},"modifierShortcut":"9"`. Since `-1`
is the "no keycode on this platform" sentinel, push-to-talk was literally
unpressable: the key monitor delivered events that matched nothing, Settings
rendered the binding blank, and onboarding could not be completed. That is the
one bug behind both #33 and #46.

The fix could **not** be "widen `H8` at its definition" — in the main bundle it
has ~79 consumers and does gate the real Windows-only OS-API class (registry,
`%LOCALAPPDATA%` path resolution, Windows exit-code semantics). So
[`linux-main-shortcut-defaults.sh`](../../scripts/patches/linux-main-shortcut-defaults.sh)
widens the flag only where it is *read inside the shortcuts module*. An audit of
1.6.774 found the module reads it at **8** sites and every one selects a Windows
chord against a macOS chord (default map, default modifier, four polish-prompt /
meeting-recorder chord sets, two PTT-display accessors) — so all 8 are widened
together, and the patch **fails closed** if any read there is ever not a ternary,
rather than silently widening an OS gate. Fixing only the PTT default would have
left its siblings seeding `-1` (e.g. `"-1+77"` for `open_meeting_recorder`).

**Still gated out, deliberately deferred (known limits, not patched):**

- **Meeting features behind `tD`** — speaker attribution, meeting auto-detect,
  system-audio loopback — lean on macOS app-introspection / ScreenCaptureKit. A
  real fix is large (PipeWire loopback, wiring the helper's active-app detection
  in); the loopback path already skips gracefully on Linux.
- **Telemetry cosmetics** — Linux reports `UNSPECIFIED` / `desktop_mac` (the
  client-info proto has no `LINUX` enum) and the tray uses `TrayIconWindows.png`.
  Harmless; patch only if upstream dashboards or branding start to care.

**Already patched elsewhere, don't re-flag:** the helper-path resolver
([`helper-resolver.sh`](../../scripts/patches/helper-resolver.sh) — without it
Linux took the Windows `.exe` branch and `existsSync` failed), the helper spawn
env ([`helper-env.sh`](../../scripts/patches/helper-env.sh)), and the
Applications-folder guard ([`mac-gates.sh`](../../scripts/patches/mac-gates.sh) —
without it the darwin "move me to /Applications" check would prompt-and-quit on
Linux).

**Correct by design, don't "fix":** keycode tables, Cmd-vs-Ctrl accelerators,
⌘/⌥ glyph labels, `shouldMuteAudio` defaulting false, Squirrel update hooks
(Linux uses deb/rpm/AppImage), `setLoginItemSettings` auto-launch (Electron
writes an XDG autostart `.desktop` on Linux), single-instance lock and protocol
registration (platform-neutral). The macOS `~/Library/...` path strings that
leak into the Linux ternary are never read at runtime — `WISPR_APP_SUPPORT_DIR`
/ `WISPR_LOG_DIR` override them from `app.getPath()`.

## How to re-run this audit on a new Wispr version

```bash
# 1. beautify the bundles you care about (tools/ is gitignored)
mkdir -p tools/beautified
for b in hub status scratchpad meeting_recorder contextMenu; do
	prettier --parser babel --ignore-path /dev/null \
		"extract/app/.webpack/renderer/$b/index.js" \
		> "tools/beautified/$b.index.js"
done
prettier --parser babel --ignore-path /dev/null \
	extract/app/.webpack/main/index.js > tools/beautified/main.index.js

# 2. renderers: trace the isMacOS / isWindows booleans, NOT string literals
grep -n 'isMacOS\|isWindows' tools/beautified/hub.index.js | head

# 3. main + preload: grep the literals and the tD / H8 flags
grep -nc '"darwin"\|"win32"\|"linux"' tools/beautified/main.index.js

# 4. the CSS bug: confirm Linux still matches no platform rules
grep -c '\.linux\b' tools/beautified/hub.index.js   # expect 0
```

If step 4 ever prints non-zero, upstream added Linux CSS and the headline bug may
be gone — verify before assuming.
