#!/usr/bin/env bats
#
# verify-patches.bats
# Tests for scripts/verify-patches.sh -- the post-repack static grep that
# confirms the Linux patch markers are present in the shipped app.asar
# (the .asar stores the JS bundle as concatenated plaintext, so a byte-grep
# finds the markers without unpacking).
#
# verify-patches.sh greps a fixed set of markers (8 fixed strings + 1 Perl
# regex). We build a tiny fixture carrying those exact marker strings (PASS)
# and per-marker fixtures that omit one (FAIL).
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
VERIFY_SH="$SCRIPT_DIR/../scripts/verify-patches.sh"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
}

teardown() {
	if [[ -n "${TEST_TMP:-}" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Sample lines, each carrying exactly one marker the script greps for.
# Keyed by a short name so the negative tests can omit one at a time.
declare -gA MARKER_SAMPLES=(
	[branch]='if (process.env.WISPR_LINUX_HELPER_BRANCH) { return "linux"; }'
	[logline]='console.log("Running packaged Linux Helper service", { serviceScriptPath: p });'
	[stagedpath]='const s = path.join(resourcesPath, "Release", "wispr-flow-linux-helper");'
	[macgate]='if("darwin"!==process.platform)return!1;const q=z.app.getAppPath();'
	[helperenv]='stdio:["pipe","pipe","pipe","pipe"],env:{/*WISPR_LINUX_HELPER_ENV*/...process.env,sentryDSN:x}'
	[chrome]='e.classList.add(/*WISPR_LINUX_WIN32_CHROME*/"linux"===w.electron.platform.os?"win32":w.electron.platform.os);'
	[windowframe]='"win32"===process.platform||"linux"===process.platform/*WISPR_LINUX_FRAMELESS*/&&Object.assign(t,{titleBarStyle:"hidden"});'
	[treataswindows]='const x=((y?.platform?.isWindows??!1)||"linux"===y?.platform?.os)/*WISPR_LINUX_RENDERER_ISWIN*/;'
	[deeplink]='if(f.H8||"linux"===process.platform){/*WISPR_LINUX_DEEPLINK*/const e=process.argv.find(x=>x.startsWith("wispr-flow:"));}'
	[logratelimit]='((globalThis.WISPR_LINUX_LOG_RATELIMIT_MM=(globalThis.WISPR_LINUX_LOG_RATELIMIT_MM||0)+1)%600!==1||a().info("Window is destroyed, ignoring monitorMove interval [sampled 1/600]"))'
)

# Write a fixture app.asar-like file containing every marker, except the one
# named in $1 (empty -> include all).
write_fixture() {
	local omit="${1:-}"
	local fixture="$TEST_TMP/app.asar"
	: > "$fixture"
	local name
	for name in "${!MARKER_SAMPLES[@]}"; do
		[[ $name == "$omit" ]] && continue
		printf '%s\n' "${MARKER_SAMPLES[$name]}" >> "$fixture"
	done
	printf '%s' "$fixture"
}

# =============================================================================
# Positive path
# =============================================================================

@test "verify: exits 0 when every marker present" {
	local fixture
	fixture="$(write_fixture)"
	run "$VERIFY_SH" "$fixture"
	[[ "$status" -eq 0 ]] || {
		echo 'verify rejected a fully-marked fixture'
		echo "$output"
		return 1
	}
	[[ "$output" == *'all Linux patch markers present'* ]]
}

@test "verify: prints an OK line per marker on success" {
	local fixture
	fixture="$(write_fixture)"
	run "$VERIFY_SH" "$fixture"
	[[ "$status" -eq 0 ]]
	run grep -c '  OK ' <<< "$output"
	[[ "$output" -eq "${#MARKER_SAMPLES[@]}" ]]
}

# =============================================================================
# Negative path: per-marker missing fixture exits 1
# =============================================================================

@test "verify: exits 1 when the helper branch marker is missing" {
	local fixture
	fixture="$(write_fixture branch)"
	run "$VERIFY_SH" "$fixture"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *'MISSING'* ]]
}

@test "verify: exits 1 when the helper log-line marker is missing" {
	local fixture
	fixture="$(write_fixture logline)"
	run "$VERIFY_SH" "$fixture"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *'MISSING'* ]]
}

@test "verify: exits 1 when the staged-path marker is missing" {
	local fixture
	fixture="$(write_fixture stagedpath)"
	run "$VERIFY_SH" "$fixture"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *'MISSING'* ]]
}

@test "verify: exits 1 when the mac-gate marker is missing" {
	local fixture
	fixture="$(write_fixture macgate)"
	run "$VERIFY_SH" "$fixture"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *'MISSING'* ]]
}

@test "verify: exits 1 when the helper-env marker is missing" {
	local fixture
	fixture="$(write_fixture helperenv)"
	run "$VERIFY_SH" "$fixture"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *'MISSING'* ]]
}

@test "verify: exits 1 when the renderer-chrome marker is missing" {
	local fixture
	fixture="$(write_fixture chrome)"
	run "$VERIFY_SH" "$fixture"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *'MISSING'* ]]
}

@test "verify: exits 1 when the window-frame marker is missing" {
	local fixture
	fixture="$(write_fixture windowframe)"
	run "$VERIFY_SH" "$fixture"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *'MISSING'* ]]
}

@test "verify: exits 1 when the treat-as-windows marker is missing" {
	local fixture
	fixture="$(write_fixture treataswindows)"
	run "$VERIFY_SH" "$fixture"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *'MISSING'* ]]
}

@test "verify: exits 1 when the deeplink marker is missing" {
	local fixture
	fixture="$(write_fixture deeplink)"
	run "$VERIFY_SH" "$fixture"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *'MISSING'* ]]
}

@test "verify: exits 1 when the log-ratelimit marker is missing" {
	local fixture
	fixture="$(write_fixture logratelimit)"
	run "$VERIFY_SH" "$fixture"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *'MISSING'* ]]
}

@test "verify: each marker is individually load-bearing (omit-one matrix)" {
	local name fixture failures=0
	for name in "${!MARKER_SAMPLES[@]}"; do
		fixture="$(write_fixture "$name")"
		run "$VERIFY_SH" "$fixture"
		if [[ "$status" -ne 1 ]]; then
			echo "omitting '$name' should exit 1, got $status"
			echo "$output"
			failures=$((failures + 1))
		fi
	done
	[[ "$failures" -eq 0 ]]
}

# =============================================================================
# Input shapes / usage
# =============================================================================

@test "verify: missing path argument exits 2 with usage" {
	run "$VERIFY_SH"
	[[ "$status" -eq 2 ]]
	[[ "$output" == *'usage:'* ]]
}

@test "verify: nonexistent file exits 2 with usage" {
	run "$VERIFY_SH" "$TEST_TMP/no-such.asar"
	[[ "$status" -eq 2 ]]
	[[ "$output" == *'usage:'* ]]
}
