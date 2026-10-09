#!/usr/bin/env bats
#
# linux-patches.bats
# Unit tests for the renderer/main bundle patches added for the Linux port:
#   * linux-renderer-chrome.sh           -> remaps the <html> platform class linux->win32
#   * linux-window-frame.sh              -> frameless hub/settings window on Linux
#   * linux-hub-focusable.sh             -> hub window focusable/WM-managed on Linux
#   * linux-renderer-treat-as-windows.sh -> widens each renderer's isWindows bind
#                                           (bridge stays honest; no preload touched)
#   * linux-deeplink.sh                  -> cold-start wispr-flow: argv parse on Linux
#   * linux-early-singleton.sh           -> take the single-instance lock before init
#   * helper-env.sh                      -> spreads process.env into the helper env
#   * linux-disable-pill-drag.sh         -> force the drag-overlay flag false on Linux
#   * linux-main-shortcut-defaults.sh   -> Linux seeds the Windows chord map in main
#   * linux-xdg-data-dir.sh             -> app data and logs dirs under XDG_CONFIG_HOME
#   * linux-autostart.sh                -> login items backed by an XDG autostart entry
#   * linux-status-window-visibility.sh -> re-asserts always-on-top on the
#                                           Status window's monitorMove interval,
#                                           ahead of its systemState early-out
#   * helper-resolver.sh                 -> prepends a Linux case to the helper-path
#                                           ternary (inline and exported shapes)
#
# The real bundle is the proprietary, gitignored app -- not available in CI -- so
# each test drives a hermetic minified-JS FIXTURE carrying the exact anchor the
# patch keys on. Every patch is asserted to: apply (marker + transformation),
# leave unrelated sites alone, produce parseable JS (node --check, skipped if
# node is absent), be idempotent (second run is a no-op, byte-identical), and
# bail non-zero on a fixture whose anchor is absent (never silently no-op).
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
PATCH_DIR="$SCRIPT_DIR/../scripts/patches"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	FIX="$TEST_TMP/bundle.js"
	export FIX
}

