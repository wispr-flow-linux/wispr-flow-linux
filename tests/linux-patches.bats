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
	grep -qF 'Le=e=>{let t,n;e=(/*WISPR_LINUX_DISABLE_PILL_DRAG*/"linux"===process.platform)?!1:e;if(o().info(`[Drag Overlay]: Setting drag overlay state to ${e}`),Z=e,' "$FIX"
	# exactly one insertion; the blackout handler is untouched
	[[ "$(grep -o 'WISPR_LINUX_DISABLE_PILL_DRAG' "$FIX" | wc -l)" -eq 1 ]]
	grep -qF 'const Ie=(e,t)=>{o().info(`[Blackout Overlay]' "$FIX"
	node_check "$FIX"
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
	# The 1.5.789 shape: same developer string, no `let` prelude. A decoy
	# with the literal but not the call shape must not be patched.
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
