#!/usr/bin/env bats
#
# linux-patches.bats
# Unit tests for the renderer/main bundle patches added for the Linux port:
#   * linux-renderer-chrome.sh           -> remaps the <html> platform class linux->win32
#   * linux-window-frame.sh              -> frameless hub/settings window on Linux
#   * linux-renderer-treat-as-windows.sh -> widens each renderer's isWindows bind
#                                           (bridge stays honest; no preload touched)
#   * linux-deeplink.sh                  -> cold-start wispr-flow: argv parse on Linux
#   * helper-env.sh                      -> spreads process.env into the helper env
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