teardown() {
	if [[ -n "${TEST_TMP:-}" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# node --check the fixture, but only if node is installed (it is in the build
# env; a bare bats runner may lack it).
node_check() {
	if command -v node >/dev/null; then
		node --check "$1"
	fi
}

# Assert a second run is a no-op and the file is byte-identical to the first run.
assert_idempotent() {
	local script="$1" target="$2" before after
	before=$(md5sum "$target" | cut -d' ' -f1)
	run bash "$script" "$target"
	[[ "$status" -eq 0 ]]
	[[ "$output" == *lready\ patched* ]]
	after=$(md5sum "$target" | cut -d' ' -f1)
	[[ "$before" == "$after" ]]
}

# =============================================================================
# linux-renderer-chrome.sh
# =============================================================================

@test "chrome: remaps every classList.add(...platform.os) site, leaves others" {
	cat > "$FIX" <<'JS'
document.documentElement.classList.add(window.electron.platform.os);
function f(el){el.classList.add(window.electron.platform.os)}
requestAnimationFrame(()=>x.classList.add(Yw.animated));
JS
	run bash "$PATCH_DIR/linux-renderer-chrome.sh" "$FIX"
	[[ "$status" -eq 0 ]]
	grep -q 'WISPR_LINUX_WIN32_CHROME' "$FIX"
	# both platform.os sites became a linux->win32 ternary
	[[ "$(grep -c '"linux"===window.electron.platform.os?"win32"' "$FIX")" -eq 2 ]]
	# the unrelated animated site is untouched
	grep -qF 'classList.add(Yw.animated)' "$FIX"
	node_check "$FIX"
}

@test "chrome: idempotent on second run" {
	cat > "$FIX" <<'JS'
document.documentElement.classList.add(window.electron.platform.os);
JS
	bash "$PATCH_DIR/linux-renderer-chrome.sh" "$FIX"
	assert_idempotent "$PATCH_DIR/linux-renderer-chrome.sh" "$FIX"
}

@test "chrome: bails non-zero when the anchor is absent" {
	cat > "$FIX" <<'JS'
requestAnimationFrame(()=>x.classList.add(Yw.animated));
JS
	run bash "$PATCH_DIR/linux-renderer-chrome.sh" "$FIX"
	[[ "$status" -ne 0 ]]
	! grep -q 'WISPR_LINUX_WIN32_CHROME' "$FIX"
}

# =============================================================================
# linux-window-frame.sh
# =============================================================================

@test "window-frame: widens the win32 hidden-titlebar predicate to include linux" {
	# The 1.5.695 mac branch dropped "hiddenInset" -- it now sets
	# {frame:!1,titleBarStyle:"hidden",trafficLightPosition,...}. The anchor no
	# longer keys on the mac branch, only on the win32 predicate + hidden assign.
	cat > "$FIX" <<'JS'
var s={tD:false},t={};
s.tD?Object.assign(t,{frame:!1,titleBarStyle:"hidden",trafficLightPosition:{x:1e4,y:10},transparent:!0,hasShadow:!0}):"win32"===process.platform&&Object.assign(t,{titleBarStyle:"hidden",autoHideMenuBar:!0});
JS
	run bash "$PATCH_DIR/linux-window-frame.sh" "$FIX"
	[[ "$status" -eq 0 ]]
	grep -q 'WISPR_LINUX_FRAMELESS' "$FIX"
	grep -qF '"win32"===process.platform||"linux"===process.platform' "$FIX"
	# the mac branch is left untouched
	grep -qF 'trafficLightPosition:{x:1e4,y:10}' "$FIX"
	node_check "$FIX"
}

@test "window-frame: idempotent on second run" {
	cat > "$FIX" <<'JS'
var s={tD:false},t={};
s.tD?Object.assign(t,{frame:!1,titleBarStyle:"hidden",trafficLightPosition:{x:1e4,y:10},transparent:!0,hasShadow:!0}):"win32"===process.platform&&Object.assign(t,{titleBarStyle:"hidden",autoHideMenuBar:!0});
JS
	bash "$PATCH_DIR/linux-window-frame.sh" "$FIX"
	assert_idempotent "$PATCH_DIR/linux-window-frame.sh" "$FIX"
}

@test "window-frame: bails non-zero when no matching window config exists" {
	cat > "$FIX" <<'JS'
var t={};Object.assign(t,{titleBarStyle:"default"});
JS
	run bash "$PATCH_DIR/linux-window-frame.sh" "$FIX"
	[[ "$status" -ne 0 ]]
	! grep -q 'WISPR_LINUX_FRAMELESS' "$FIX"
}

@test "window-frame: matches the 1.6.897 site with frame:!1 between the keys" {
	# Shipped 1.6.897 bytes: upstream inserted `frame:!1` between
	# titleBarStyle and autoHideMenuBar at the meeting_recorder site (the
	# exact-text anchor went to zero). The meeting_ax_inspector site alongside
	# carries the same object in a two-way switch with NO win32 predicate; its
	# else branch already covers Linux, so it must be left alone and the count
	# must stay at exactly one.
	cat > "$FIX" <<'JS'
var c={tD:false},o={tD:false},t={},u={};
c.tD?Object.assign(t,{frame:!1,titleBarStyle:"hidden",trafficLightPosition:{x:1e4,y:10},transparent:!0,hasShadow:!0}):"win32"===process.platform&&Object.assign(t,{titleBarStyle:"hidden",frame:!1,autoHideMenuBar:!0});
o.tD?Object.assign(u,{titleBarStyle:"hidden",trafficLightPosition:{x:12,y:16}}):Object.assign(u,{titleBarStyle:"hidden",autoHideMenuBar:!0});
JS
	run bash "$PATCH_DIR/linux-window-frame.sh" "$FIX"
	[[ "$status" -eq 0 ]]
	grep -qF '/*WISPR_LINUX_FRAMELESS*/"win32"===process.platform||"linux"===process.platform)&&Object.assign(t,{titleBarStyle:"hidden",frame:!1,autoHideMenuBar:!0})' "$FIX"
	# the ax-inspector two-way switch is untouched
	grep -qF '):Object.assign(u,{titleBarStyle:"hidden",autoHideMenuBar:!0});' "$FIX"
	[[ $(grep -o 'WISPR_LINUX_FRAMELESS' "$FIX" | wc -l) -eq 1 ]]
	node_check "$FIX"
}

@test "window-frame: fence stops the loosened anchor at a brace boundary" {
	# Near-miss for the `[^{}]` fence: the two keys sit in ADJACENT object
	# literals of the same win32 branch. An unfenced `.*?` between the keys
	# would match across `})&&Object.assign(t,{`; the fence must not.
	cat > "$FIX" <<'JS'
var t={};
"win32"===process.platform&&Object.assign(t,{titleBarStyle:"hidden"})&&Object.assign(t,{autoHideMenuBar:!0});
JS
	run bash "$PATCH_DIR/linux-window-frame.sh" "$FIX"
	[[ "$status" -ne 0 ]]
	! grep -q 'WISPR_LINUX_FRAMELESS' "$FIX"
}

@test "window-frame: ignores a win32 assign that does not hide the menu bar" {
	# One character from the anchor: autoHideMenuBar:!1 instead of !0.
	cat > "$FIX" <<'JS'
var t={};
"win32"===process.platform&&Object.assign(t,{titleBarStyle:"hidden",frame:!1,autoHideMenuBar:!1});
JS
	run bash "$PATCH_DIR/linux-window-frame.sh" "$FIX"
	[[ "$status" -ne 0 ]]
	! grep -q 'WISPR_LINUX_FRAMELESS' "$FIX"
}

# =============================================================================
# linux-hub-focusable.sh
# =============================================================================

@test "hub-focusable: rewrites the Hub focusable:!1, leaves overlays alone" {
	cat > "$FIX" <<'JS'
const t={title:"Flow Hub",center:!0,show:!1,webPreferences:{preload:require("path").resolve(__dirname,"../renderer","hub","preload.js"),devTools:"development"===_.M0||(0,N.Pv)(d.RA.prefs?.user.email||"")},focusable:!1};_.tD?Object.assign(t,{frame:!1,titleBarStyle:"hidden"}):Object.assign(t,{frame:!1,autoHideMenuBar:!0});
const ov=new r.BrowserWindow({show:!1,transparent:!0,frame:!1,hasShadow:!1,focusable:!1,skipTaskbar:!0});
JS
	run bash "$PATCH_DIR/linux-hub-focusable.sh" "$FIX"
	[[ "$status" -eq 0 ]]
	grep -q 'WISPR_LINUX_HUB_FOCUSABLE' "$FIX"
	# the Hub site now gates focusable on the platform
	grep -qF 'focusable:/*WISPR_LINUX_HUB_FOCUSABLE*/"linux"===process.platform}' "$FIX"
	# the overlay's intentional focusable:!1 is untouched (exactly one remains)
	[[ "$(grep -c 'focusable:!1' "$FIX")" -eq 1 ]]
	grep -qF 'hasShadow:!1,focusable:!1,skipTaskbar:!0' "$FIX"
	node_check "$FIX"
}

@test "hub-focusable: idempotent on second run" {
	cat > "$FIX" <<'JS'
const t={title:"Flow Hub",center:!0,show:!1,webPreferences:{preload:require("path").resolve(__dirname,"../renderer","hub","preload.js"),devTools:"development"===_.M0},focusable:!1};
JS
	bash "$PATCH_DIR/linux-hub-focusable.sh" "$FIX"
	assert_idempotent "$PATCH_DIR/linux-hub-focusable.sh" "$FIX"
}

@test "hub-focusable: bails non-zero when the Hub anchor is absent" {
	cat > "$FIX" <<'JS'
const ov=new r.BrowserWindow({show:!1,transparent:!0,frame:!1,hasShadow:!1,focusable:!1,skipTaskbar:!0});
JS
	run bash "$PATCH_DIR/linux-hub-focusable.sh" "$FIX"
	[[ "$status" -ne 0 ]]
	! grep -q 'WISPR_LINUX_HUB_FOCUSABLE' "$FIX"
}

# =============================================================================
# linux-renderer-treat-as-windows.sh
# =============================================================================

@test "treat-as-windows: widens the isWindows bind to include linux, honest bridge" {
	cat > "$FIX" <<'JS'
const y="undefined"!=typeof window?window.electron:void 0,$=y?.platform?.isMacOS??!1,x=y?.platform?.isWindows??!1,k="2025-03-01";
const na=x?Yi:Li,delay=x?500:100;
JS
	run bash "$PATCH_DIR/linux-renderer-treat-as-windows.sh" "$FIX"
	[[ "$status" -eq 0 ]]
	grep -q 'WISPR_LINUX_RENDERER_ISWIN' "$FIX"
	# the bind is widened, reusing the SAME window.electron local (y) for the OS check
	grep -qF 'x=((y?.platform?.isWindows??!1)||"linux"===y?.platform?.os)/*WISPR_LINUX_RENDERER_ISWIN*/' "$FIX"
	# isMacOS bind is untouched; the bridge property name itself is never flipped
	grep -qF '$=y?.platform?.isMacOS??!1' "$FIX"
	# downstream consumers (na, delay) are left exactly as-is -- they ride on x
	grep -qF 'na=x?Yi:Li' "$FIX"
	grep -qF 'delay=x?500:100' "$FIX"
	node_check "$FIX"
}

@test "treat-as-windows: idempotent on second run" {
	cat > "$FIX" <<'JS'
const y=window.electron,$=y?.platform?.isMacOS??!1,x=y?.platform?.isWindows??!1;
JS
	bash "$PATCH_DIR/linux-renderer-treat-as-windows.sh" "$FIX"
	assert_idempotent "$PATCH_DIR/linux-renderer-treat-as-windows.sh" "$FIX"
}

@test "treat-as-windows: bails non-zero when the renderer has no isWindows bind" {
	cat > "$FIX" <<'JS'
const y=window.electron,$=y?.platform?.isMacOS??!1;
JS
	run bash "$PATCH_DIR/linux-renderer-treat-as-windows.sh" "$FIX"
	[[ "$status" -ne 0 ]]
	! grep -q 'WISPR_LINUX_RENDERER_ISWIN' "$FIX"
}

# =============================================================================
# linux-deeplink.sh
# =============================================================================

@test "deeplink: widens the cold-start win32 argv guard to include linux" {
	cat > "$FIX" <<'JS'
function L(x){}function B(x){return x}
if(f.H8){const e=B(process.argv.find(e=>e.startsWith("wispr-flow:")||e.startsWith("wispr-flow/")));e&&L(e)}
JS
	run bash "$PATCH_DIR/linux-deeplink.sh" "$FIX"
	[[ "$status" -eq 0 ]]
	grep -q 'WISPR_LINUX_DEEPLINK' "$FIX"
	grep -qF 'if(f.H8||"linux"===process.platform){' "$FIX"
	node_check "$FIX"
}

@test "deeplink: idempotent on second run" {
	cat > "$FIX" <<'JS'
function L(x){}function B(x){return x}
if(f.H8){const e=B(process.argv.find(e=>e.startsWith("wispr-flow:")||e.startsWith("wispr-flow/")));e&&L(e)}
JS
	bash "$PATCH_DIR/linux-deeplink.sh" "$FIX"
	assert_idempotent "$PATCH_DIR/linux-deeplink.sh" "$FIX"
}

@test "deeplink: leaves the cross-platform second-instance handler untouched" {
	# second-instance scans r.find(...), NOT process.argv.find(...) -- the anchor
	# must not match it, so the patch must bail (0 cold-start guards present).
	cat > "$FIX" <<'JS'
function L(x){}function B(x){return x}
app.on("second-instance",(e,r)=>{if(f.H8){const u=B(r.find(e=>e.startsWith("wispr-flow:")));u&&L(u)}});
JS
	run bash "$PATCH_DIR/linux-deeplink.sh" "$FIX"
	[[ "$status" -ne 0 ]]
	! grep -q 'WISPR_LINUX_DEEPLINK' "$FIX"
}

# =============================================================================
# linux-early-singleton.sh
# =============================================================================

@test "early-singleton: guard lands after the license banner, before the IIFE" {
	cat > "$FIX" <<'JS'
/*! For license information please see index.js.LICENSE.txt */
!function(){console.log("app init")}()
JS
	run bash "$PATCH_DIR/linux-early-singleton.sh" "$FIX"
	[[ "$status" -eq 0 ]]
	# License banner stays line 1.
	[[ "$(head -1 "$FIX")" == '/*! For license information please see index.js.LICENSE.txt */' ]]
	# Guard is line 2 and keys on the real Electron API, not a minified name.
	grep -qF 'WISPR_LINUX_EARLY_SINGLETON_V1' "$FIX"
	grep -qF 'require("electron").app' "$FIX"
	grep -qF 'requestSingleInstanceLock' "$FIX"
	grep -qF 'process.exit(0)' "$FIX"
	# Nothing but the banner precedes the guard.
	[[ "$(grep -nF 'WISPR_LINUX_EARLY_SINGLETON_V1' "$FIX" | cut -d: -f1)" -eq 2 ]]
	node_check "$FIX"
}

@test "early-singleton: guard at byte 0 when there is no banner" {
	printf '!function(){console.log("app init")}()' > "$FIX"
	run bash "$PATCH_DIR/linux-early-singleton.sh" "$FIX"
	[[ "$status" -eq 0 ]]
	[[ "$(grep -nF 'WISPR_LINUX_EARLY_SINGLETON_V1' "$FIX" | cut -d: -f1)" -eq 1 ]]
	node_check "$FIX"
}

@test "early-singleton: idempotent on second run" {
	printf '!function(){console.log("app init")}()' > "$FIX"
	bash "$PATCH_DIR/linux-early-singleton.sh" "$FIX"
	assert_idempotent "$PATCH_DIR/linux-early-singleton.sh" "$FIX"
}

@test "early-singleton: keeps a backup of the pre-patch bundle" {
	printf '!function(){console.log("app init")}()' > "$FIX"
	run bash "$PATCH_DIR/linux-early-singleton.sh" "$FIX"
	[[ "$status" -eq 0 ]]
	[[ -f "$FIX.earlysingleton.orig" ]]
	cmp -s "$FIX.earlysingleton.orig" <(printf '!function(){console.log("app init")}()')
}

# =============================================================================
# helper-env.sh
# =============================================================================

@test "helper-env: spreads process.env into the inline spawn env (<=1.6.7)" {
	cat > "$FIX" <<'JS'
var s="h",o={spawn:function(){}},f={kL:"",M0:""};
o.spawn(s,{stdio:["pipe","pipe","pipe","pipe"],env:{sentryDSN:f.kL,environment:f.M0}});
JS
	run bash "$PATCH_DIR/helper-env.sh" "$FIX"
	[[ "$status" -eq 0 ]]
	grep -qF 'env:{/*WISPR_LINUX_HELPER_ENV*/...process.env,sentryDSN:f.kL,environment:f.M0}' "$FIX"
	node_check "$FIX"
}

@test "helper-env: spreads process.env into the hoisted env factory (>=1.6.774)" {
	# Shipped 1.6.897 shape: the object lives in a factory the spawn calls.
	cat > "$FIX" <<'JS'
var a={app:{isPackaged:!0}},f={kL:"",M0:"",iP:!1},o={spawn:function(){}},s="h";
const N=(e=a.app.isPackaged)=>({sentryDSN:f.kL,environment:f.M0,sentryLocalDebug:f.iP?"true":"",developmentFileLogging:e?"false":"true"});
o.spawn(s,{stdio:["pipe","pipe","pipe","pipe"],env:N()});
JS
	run bash "$PATCH_DIR/helper-env.sh" "$FIX"
	[[ "$status" -eq 0 ]]
	grep -qF '=>({/*WISPR_LINUX_HELPER_ENV*/...process.env,sentryDSN:f.kL,' "$FIX"
	# the spawn site itself is untouched
	grep -qF 'stdio:["pipe","pipe","pipe","pipe"],env:N()' "$FIX"
	node_check "$FIX"
}

@test "helper-env: idempotent on second run" {
	cat > "$FIX" <<'JS'
var a={app:{isPackaged:!0}},f={kL:""},o={spawn:function(){}},s="h";
const N=(e=a.app.isPackaged)=>({sentryDSN:f.kL});
o.spawn(s,{stdio:["pipe","pipe","pipe","pipe"],env:N()});
JS
	bash "$PATCH_DIR/helper-env.sh" "$FIX"
	assert_idempotent "$PATCH_DIR/helper-env.sh" "$FIX"
}

@test "helper-env: rewrites an upstream spread to the marked shape, once" {
	# If upstream ever spreads process.env itself the fix is a no-op in effect,
	# but the marker must still land so verify-patches.sh keeps its fingerprint.
	cat > "$FIX" <<'JS'
var f={kL:""},o={spawn:function(){}},s="h";
o.spawn(s,{stdio:["pipe","pipe","pipe","pipe"],env:{...process.env,sentryDSN:f.kL}});
JS
	run bash "$PATCH_DIR/helper-env.sh" "$FIX"
	[[ "$status" -eq 0 ]]
	grep -qF 'env:{/*WISPR_LINUX_HELPER_ENV*/...process.env,sentryDSN:f.kL}' "$FIX"
	[[ $(grep -o 'process.env' "$FIX" | wc -l) -eq 1 ]]
	node_check "$FIX"
}

@test "helper-env: bails when the env object has no 4-pipe spawn beside it" {
	# Near-miss: `{sentryDSN:` present, but the fd-3 helper spawn is not. The
	# object is then not the helper env and must not be touched.
	cat > "$FIX" <<'JS'
var f={kL:""},o={spawn:function(){}},s="h";
const T={sentryDSN:f.kL};
o.spawn(s,{stdio:["pipe","pipe","pipe"],env:T});
JS
	run bash "$PATCH_DIR/helper-env.sh" "$FIX"
	[[ "$status" -ne 0 ]]
	! grep -q 'WISPR_LINUX_HELPER_ENV' "$FIX"
}

@test "helper-env: bails when the env object anchor is not unique" {
	cat > "$FIX" <<'JS'
var f={kL:""},o={spawn:function(){}},s="h";
const A={sentryDSN:f.kL},B={sentryDSN:f.kL};
o.spawn(s,{stdio:["pipe","pipe","pipe","pipe"],env:A});
JS
	run bash "$PATCH_DIR/helper-env.sh" "$FIX"
	[[ "$status" -ne 0 ]]
	! grep -q 'WISPR_LINUX_HELPER_ENV' "$FIX"
}

# =============================================================================
# linux-disable-pill-drag.sh
# =============================================================================

@test "pill-drag: forces the handler's flag false on Linux, leaves the blackout site alone" {
	# Shipped 1.6.897 bytes: the drag-overlay handler opens with `let t,n;if(`
	# and the sibling blackout-overlay handler beside it has the same log
	# shape with a different developer string and no `let` prelude.
	cat > "$FIX" <<'JS'
var i={globalShortcut:{isRegistered:()=>!1,register:()=>!0,unregister:()=>{}}},o=()=>({info(){},warn(){}}),Y,Z,ke=()=>{};
const Ie=(e,t)=>{o().info(`[Blackout Overlay]: Setting blackout overlay state to ${e} (source: ${t})`),Y=e,ke()},Le=e=>{let t,n;if(o().info(`[Drag Overlay]: Setting drag overlay state to ${e}`),Z=e,e?i.globalShortcut.isRegistered("Escape")||i.globalShortcut.register("Escape",()=>Le(!1)):i.globalShortcut.isRegistered("Escape")&&i.globalShortcut.unregister("Escape"),ke(),e){t=1,n=2}};
JS
	run bash "$PATCH_DIR/linux-disable-pill-drag.sh" "$FIX"
	[[ "$status" -eq 0 ]]
	grep -qF 'Le=e=>{let t,n;if(/*WISPR_LINUX_DISABLE_PILL_DRAG*/"linux"===process.platform){e=!1}if(o().info(`[Drag Overlay]: Setting drag overlay state to ${e}`),Z=e,' "$FIX"
	# exactly one insertion; the blackout handler is untouched
	[[ "$(grep -o 'WISPR_LINUX_DISABLE_PILL_DRAG' "$FIX" | wc -l)" -eq 1 ]]
	grep -qF 'const Ie=(e,t)=>{o().info(`[Blackout Overlay]' "$FIX"
	node_check "$FIX"
}

@test "pill-drag: matches a handler with no declaration prelude (if( right after the brace)" {
	# The prelude is the minifier's hoisted `let`, not part of the shape;
	# a bundle that drops it must still patch, with the gate in the same place.
	cat > "$FIX" <<'JS'
var o=()=>({info(){}}),Z;
const Le=e=>{if(o().info(`[Drag Overlay]: Setting drag overlay state to ${e}`),Z=e,e){}};
JS
	run bash "$PATCH_DIR/linux-disable-pill-drag.sh" "$FIX"
	[[ "$status" -eq 0 ]]
	grep -qF 'Le=e=>{if(/*WISPR_LINUX_DISABLE_PILL_DRAG*/"linux"===process.platform){e=!1}if(o().info(`[Drag Overlay]' "$FIX"
	node_check "$FIX"
}

@test "pill-drag: reproduces a reshaped prelude verbatim (split declarations)" {
	cat > "$FIX" <<'JS'
var o=()=>({info(){}}),Z;
const Le=e=>{let t;var n;if(o().info(`[Drag Overlay]: Setting drag overlay state to ${e}`),Z=e,e){t=1,n=2}};
JS
	run bash "$PATCH_DIR/linux-disable-pill-drag.sh" "$FIX"
	[[ "$status" -eq 0 ]]
	grep -qF 'Le=e=>{let t;var n;if(/*WISPR_LINUX_DISABLE_PILL_DRAG*/"linux"===process.platform){e=!1}if(o().info(`[Drag Overlay]' "$FIX"
	node_check "$FIX"
}

@test "pill-drag: the prelude fence stops at a nested block (near miss)" {
	# A brace inside the prelude is a structural boundary the bounded run must
	# not cross, so the anchor finds nothing and the patch fails closed for a
	# re-audit rather than injecting past an unknown statement.
	cat > "$FIX" <<'JS'
var o=()=>({info(){}}),Z;
const Le=e=>{let t={};if(o().info(`[Drag Overlay]: Setting drag overlay state to ${e}`),Z=e,e){t=1}};
JS
	run bash "$PATCH_DIR/linux-disable-pill-drag.sh" "$FIX"
	[[ "$status" -ne 0 ]]
	[[ "$output" == *'found 0'* ]]
	run grep -q 'WISPR_LINUX_DISABLE_PILL_DRAG' "$FIX"
	[[ "$status" -ne 0 ]]
}

@test "pill-drag: the prelude budget is 80 characters (near miss at 81)" {
	local pad80 pad81
	pad80="let $(printf 'a%.0s' {1..75});"
	pad81="let $(printf 'a%.0s' {1..76});"
	[[ ${#pad80} -eq 80 && ${#pad81} -eq 81 ]]
	printf 'var o=()=>({info(){}}),Z;\nconst Le=e=>{%sif(o().info(`[Drag Overlay]: Setting drag overlay state to ${e}`),Z=e,e){}};\n' "$pad80" > "$FIX"
	run bash "$PATCH_DIR/linux-disable-pill-drag.sh" "$FIX"
	[[ "$status" -eq 0 ]]
	printf 'var o=()=>({info(){}}),Z;\nconst Le=e=>{%sif(o().info(`[Drag Overlay]: Setting drag overlay state to ${e}`),Z=e,e){}};\n' "$pad81" > "$FIX"
	run bash "$PATCH_DIR/linux-disable-pill-drag.sh" "$FIX"
	[[ "$status" -ne 0 ]]
	[[ "$output" == *'found 0'* ]]
}

@test "pill-drag: idempotent on second run" {
	cat > "$FIX" <<'JS'
var o=()=>({info(){}}),Z;
const Le=e=>{let t,n;if(o().info(`[Drag Overlay]: Setting drag overlay state to ${e}`),Z=e,e){t=1,n=2}};
JS
	bash "$PATCH_DIR/linux-disable-pill-drag.sh" "$FIX"
	assert_idempotent "$PATCH_DIR/linux-disable-pill-drag.sh" "$FIX"
}

@test "pill-drag: bails non-zero when the log string is present but the handler shape is not" {
	# The 1.5.789 shape: same developer string, but the handler is a comma
	# expression with no `if(` at all. A decoy with the literal but not the
	# call shape must not be patched.
	cat > "$FIX" <<'JS'
var o=()=>({info(){}}),R;
const U=e=>{o().info(`[Drag Overlay]: Setting drag overlay state to ${e}`),R=e};
JS
	run bash "$PATCH_DIR/linux-disable-pill-drag.sh" "$FIX"
	[[ "$status" -ne 0 ]]
	! grep -q 'WISPR_LINUX_DISABLE_PILL_DRAG' "$FIX"
}

# =============================================================================
# linux-main-shortcut-defaults.sh
# =============================================================================

# The shipped 1.6.897 shape, trimmed: webpack module 28889 defines the Windows
# chord map (`re`, ctrl+win+space Popo) and the macOS one (`Te`, fn+space  # codespell:ignore te
# Popo), selects between them with `r.H8?re:Te`, and reads `r.H8` at two more  # codespell:ignore te
# ternary sites (the display accessor and the modifier default). `lr.H8` in the same module is a DIFFERENT module-local (the
# left-boundary decoy from the patch's own audit) and module 95001 reads
# `r.H8` non-ternarily, which is outside the shortcuts module and must be
# left alone.
write_shortcut_fixture() {
	cat > "$FIX" <<'JS'
var lr={H8:!0};
({0:1,28889(e,t,n){"use strict";var r={H8:!1},y={Ptt:1,Popo:2,Lens:3,PasteLastText:4,CopyLastText:5,Dismiss:6},s={ctrl:1,win:2,space:3,alt:4,shift:5,z:6,x:7,esc:8,fn:9,cmd:10,c:11,v:12},O=e=>e.join("+");const te=O([s.ctrl,s.win]),re={[te]:y.Ptt,[O([s.ctrl,s.win,s.space])]:y.Popo,[O([s.ctrl,s.win,s.alt])]:y.Lens,[O([s.shift,s.alt,s.z])]:y.PasteLastText,[O([s.shift,s.alt,s.x])]:y.CopyLastText,[O([s.esc])]:y.Dismiss},Ce=O([s.fn]),Te={[Ce]:y.Ptt,[O([s.fn,s.space])]:y.Popo,[O([s.fn,s.ctrl])]:y.Lens,[O([s.cmd,s.ctrl,s.v])]:y.PasteLastText,[O([s.cmd,s.ctrl,s.c])]:y.CopyLastText,[O([s.esc])]:y.Dismiss},ae=O([s.alt]),Ne=O([s.cmd]),H=e=>{const t=r.H8?te:Ce;return e||t},Pe=r.H8?re:Te,Qe=r.H8?ae:Ne,Re=lr.H8?1:2;t.x=[H,Pe,Qe,Re]},95001(e,t,n){"use strict";var r={H8:!1};if(r.H8)t.q=1}});// codespell:ignore te,Te
JS
}

@test "shortcut-defaults: widens every r.H8 ternary in the shortcuts module, leaves the rest" {
	write_shortcut_fixture
	run bash "$PATCH_DIR/linux-main-shortcut-defaults.sh" "$FIX"
	[[ "$status" -eq 0 ]]
	[[ "$output" == *'widened at 3 chord-selection site(s)'* ]]
	# the marker sits on the first widened read, and the other two are widened too
	grep -qF '(r.H8||"linux"===process.platform)/*WISPR_LINUX_MAIN_SHORTCUT_DEFAULTS*/?te:Ce' "$FIX" # codespell:ignore te
	grep -qF 'Pe=(r.H8||"linux"===process.platform)?re:Te' "$FIX" # codespell:ignore te
	grep -qF 'Qe=(r.H8||"linux"===process.platform)?ae:Ne' "$FIX"
	[[ "$(grep -o '(r.H8||"linux"===process.platform)' "$FIX" | wc -l)" -eq 3 ]]
	[[ "$(grep -o 'WISPR_LINUX_MAIN_SHORTCUT_DEFAULTS' "$FIX" | wc -l)" -eq 1 ]]
	# the lr.H8 decoy and the neighbouring module's r.H8 are untouched
	grep -qF 'Re=lr.H8?1:2' "$FIX"
	grep -qF '95001(e,t,n){"use strict";var r={H8:!1};if(r.H8)t.q=1}' "$FIX"
	node_check "$FIX"
}

@test "shortcut-defaults: idempotent on second run" {
	write_shortcut_fixture
	bash "$PATCH_DIR/linux-main-shortcut-defaults.sh" "$FIX"
	assert_idempotent "$PATCH_DIR/linux-main-shortcut-defaults.sh" "$FIX"
}

@test "shortcut-defaults: bails non-zero when the chord maps are absent" {
	cat > "$FIX" <<'JS'
({0:1,28889(e,t,n){"use strict";var r={H8:!1};t.x=r.H8?1:2}});
JS
	run bash "$PATCH_DIR/linux-main-shortcut-defaults.sh" "$FIX"
	[[ "$status" -ne 0 ]]
	! grep -q 'WISPR_LINUX_MAIN_SHORTCUT_DEFAULTS' "$FIX"
}

@test "shortcut-defaults: bails non-zero when a read in the module is not a ternary" {
	# Near miss: same maps and selector, plus one `if(r.H8)` inside the module.
	# That is the OS-API gate shape the patch must refuse to widen.
	write_shortcut_fixture
	sed -i 's/Re=lr\.H8?1:2;/Re=lr.H8?1:2;if(r.H8)t.w=1;/' "$FIX"
	grep -qF 'if(r.H8)t.w=1;t.x=' "$FIX"
	run bash "$PATCH_DIR/linux-main-shortcut-defaults.sh" "$FIX"
	[[ "$status" -ne 0 ]]
	[[ "$output" == *'NOT ternary selections'* ]]
	! grep -q 'WISPR_LINUX_MAIN_SHORTCUT_DEFAULTS' "$FIX"
}

# =============================================================================
# helper-resolver.sh
# =============================================================================
#
# Fixtures are the shipped ternary with the template paths shortened. The
# inline shape is 1.6.897's (the ternary is a `const s=` in the spawn
# function, followed by the existsSync guard); the exported shape is
# 1.6.937's (the same ternary is the body of `const l=()=>`). The anchor is
# the ternary head, so both must patch to the same Linux case.

# Evaluate the patched fixture under node with process.platform forced to $1
# and process.resourcesPath set, then print what the resolver returns. The
# fixtures derive their isMac flag from process.platform so the forced value
# reaches the upstream arms. Callers guard on node being present.
resolver_result() {
	local platform="$1" expr="$2"
	node -e "
		Object.defineProperty(process,'platform',{value:'$platform'});
		process.resourcesPath='/res';
		$(cat "$FIX")
		console.log($expr);"
}

@test "helper-resolver: prepends the Linux case to the inline ternary (<=1.6.897)" {
	cat > "$FIX" <<'JS'
var a={app:{isPackaged:!0}},f={tD:"darwin"===process.platform},E={ty:{isHelperProcessRunningManually:!1}},S={ZI:"/r"},l=function(){return{info:function(){},error:function(){}}},d=function(){return{existsSync:function(){return!0}}};
const s=f.tD?E.ty.isHelperProcessRunningManually?(l().info("Running Dev Mac Helper service"),`${S.ZI}/swift-helper-app/DerivedData/Wispr Flow`):(l().info("Running packaged Mac Helper service"),`${S.ZI}/swift-helper-app-dist/Wispr Flow`):E.ty.isHelperProcessRunningManually||!a.app.isPackaged?(l().info("Running Dev Windows Helper service"),`${S.ZI}\\windows-helper-app\\Wispr Flow Helper.exe`):(l().info("Running packaged Windows Helper service"),`${S.ZI}\\Release\\Wispr Flow Helper.exe`);if(!d().existsSync(s))l().error("Helper service script path not found",{customAttributes:{serviceScriptPath:s}});
JS
	run bash "$PATCH_DIR/helper-resolver.sh" "$FIX"
	[[ "$status" -eq 0 ]]
	grep -qF 'const s="linux"===process.platform/*WISPR_LINUX_HELPER_BRANCH*/?(l().info("Running packaged Linux Helper service"),require("path").join(process.resourcesPath,"Release","wispr-flow-linux-helper")):f.tD?E.ty.isHelperProcessRunningManually?(l().info("Running Dev Mac Helper service")' "$FIX"
	# the guard after the ternary is untouched
	grep -qF ';if(!d().existsSync(s))l().error("Helper service script path not found"' "$FIX"
	node_check "$FIX"
	# behaviour: linux takes the new arm, win32 still lands on the packaged
	# Windows path (the upstream arms are not rewritten)
	if command -v node >/dev/null; then
		[[ $(resolver_result linux s) == '/res/Release/wispr-flow-linux-helper' ]]
		[[ $(resolver_result win32 s) == '/r\Release\Wispr Flow Helper.exe' ]]
	fi
}

@test "helper-resolver: prepends the Linux case to the exported arrow resolver (>=1.6.937)" {
	cat > "$FIX" <<'JS'
var r={app:{isPackaged:!0}},o={tD:"darwin"===process.platform},a={ty:{isHelperProcessRunningManually:!1}},c={ZI:"/r"},s=function(){return{info:function(){}}};
const l=()=>o.tD?a.ty.isHelperProcessRunningManually?(s().info("Running Dev Mac Helper service"),`${c.ZI}/swift-helper-app/DerivedData/Wispr Flow`):(s().info("Running packaged Mac Helper service"),`${c.ZI}/swift-helper-app-dist/Wispr Flow`):a.ty.isHelperProcessRunningManually||!r.app.isPackaged?(s().info("Running Dev Windows Helper service"),`${c.ZI}\\windows-helper-app\\Wispr Flow Helper.exe`):(s().info("Running packaged Windows Helper service"),`${c.ZI}\\Release\\Wispr Flow Helper.exe`);
JS
	run bash "$PATCH_DIR/helper-resolver.sh" "$FIX"
	[[ "$status" -eq 0 ]]
	grep -qF 'const l=()=>"linux"===process.platform/*WISPR_LINUX_HELPER_BRANCH*/?(s().info("Running packaged Linux Helper service"),require("path").join(process.resourcesPath,"Release","wispr-flow-linux-helper")):o.tD?a.ty.isHelperProcessRunningManually?(s().info("Running Dev Mac Helper service")' "$FIX"
	node_check "$FIX"
	if command -v node >/dev/null; then
		[[ $(resolver_result linux 'l()') == '/res/Release/wispr-flow-linux-helper' ]]
		[[ $(resolver_result darwin 'l()') == '/r/swift-helper-app-dist/Wispr Flow' ]]
	fi
}

@test "helper-resolver: matches the log lines under any string delimiter" {
	# A bundler swap can re-emit every "literal" as a `literal` (the sibling
	# project lost four anchors that way). Both developer strings the anchor
	# keys on are backticked here; the patch must still find the one site.
	cat > "$FIX" <<'JS'
var r={app:{isPackaged:!0}},o={tD:!1},a={ty:{isHelperProcessRunningManually:!1}},s=function(){return{info:function(){}}};
const l=()=>o.tD?a.ty.isHelperProcessRunningManually?(s().info(`Running Dev Mac Helper service`),`m1`):(s().info(`Running packaged Mac Helper service`),`m2`):a.ty.isHelperProcessRunningManually||!r.app.isPackaged?(s().info(`Running Dev Windows Helper service`),`w1`):(s().info(`Running packaged Windows Helper service`),`w2`);
JS
	run bash "$PATCH_DIR/helper-resolver.sh" "$FIX"
	[[ "$status" -eq 0 ]]
	grep -qF 'const l=()=>"linux"===process.platform/*WISPR_LINUX_HELPER_BRANCH*/?(s().info("Running packaged Linux Helper service"),require("path").join(process.resourcesPath,"Release","wispr-flow-linux-helper")):o.tD?a.ty.isHelperProcessRunningManually?(s().info(`Running Dev Mac Helper service`)' "$FIX"
	node_check "$FIX"
}

@test "helper-resolver: idempotent on second run" {
	cat > "$FIX" <<'JS'
var r={app:{isPackaged:!0}},o={tD:!1},a={ty:{isHelperProcessRunningManually:!1}},s=function(){return{info:function(){}}};
const l=()=>o.tD?a.ty.isHelperProcessRunningManually?(s().info("Running Dev Mac Helper service"),"m1"):(s().info("Running packaged Mac Helper service"),"m2"):a.ty.isHelperProcessRunningManually||!r.app.isPackaged?(s().info("Running Dev Windows Helper service"),"w1"):(s().info("Running packaged Windows Helper service"),"w2");
JS
	bash "$PATCH_DIR/helper-resolver.sh" "$FIX"
	assert_idempotent "$PATCH_DIR/helper-resolver.sh" "$FIX"
}

@test "helper-resolver: a bare Dev-Mac log line elsewhere is not a second site" {
	# Near-miss decoy: the developer string without the ternary head around
	# it. The count must stay one and the decoy must be left alone.
	cat > "$FIX" <<'JS'
var r={app:{isPackaged:!0}},o={tD:!1},a={ty:{isHelperProcessRunningManually:!1}},s=function(){return{info:function(){}}};
function decoy(){s().info("Running Dev Mac Helper service");return"x"}
const l=()=>o.tD?a.ty.isHelperProcessRunningManually?(s().info("Running Dev Mac Helper service"),"m1"):(s().info("Running packaged Mac Helper service"),"m2"):a.ty.isHelperProcessRunningManually||!r.app.isPackaged?(s().info("Running Dev Windows Helper service"),"w1"):(s().info("Running packaged Windows Helper service"),"w2");
JS
	run bash "$PATCH_DIR/helper-resolver.sh" "$FIX"
	[[ "$status" -eq 0 ]]
	[[ $(grep -o 'WISPR_LINUX_HELPER_BRANCH' "$FIX" | wc -l) -eq 1 ]]
	grep -qF 'function decoy(){s().info("Running Dev Mac Helper service");return"x"}' "$FIX"
	grep -qF 'const l=()=>"linux"===process.platform/*WISPR_LINUX_HELPER_BRANCH*/' "$FIX"
}

@test "helper-resolver: bails when the ternary head is not unique" {
	cat > "$FIX" <<'JS'
var r={app:{isPackaged:!0}},o={tD:!1},a={ty:{isHelperProcessRunningManually:!1}},s=function(){return{info:function(){}}};
const l=()=>o.tD?a.ty.isHelperProcessRunningManually?(s().info("Running Dev Mac Helper service"),"m1"):"m2":"w";
const m=()=>o.tD?a.ty.isHelperProcessRunningManually?(s().info("Running Dev Mac Helper service"),"m1"):"m2":(s().info("Running packaged Windows Helper service"),"w2");
JS
	run bash "$PATCH_DIR/helper-resolver.sh" "$FIX"
	[[ "$status" -ne 0 ]]
	[[ "$output" == *'expected exactly 1 helper-resolver ternary head, found 2'* ]]
	run grep -q 'WISPR_LINUX_HELPER_BRANCH' "$FIX"
	[[ "$status" -ne 0 ]]
}

@test "helper-resolver: bails when the isMac test is a call, not a member (shape near-miss)" {
	# The anchor is bound to `a.b?c.d.isHelperProcessRunningManually?(`. A
	# re-emitted `(0,o.tD)()?` is one character away and must fail closed,
	# not patch a wrong site.
	cat > "$FIX" <<'JS'
var r={app:{isPackaged:!0}},o={tD:function(){return!1}},a={ty:{isHelperProcessRunningManually:!1}},s=function(){return{info:function(){}}};
const l=()=>(0,o.tD)()?a.ty.isHelperProcessRunningManually?(s().info("Running Dev Mac Helper service"),"m1"):"m2":(s().info("Running packaged Windows Helper service"),"w2");
JS
	run bash "$PATCH_DIR/helper-resolver.sh" "$FIX"
	[[ "$status" -ne 0 ]]
	[[ "$output" == *'expected exactly 1 helper-resolver ternary head, found 0'* ]]
	run grep -q 'WISPR_LINUX_HELPER_BRANCH' "$FIX"
	[[ "$status" -ne 0 ]]
}

@test "helper-resolver: bails when the logger cannot be derived" {
	# No "Running packaged Windows Helper service" line: the logger symbol
	# has nothing to be read from, so the patch must not guess one.
	cat > "$FIX" <<'JS'
var o={tD:!1},a={ty:{isHelperProcessRunningManually:!1}},s=function(){return{info:function(){}}};
const l=()=>o.tD?a.ty.isHelperProcessRunningManually?(s().info("Running Dev Mac Helper service"),"m1"):"m2":"w2";
JS
	run bash "$PATCH_DIR/helper-resolver.sh" "$FIX"
	[[ "$status" -ne 0 ]]
	[[ "$output" == *'could not uniquely derive logger symbol'* ]]
	run grep -q 'WISPR_LINUX_HELPER_BRANCH' "$FIX"
	[[ "$status" -ne 0 ]]
}

# =============================================================================
# linux-xdg-data-dir.sh
# =============================================================================

# The platform-consts module as shipped in 1.6.897 and 1.6.937 (identifiers
# from 1.6.937), plus the pre-rename "Flow" dir from its sibling module,
# made loadable: the interop getters return the real path and os modules so
# the patched joins can be evaluated, not just grepped.
_xdg_fixture() {
	cat > "$FIX" <<'JS'
var o=()=>require("path"),i=()=>require("os"),a=o,s=i,u="win32"===process.platform;
const m=u?o().join(i().homedir(),"AppData","Roaming","Wispr Flow","Logs"):o().join(i().homedir(),"Library","Logs","Wispr Flow"),f=(u?o().join(i().homedir(),"AppData","Roaming","Wispr Flow","session.json"):o().join(i().homedir(),"Library","Application Support","Wispr Flow","session.json"),u?o().join(process.env.APPDATA||"","Wispr Flow"):o().join(i().homedir(),"Library","Application Support","Wispr Flow"));
const l=u?a().join(process.env.APPDATA||"","Flow"):a().join(s().homedir(),"Library","Application Support","Flow");
module.exports={m,f,l};
JS
}

# Print the fixture's data, logs and Flow dirs, one per line, as node
# resolves them under the current HOME / XDG_CONFIG_HOME.
_xdg_eval() {
	node -e 'const r=require(process.argv[1]);console.log(r.f);console.log(r.m);console.log(r.l)' "$FIX"
}

@test "xdg-data-dir: wraps the data and logs joins, leaves session.json and Flow alone" {
	_xdg_fixture
	run bash "$PATCH_DIR/linux-xdg-data-dir.sh" "$FIX"
	[[ "$status" -eq 0 ]]
	grep -qF ':("linux"===process.platform/*WISPR_LINUX_XDG_DATA_DIR*/?o().join(process.env.XDG_CONFIG_HOME||o().join(i().homedir(),".config"),"Wispr Flow"):o().join(i().homedir(),"Library","Application Support","Wispr Flow")))' "$FIX"
	grep -qF ':("linux"===process.platform/*WISPR_LINUX_XDG_DATA_DIR*/?o().join(process.env.XDG_CONFIG_HOME||o().join(i().homedir(),".config"),"Wispr Flow","logs"):o().join(i().homedir(),"Library","Logs","Wispr Flow"))' "$FIX"
	[[ "$(grep -o 'WISPR_LINUX_XDG_DATA_DIR' "$FIX" | wc -l)" -eq 2 ]]
	grep -qF ':o().join(i().homedir(),"Library","Application Support","Wispr Flow","session.json"),u?' "$FIX"
	grep -qF ':a().join(s().homedir(),"Library","Application Support","Flow");' "$FIX"
	node_check "$FIX"
}

@test "xdg-data-dir: the patched dirs are the launcher's wispr_config_dir on Linux" {
	command -v node >/dev/null || skip 'node not installed'
	_xdg_fixture
	bash "$PATCH_DIR/linux-xdg-data-dir.sh" "$FIX"
	local launcher="$SCRIPT_DIR/../scripts/launcher-common.sh" want
	export HOME="$TEST_TMP/home"

	export XDG_CONFIG_HOME="$TEST_TMP/cfg"
	want=$(bash -c 'source "$1"; wispr_config_dir' _ "$launcher")
	[[ $want == "$TEST_TMP/cfg/Wispr Flow" ]]
	run _xdg_eval
	[[ "$status" -eq 0 ]]
	[[ "${lines[0]}" == "$want" ]]
	[[ "${lines[1]}" == "$want/logs" ]]
	[[ "${lines[2]}" == "$HOME/Library/Application Support/Flow" ]]

	# empty counts as unset on both sides
	export XDG_CONFIG_HOME=''
	want=$(bash -c 'source "$1"; wispr_config_dir' _ "$launcher")
	[[ $want == "$HOME/.config/Wispr Flow" ]]
	run _xdg_eval
	[[ "${lines[0]}" == "$want" ]]
	[[ "${lines[1]}" == "$want/logs" ]]
}

@test "xdg-data-dir: the unpatched module puts both dirs under ~/Library (the bug)" {
	command -v node >/dev/null || skip 'node not installed'
	_xdg_fixture
	export HOME="$TEST_TMP/home" XDG_CONFIG_HOME="$TEST_TMP/cfg"
	run _xdg_eval
	[[ "${lines[0]}" == "$HOME/Library/Application Support/Wispr Flow" ]]
	[[ "${lines[1]}" == "$HOME/Library/Logs/Wispr Flow" ]]
}

@test "xdg-data-dir: matches any string delimiter and the (0,x.join) callee shape" {
	cat > "$FIX" <<'JS'
var o={join:(...a)=>a.join("/")},i={homedir:()=>"/h"},u=!1;
const m=u?"":(0,o.join)((0,i.homedir)(),`Library`,`Logs`,`Wispr Flow`),f=u?"":(0,o.join)((0,i.homedir)(),'Library','Application Support','Wispr Flow');
JS
	run bash "$PATCH_DIR/linux-xdg-data-dir.sh" "$FIX"
	[[ "$status" -eq 0 ]]
	grep -qF 'u?"":("linux"===process.platform/*WISPR_LINUX_XDG_DATA_DIR*/?(0,o.join)(process.env.XDG_CONFIG_HOME||(0,o.join)((0,i.homedir)(),".config"),"Wispr Flow","logs"):(0,o.join)((0,i.homedir)(),`Library`,`Logs`,`Wispr Flow`))' "$FIX"
	grep -qF "u?\"\":(\"linux\"===process.platform/*WISPR_LINUX_XDG_DATA_DIR*/?(0,o.join)(process.env.XDG_CONFIG_HOME||(0,o.join)((0,i.homedir)(),\".config\"),\"Wispr Flow\"):(0,o.join)((0,i.homedir)(),'Library','Application Support','Wispr Flow'))" "$FIX"
	node_check "$FIX"
}

@test "xdg-data-dir: idempotent on second run" {
	_xdg_fixture
	bash "$PATCH_DIR/linux-xdg-data-dir.sh" "$FIX"
	assert_idempotent "$PATCH_DIR/linux-xdg-data-dir.sh" "$FIX"
}

@test "xdg-data-dir: the session.json and Flow joins alone are not a data dir (near miss)" {
	# One argument past the anchor, and one literal short of it: neither may
	# stand in for the data-dir join.
	cat > "$FIX" <<'JS'
var o=()=>require("path"),i=()=>require("os"),u=!1;
const m=u?"":o().join(i().homedir(),"Library","Logs","Wispr Flow"),f=u?"":o().join(i().homedir(),"Library","Application Support","Wispr Flow","session.json"),l=u?"":o().join(i().homedir(),"Library","Application Support","Flow");
JS
	cp "$FIX" "$TEST_TMP/before.js"
	run bash "$PATCH_DIR/linux-xdg-data-dir.sh" "$FIX"
	[[ "$status" -ne 0 ]]
	[[ "$output" == *'app data join, found 0'* ]]
	cmp -s "$FIX" "$TEST_TMP/before.js"
}

@test "xdg-data-dir: bails when the logs join is missing, and writes nothing" {
	cat > "$FIX" <<'JS'
var o=()=>require("path"),i=()=>require("os"),u=!1;
const f=u?"":o().join(i().homedir(),"Library","Application Support","Wispr Flow");
JS
	cp "$FIX" "$TEST_TMP/before.js"
	run bash "$PATCH_DIR/linux-xdg-data-dir.sh" "$FIX"
	[[ "$status" -ne 0 ]]
	[[ "$output" == *'logs join, found 0'* ]]
	cmp -s "$FIX" "$TEST_TMP/before.js"
}

@test "xdg-data-dir: bails when the data-dir join is not unique" {
	cat > "$FIX" <<'JS'
var o=()=>require("path"),i=()=>require("os"),u=!1;
const m=u?"":o().join(i().homedir(),"Library","Logs","Wispr Flow"),f=u?"":o().join(i().homedir(),"Library","Application Support","Wispr Flow"),g=o().join(i().homedir(),"Library","Application Support","Wispr Flow");
JS
	run bash "$PATCH_DIR/linux-xdg-data-dir.sh" "$FIX"
	[[ "$status" -ne 0 ]]
	[[ "$output" == *'app data join, found 2'* ]]
	run grep -q 'WISPR_LINUX_XDG_DATA_DIR' "$FIX"
	[[ "$status" -ne 0 ]]
}

# =============================================================================
# linux-autostart.sh (+ linux-autostart.js)
# =============================================================================

# A bundle whose only job is to hand back electron's app after the shim ran,
# and a stand-in electron module whose own getter returns what stock
# Electron does on Linux (plus a field the shim must pass through).
_as_setup() {
	command -v node >/dev/null || skip 'node not installed'
	mkdir -p "$TEST_TMP/nm/electron" "$TEST_TMP/home"
	cat > "$TEST_TMP/nm/electron/index.js" <<'JS'
module.exports={app:{getLoginItemSettings(){return{openAtLogin:false,wasOpenedAtLogin:false,launchItems:["stock"]}},setLoginItemSettings(){}}};
JS
	printf '%s\n' '/*! For license information please see index.js.LICENSE.txt */' \
		'module.exports=require("electron").app;' > "$FIX"
	export NODE_PATH="$TEST_TMP/nm" HOME="$TEST_TMP/home"
	export XDG_CONFIG_HOME="$TEST_TMP/cfg"
	unset APPIMAGE APPDIR
	ENTRY="$XDG_CONFIG_HOME/autostart/wispr-flow.desktop"
	bash "$PATCH_DIR/linux-autostart.sh" "$FIX" >/dev/null
}

# _as_trust_appimage <path>: the AppImage runtime's env as this Electron
# (node, in the tests) sees it when it runs from inside the mount.
_as_trust_appimage() {
	export APPIMAGE="$1"
	APPDIR="$(dirname "$(node -p 'require("fs").realpathSync(process.execPath)')")"
	export APPDIR
}

# _as_node <js> [argv...]: load the patched bundle as `app` in a fresh
# process (so once-per-launch state starts clean) and run <js>.
_as_node() {
	local js="$1"
	shift
	node -e "const app=require(process.env.FIX);$js" -- "$@"
}

@test "autostart: injects the shim after the license banner, once" {
	printf '%s\n' '/*! For license information please see index.js.LICENSE.txt */' \
		'!function(){var e=1}();' > "$FIX"
	run bash "$PATCH_DIR/linux-autostart.sh" "$FIX"
	[[ "$status" -eq 0 ]]
	[[ "$(head -1 "$FIX")" == '/*! For license information please see index.js.LICENSE.txt */' ]]
	[[ "$(sed -n 2p "$FIX")" == '/*WISPR_LINUX_AUTOSTART*/' ]]
	[[ "$(tail -1 "$FIX")" == '!function(){var e=1}();' ]]
	[[ "$(grep -c 'WISPR_LINUX_AUTOSTART' "$FIX")" -eq 1 ]]
	node_check "$FIX"
}

@test "autostart: injects at byte 0 when there is no banner" {
	printf '%s\n' '!function(){var e=1}();' > "$FIX"
	run bash "$PATCH_DIR/linux-autostart.sh" "$FIX"
	[[ "$status" -eq 0 ]]
	[[ "$(head -1 "$FIX")" == '/*WISPR_LINUX_AUTOSTART*/' ]]
	node_check "$FIX"
}

@test "autostart: idempotent on second run" {
	printf '%s\n' '/*! banner */' '!function(){}();' > "$FIX"
	bash "$PATCH_DIR/linux-autostart.sh" "$FIX"
	assert_idempotent "$PATCH_DIR/linux-autostart.sh" "$FIX"
}

@test "autostart: the toggle writes and removes the entry" {
	_as_setup
	_as_node 'app.setLoginItemSettings({openAtLogin:true})'
	[[ -f $ENTRY ]]
	grep -qx 'Exec=wispr-flow --hidden' "$ENTRY"
	grep -qx 'TryExec=wispr-flow' "$ENTRY"
	grep -qx 'X-Wispr-Flow-Linux-Autostart=true' "$ENTRY"
	grep -qx 'X-GNOME-Autostart-enabled=true' "$ENTRY"
	_as_node 'app.setLoginItemSettings({openAtLogin:false})'
	[[ ! -e $ENTRY ]]
}

@test "autostart: the getter is Electron's, with wasOpenedAtLogin from --hidden" {
	_as_setup
	run _as_node 'const s=app.getLoginItemSettings();console.log(s.wasOpenedAtLogin,s.openAtLogin,s.launchItems[0])'
	[[ "$output" == 'false false stock' ]]
	run _as_node 'console.log(app.getLoginItemSettings().wasOpenedAtLogin)' --hidden
	[[ "$output" == 'true' ]]
}

@test "autostart: an AppImage path is quoted per the Desktop Entry spec" {
	_as_setup
	_as_trust_appimage '/opt/My Apps/a"b$c%d\e.AppImage'
	_as_node 'app.setLoginItemSettings({openAtLogin:true})'
	grep -qxF 'Exec="/opt/My Apps/a\\"b\\$c%%d\\\\e.AppImage" --hidden' "$ENTRY"
	grep -qxF 'TryExec=/opt/My Apps/a"b$c%d\\e.AppImage' "$ENTRY"
}

@test "autostart: APPIMAGE leaked from another AppImage is not trusted" {
	_as_setup
	export APPIMAGE='/home/u/Apps/Other.AppImage'
	_as_node 'app.setLoginItemSettings({openAtLogin:true})'
	grep -qx 'Exec=wispr-flow --hidden' "$ENTRY"
	# the other AppImage's APPDIR leaks too, and this Electron is not in it
	mkdir -p "$TEST_TMP/other-mount"
	export APPDIR="$TEST_TMP/other-mount"
	_as_node 'app.setLoginItemSettings({openAtLogin:true})'
	grep -qx 'Exec=wispr-flow --hidden' "$ENTRY"
}

@test "autostart: repairs a gone TryExec= target, keeps the user's disable" {
	_as_setup
	mkdir -p "${ENTRY%/*}"
	printf '%s\n' '[Desktop Entry]' 'Exec="/old/wispr.AppImage" --hidden' \
		'TryExec=/old/wispr.AppImage' 'X-GNOME-Autostart-enabled=false' \
		'X-Wispr-Flow-Linux-Autostart=true' > "$ENTRY"
	_as_trust_appimage '/new/wispr.AppImage'
	_as_node 'app.getLoginItemSettings()'
	grep -qxF 'Exec="/new/wispr.AppImage" --hidden' "$ENTRY"
	grep -qxF 'TryExec=/new/wispr.AppImage' "$ENTRY"
	grep -qx 'X-GNOME-Autostart-enabled=false' "$ENTRY"
	[[ "$(grep -c '^Exec=' "$ENTRY")" -eq 1 ]]
	[[ "$(grep -c '^TryExec=' "$ENTRY")" -eq 1 ]]
}

@test "autostart: a TryExec= target that exists is left alone" {
	_as_setup
	# a PATH of its own, so an installed wispr-flow cannot answer for it
	mkdir -p "${ENTRY%/*}" "$TEST_TMP/bin"
	ln -s "$(command -v node)" "$TEST_TMP/bin/node"
	printf '#!/bin/sh\n' > "$TEST_TMP/bin/wispr-flow"
	chmod +x "$TEST_TMP/bin/wispr-flow"
	printf '%s\n' '[Desktop Entry]' 'Exec=wispr-flow --hidden' \
		'TryExec=wispr-flow' 'X-Wispr-Flow-Linux-Autostart=true' > "$ENTRY"
	cp "$ENTRY" "$TEST_TMP/before"
	_as_trust_appimage '/opt/wispr.AppImage'
	PATH="$TEST_TMP/bin" _as_node 'app.getLoginItemSettings()'
	cmp -s "$ENTRY" "$TEST_TMP/before"
	# near miss: with the deb gone from PATH, the AppImage takes it over
	rm "$TEST_TMP/bin/wispr-flow"
	PATH="$TEST_TMP/bin" _as_node 'app.getLoginItemSettings()'
	grep -qxF 'Exec="/opt/wispr.AppImage" --hidden' "$ENTRY"
}

@test "autostart: leaves an entry it did not write alone" {
	_as_setup
	mkdir -p "${ENTRY%/*}"
	printf '%s\n' '[Desktop Entry]' 'Exec=/usr/local/bin/my-wispr' > "$ENTRY"
	cp "$ENTRY" "$TEST_TMP/before"
	_as_node 'app.getLoginItemSettings()'
	cmp -s "$ENTRY" "$TEST_TMP/before"
	_as_node 'app.setLoginItemSettings({openAtLogin:true})'
	cmp -s "$ENTRY" "$TEST_TMP/before"
	_as_node 'app.setLoginItemSettings({openAtLogin:false})'
	cmp -s "$ENTRY" "$TEST_TMP/before"
}

@test "autostart: an existing profile with the preference on gets no entry" {
	_as_setup
	mkdir -p "$XDG_CONFIG_HOME/Wispr Flow"
	printf '{"prefs":{"user":{"openAtLogin":true}}}' \
		> "$XDG_CONFIG_HOME/Wispr Flow/config.json"
	_as_node 'app.getLoginItemSettings()'
	[[ ! -e $ENTRY ]]
	[[ -z "$(ls -A "$XDG_CONFIG_HOME/Wispr Flow" | grep -v '^config.json$')" ]]
}

@test "autostart: loading the bundle writes nothing until the getter runs" {
	_as_setup
	mkdir -p "${ENTRY%/*}"
	printf '%s\n' '[Desktop Entry]' 'Exec="/old/wispr.AppImage" --hidden' \
		'TryExec=/old/wispr.AppImage' 'X-Wispr-Flow-Linux-Autostart=true' \
		> "$ENTRY"
	cp "$ENTRY" "$TEST_TMP/before"
	_as_trust_appimage '/new/wispr.AppImage'
	# a second instance exits before the Hub launch decision calls the getter
	_as_node 'app.setLoginItemSettings'
	cmp -s "$ENTRY" "$TEST_TMP/before"
}

@test "autostart: off Linux the stock methods are left in place" {
	_as_setup
	run node -e 'Object.defineProperty(process,"platform",{value:"darwin"});const app=require(process.env.FIX);app.setLoginItemSettings({openAtLogin:true});console.log(JSON.stringify(app.getLoginItemSettings()))'
	[[ "$output" == '{"openAtLogin":false,"wasOpenedAtLogin":false,"launchItems":["stock"]}' ]]
	[[ ! -e $ENTRY ]]
}

# =============================================================================
# linux-status-window-visibility.sh
# =============================================================================

@test "status-window-visibility: watchdog sits AHEAD of the systemState early-out" {
	cat > "$FIX" <<'JS'
ke=async()=>{if("active"!==u.RA.systemState)return;const e=performance.now();if(u.RA.statusWindow&&!u.RA.statusWindow.isDestroyed())try{if(X.isLocked())return void o().warn("Monitor move mutex is locked, skipping monitorMove interval");await X.acquire()}finally{}else o().info("Window is destroyed, ignoring monitorMove interval")};
JS
	run bash "$PATCH_DIR/linux-status-window-visibility.sh" "$FIX"
	[[ "$status" -eq 0 ]]
	grep -q 'WISPR_LINUX_STATUS_VIS_WATCHDOG' "$FIX"
	grep -qF 'ke=async()=>{/*WISPR_LINUX_STATUS_VIS_WATCHDOG*/{const w=u.RA.statusWindow;w&&!w.isDestroyed()&&!w.isAlwaysOnTop()&&w.setAlwaysOnTop(!0,"screen-saver");}if("active"!==u.RA.systemState)return;' "$FIX"
	# the watchdog block's closing brace must come BEFORE the systemState
	# check, not after -- it must run every tick regardless of dictation/idle
	# state, which is exactly the gap the earlier (rejected) position missed.
	watchdog_end=$(grep -bo 'screen-saver");}' "$FIX" | head -1 | cut -d: -f1)
	earlyout_start=$(grep -bo 'if("active"!==u.RA.systemState)' "$FIX" | head -1 | cut -d: -f1)
	[[ "$watchdog_end" -lt "$earlyout_start" ]]
	node_check "$FIX"
}

@test "status-window-visibility: matches a different quote delimiter around active" {
	cat > "$FIX" <<'JS'
ke=async()=>{if('active'!==u.RA.systemState)return;const e=performance.now();if(u.RA.statusWindow&&!u.RA.statusWindow.isDestroyed())try{}finally{}else o().info("Window is destroyed, ignoring monitorMove interval")};
JS
	run bash "$PATCH_DIR/linux-status-window-visibility.sh" "$FIX"
	[[ "$status" -eq 0 ]]
	grep -qF "ke=async()=>{/*WISPR_LINUX_STATUS_VIS_WATCHDOG*/{const w=u.RA.statusWindow;w&&!w.isDestroyed()&&!w.isAlwaysOnTop()&&w.setAlwaysOnTop(!0,\"screen-saver\");}if('active'!==u.RA.systemState)return;" "$FIX"
	node_check "$FIX"
}

@test "status-window-visibility: matches with different identifiers (re-minify churn)" {
	cat > "$FIX" <<'JS'
zz=async()=>{if("active"!==nn.qq.systemState)return;const p=performance.now();if(nn.qq.statusWindow&&!nn.qq.statusWindow.isDestroyed())try{}finally{}else vv().info("Window is destroyed, ignoring monitorMove interval")};
JS
	run bash "$PATCH_DIR/linux-status-window-visibility.sh" "$FIX"
	[[ "$status" -eq 0 ]]
	grep -qF 'zz=async()=>{/*WISPR_LINUX_STATUS_VIS_WATCHDOG*/{const w=nn.qq.statusWindow;w&&!w.isDestroyed()&&!w.isAlwaysOnTop()&&w.setAlwaysOnTop(!0,"screen-saver");}if("active"!==nn.qq.systemState)return;' "$FIX"
	node_check "$FIX"
}

@test "status-window-visibility: idempotent on second run" {
	cat > "$FIX" <<'JS'
ke=async()=>{if("active"!==u.RA.systemState)return;const e=performance.now();if(u.RA.statusWindow&&!u.RA.statusWindow.isDestroyed())try{}finally{}else o().info("Window is destroyed, ignoring monitorMove interval")};
JS
	bash "$PATCH_DIR/linux-status-window-visibility.sh" "$FIX"
	assert_idempotent "$PATCH_DIR/linux-status-window-visibility.sh" "$FIX"
}

@test "status-window-visibility: bails non-zero when the interval callback is absent" {
	cat > "$FIX" <<'JS'
ke=async()=>{if("active"!==u.RA.systemState)return;doSomethingElse()};
JS
	run bash "$PATCH_DIR/linux-status-window-visibility.sh" "$FIX"
	[[ "$status" -ne 0 ]]
	! grep -q 'WISPR_LINUX_STATUS_VIS_WATCHDOG' "$FIX"
}

@test "status-window-visibility: bails when the developer string is too far from the callback" {
	# Near miss: the callback shape matches, but "ignoring monitorMove interval"
	# is a different, unrelated callback more than 1500 chars away.
	cat > "$FIX" <<'JS'
ke=async()=>{if("active"!==u.RA.systemState)return;const e=performance.now();if(u.RA.statusWindow&&!u.RA.statusWindow.isDestroyed())try{}finally{}};
JS
	printf '%s' "$(printf 'x%.0s' {1..1600})" >> "$FIX"
	printf 'o().info("Window is destroyed, ignoring monitorMove interval");' >> "$FIX"
	run bash "$PATCH_DIR/linux-status-window-visibility.sh" "$FIX"
	[[ "$status" -ne 0 ]]
	! grep -q 'WISPR_LINUX_STATUS_VIS_WATCHDOG' "$FIX"
}
