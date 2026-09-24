#!/usr/bin/env bats
#
# installer-pin.bats
# Tests for the pinned-installer path:
#   * scripts/setup/installer-pin.sh        -> the pin itself is well-formed and
#                                              internally consistent
#   * scripts/setup/write-installer-pin.sh  -> rewrites the pin from resolver
#                                              output, refuses bad or partial
#                                              input, never touches comments
#   * scripts/setup/resolve-installer-url.sh -> parses upstream's JSON manifest
#                                              (driven via file:// fixtures)
#   * scripts/setup/download.sh             -> fetch_installer verifies the
#                                              digest and caches; the --exe
#                                              path warns; extract_installer
#                                              refuses a wrong-version tree
#
# Every FAIL branch below hits the real tool (sha256sum, sed, curl, python3,
# find); only the network fetch itself is a stub (_fetch copies a fixture).
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
SETUP_DIR="$SCRIPT_DIR/../scripts/setup"
PIN_SH="$SETUP_DIR/installer-pin.sh"
WRITE_SH="$SETUP_DIR/write-installer-pin.sh"
RESOLVE_SH="$SETUP_DIR/resolve-installer-url.sh"

# A digest that is 64 hex chars but matches nothing real.
FAKE_SHA='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	# The pin under test is always a copy; the real one is read-only here.
	PIN="$TEST_TMP/installer-pin.sh"
	cp "$PIN_SH" "$PIN"
	unset WISPR_EXE_SHA256 WISPR_VERSION WISPR_INSTALLER_URL \
		WISPR_INSTALLER_SHA256 APP_VERSION
}

teardown() {
	if [[ -n "${TEST_TMP:-}" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# resolver_output <version> <sha256> [url] -- the KEY=VALUE shape
# resolve-installer-url.sh emits, for feeding the writer.
resolver_output() {
	local url="${3:-https://dl.example/win32/x64/Wispr%20Flow%20Setup-v${1}.exe}"
	printf 'URL=%s\nVERSION=%s\nSHA256=%s\n' "$url" "$1" "$2"
}

# manifest <file> <url> [sha256] -- write a latest.json-shaped fixture.
manifest() {
	local sha_field=''
	[[ -n ${3:-} ]] && sha_field=",\"sha256\":\"$3\""
	printf '{"schemaVersion":1,"windows":{"x64":{"url":"%s"%s,"size":1}}}' \
		"$2" "$sha_field" > "$1"
}

# Source _common.sh + download.sh with the globals build.sh would have set,
# reading the pin from $PIN. Runs in the test shell so a direct call can be
# asserted on; wrap in `run` when the branch under test die()s.
source_download() {
	# shellcheck source=scripts/_common.sh
	source "$SCRIPT_DIR/../scripts/_common.sh"
	# shellcheck source=scripts/setup/installer-pin.sh
	source "$PIN"
	# shellcheck source=scripts/setup/download.sh
	source "$SETUP_DIR/download.sh"
	project_root="$TEST_TMP/root"
	work_dir="$TEST_TMP/root/build-linux"
	local_exe_path=''
	installer_exe_path=''
	mkdir -p "$project_root"
	# Replace the network fetch (the one un-fakeable step) with a fixture
	# copy, defined AFTER the source so the real _fetch does not win. It
	# records each call so a test can assert no download happened.
	_fetch() {
		printf '%s\n' "$1" >> "$TEST_TMP/fetch-calls"
		cp "$FETCH_SRC" "$2"
	}
}

# =============================================================================
# The pin file
# =============================================================================

@test "pin: sources cleanly and defines the three fields" {
	# shellcheck source=scripts/setup/installer-pin.sh
	source "$PIN_SH"
	[[ -n $WISPR_VERSION ]]
	[[ -n $WISPR_INSTALLER_URL ]]
	[[ -n $WISPR_INSTALLER_SHA256 ]]
}

@test "pin: version is x.y.z, URL is https and names that version, sha is 64 hex" {
	# shellcheck source=scripts/setup/installer-pin.sh
	source "$PIN_SH"
	[[ $WISPR_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
	[[ $WISPR_INSTALLER_URL == https://* ]]
	[[ $WISPR_INSTALLER_URL == *"Setup-v${WISPR_VERSION}.exe" ]]
	[[ $WISPR_INSTALLER_SHA256 =~ ^[0-9a-f]{64}$ ]]
}

@test "pin: each field is one single-quoted assignment at column 0 (the writer's anchor)" {
	local name
	for name in WISPR_VERSION WISPR_INSTALLER_URL WISPR_INSTALLER_SHA256; do
		[[ $(grep -c "^${name}='[^']*'\$" "$PIN_SH") -eq 1 ]]
	done
}

@test "pin: the real pin round-trips through the writer unchanged" {
	# shellcheck source=scripts/setup/installer-pin.sh
	source "$PIN_SH"
	resolver_output "$WISPR_VERSION" "$WISPR_INSTALLER_SHA256" \
		"$WISPR_INSTALLER_URL" | "$WRITE_SH" --pin "$PIN"
	cmp -s "$PIN_SH" "$PIN"
}

# =============================================================================
# write-installer-pin.sh
# =============================================================================

@test "write: rewrites all three fields from resolver output" {
	resolver_output 1.7.42 "$FAKE_SHA" | "$WRITE_SH" --pin "$PIN"
	# shellcheck source=scripts/setup/installer-pin.sh
	source "$PIN"
	[[ $WISPR_VERSION == '1.7.42' ]]
	[[ $WISPR_INSTALLER_URL == 'https://dl.example/win32/x64/Wispr%20Flow%20Setup-v1.7.42.exe' ]]
	[[ $WISPR_INSTALLER_SHA256 == "$FAKE_SHA" ]]
}

@test "write: reports old -> new for every field on stderr" {
	local old
	old=$(sed -n "s/^WISPR_VERSION='\\(.*\\)'\$/\\1/p" "$PIN")
	run "$WRITE_SH" --pin "$PIN" < <(resolver_output 1.7.42 "$FAKE_SHA")
	[[ $status -eq 0 ]]
	[[ $output == *"WISPR_VERSION:          $old -> 1.7.42"* ]]
	[[ $output == *"WISPR_INSTALLER_URL:    "*" -> https://dl.example/"* ]]
	[[ $output == *"WISPR_INSTALLER_SHA256: "*" -> ${FAKE_SHA}"* ]]
}

@test "write: is idempotent (second run byte-identical, exit 0)" {
	resolver_output 1.7.42 "$FAKE_SHA" | "$WRITE_SH" --pin "$PIN"
	cp "$PIN" "$TEST_TMP/first"
	resolver_output 1.7.42 "$FAKE_SHA" | "$WRITE_SH" --pin "$PIN"
	cmp -s "$TEST_TMP/first" "$PIN"
}

@test "write: near-miss -- a comment mentioning WISPR_VERSION= is not rewritten" {
	printf '# WISPR_VERSION=%s is the shape; never edit by hand\n' "'9.9.9'" \
		>> "$PIN"
	printf '  WISPR_VERSION=%s\n' "'8.8.8'" >> "$PIN"
	resolver_output 1.7.42 "$FAKE_SHA" | "$WRITE_SH" --pin "$PIN"
	grep -qF "# WISPR_VERSION='9.9.9' is the shape" "$PIN"
	grep -qF "  WISPR_VERSION='8.8.8'" "$PIN"
	[[ $(grep -c "^WISPR_VERSION='1.7.42'\$" "$PIN") -eq 1 ]]
}

@test "write: rejects a non-hex sha256 and leaves the pin byte-identical" {
	run "$WRITE_SH" --pin "$PIN" < <(resolver_output 1.7.42 'not-a-digest')
	[[ $status -eq 1 ]]
	[[ $output == *'SHA256 is not a 64-hex digest'* ]]
	cmp -s "$PIN_SH" "$PIN"
}

@test "write: rejects a 63-char sha256 (one short of a digest)" {
	run "$WRITE_SH" --pin "$PIN" < <(resolver_output 1.7.42 "${FAKE_SHA:1}")
	[[ $status -eq 1 ]]
	cmp -s "$PIN_SH" "$PIN"
}

@test "write: rejects an empty sha256 (manifest dropped it) -- no partial pin" {
	run "$WRITE_SH" --pin "$PIN" < <(resolver_output 1.7.42 '')
	[[ $status -eq 1 ]]
	[[ $output == *'SHA256'* ]]
	cmp -s "$PIN_SH" "$PIN"
}

@test "write: rejects a missing VERSION line" {
	run "$WRITE_SH" --pin "$PIN" \
		< <(printf 'URL=https://h/Setup-v1.7.42.exe\nSHA256=%s\n' "$FAKE_SHA")
	[[ $status -eq 1 ]]
	[[ $output == *'VERSION is not x.y.z'* ]]
	cmp -s "$PIN_SH" "$PIN"
}

@test "write: rejects a URL whose filename disagrees with VERSION" {
	run "$WRITE_SH" --pin "$PIN" < <(resolver_output 1.7.42 "$FAKE_SHA" \
		'https://dl.example/Wispr%20Flow%20Setup-v1.7.43.exe')
	[[ $status -eq 1 ]]
	[[ $output == *'does not name Setup-v1.7.42.exe'* ]]
	cmp -s "$PIN_SH" "$PIN"
}

@test "write: rejects a plain-http URL" {
	run "$WRITE_SH" --pin "$PIN" < <(resolver_output 1.7.42 "$FAKE_SHA" \
		'http://dl.example/Wispr%20Flow%20Setup-v1.7.42.exe')
	[[ $status -eq 1 ]]
	[[ $output == *'not a bare https URL'* ]]
	cmp -s "$PIN_SH" "$PIN"
}

@test "write: rejects a URL carrying a quote (would break the sourced pin)" {
	run "$WRITE_SH" --pin "$PIN" < <(resolver_output 1.7.42 "$FAKE_SHA" \
		"https://dl.example/x'y/Setup-v1.7.42.exe")
	[[ $status -eq 1 ]]
	cmp -s "$PIN_SH" "$PIN"
}

@test "write: refuses a pin file missing one of the three lines" {
	sed -i '/^WISPR_INSTALLER_URL=/d' "$PIN"
	run "$WRITE_SH" --pin "$PIN" < <(resolver_output 1.7.42 "$FAKE_SHA")
	[[ $status -eq 1 ]]
	[[ $output == *'missing one of the three'* ]]
}

@test "write: refuses an unwritable pin path" {
	run "$WRITE_SH" --pin "$TEST_TMP/nope.sh" < <(resolver_output 1.7.42 "$FAKE_SHA")
	[[ $status -eq 1 ]]
	[[ $output == *'not writable'* ]]
}

# =============================================================================
# resolve-installer-url.sh (manifest parsing via file:// fixtures)
# =============================================================================

@test "resolve: emits URL, VERSION and SHA256 from a well-formed manifest" {
	manifest "$TEST_TMP/latest.json" \
		'https://dl.example/win32/x64/Wispr%20Flow%20Setup-v1.6.897.exe' "$FAKE_SHA"
	run "$RESOLVE_SH" --latest-url "file://$TEST_TMP/latest.json"
	[[ $status -eq 0 ]]
	[[ $output == *'URL=https://dl.example/win32/x64/Wispr%20Flow%20Setup-v1.6.897.exe'* ]]
	[[ $output == *'VERSION=1.6.897'* ]]
	[[ $output == *"SHA256=${FAKE_SHA}"* ]]
}

@test "resolve: stdout is exactly the three KEY=VALUE lines (diagnostics on stderr)" {
	manifest "$TEST_TMP/latest.json" \
		'https://dl.example/Wispr%20Flow%20Setup-v1.6.897.exe' "$FAKE_SHA"
	local out
	out=$("$RESOLVE_SH" --latest-url "file://$TEST_TMP/latest.json" 2>/dev/null)
	[[ $(printf '%s\n' "$out" | wc -l) -eq 3 ]]
	[[ $(printf '%s\n' "$out" | grep -c '^\(URL\|VERSION\|SHA256\)=') -eq 3 ]]
}

@test "resolve: a manifest without sha256 emits an empty SHA256= and exits 0" {
	manifest "$TEST_TMP/latest.json" \
		'https://dl.example/Wispr%20Flow%20Setup-v1.6.897.exe'
	run "$RESOLVE_SH" --latest-url "file://$TEST_TMP/latest.json"
	[[ $status -eq 0 ]]
	[[ $output == *$'\nSHA256='* ]]
	[[ $output == *'no sha256'* ]]
}

@test "resolve: a malformed sha256 in the manifest is fatal" {
	manifest "$TEST_TMP/latest.json" \
		'https://dl.example/Wispr%20Flow%20Setup-v1.6.897.exe' 'abc123'
	run "$RESOLVE_SH" --latest-url "file://$TEST_TMP/latest.json"
	[[ $status -eq 1 ]]
	[[ $output == *'not a 64-hex digest'* ]]
}

@test "resolve: a non-https installer URL is refused" {
	manifest "$TEST_TMP/latest.json" \
		'http://dl.example/Wispr%20Flow%20Setup-v1.6.897.exe' "$FAKE_SHA"
	run "$RESOLVE_SH" --latest-url "file://$TEST_TMP/latest.json"
	[[ $status -eq 1 ]]
	[[ $output == *'refusing non-https'* ]]
}

@test "resolve: a manifest with no windows.x64 entry is fatal" {
	printf '{"schemaVersion":1,"windows":{"arm64":{"url":"https://x"}}}' \
		> "$TEST_TMP/latest.json"
	run "$RESOLVE_SH" --latest-url "file://$TEST_TMP/latest.json"
	[[ $status -eq 1 ]]
	[[ $output == *'no windows.x64 entry'* ]]
}

@test "resolve: the versionless bootstrapper stub URL cannot be parsed (the #83 shape)" {
	manifest "$TEST_TMP/latest.json" \
		'https://dl.example/win32/x64/WisprFlowInstaller.exe' "$FAKE_SHA"
	run "$RESOLVE_SH" --latest-url "file://$TEST_TMP/latest.json"
	[[ $status -eq 1 ]]
	[[ $output == *'could not parse a version'* ]]
}

@test "resolve: --version overrides the filename parse" {
	manifest "$TEST_TMP/latest.json" \
		'https://dl.example/win32/x64/WisprFlowInstaller.exe' "$FAKE_SHA"
	run "$RESOLVE_SH" --latest-url "file://$TEST_TMP/latest.json" --version 1.6.897
	[[ $status -eq 0 ]]
	[[ $output == *'VERSION=1.6.897'* ]]
}

@test "resolve: an unreachable manifest is fatal" {
	run "$RESOLVE_SH" --latest-url "file://$TEST_TMP/does-not-exist.json"
	[[ $status -eq 1 ]]
	[[ $output == *'failed to fetch'* ]]
}

@test "resolve | write: the bump pipeline moves the pin end to end" {
	manifest "$TEST_TMP/latest.json" \
		'https://dl.example/win32/x64/Wispr%20Flow%20Setup-v1.7.42.exe' "$FAKE_SHA"
	"$RESOLVE_SH" --latest-url "file://$TEST_TMP/latest.json" 2>/dev/null \
		| "$WRITE_SH" --pin "$PIN"
	# shellcheck source=scripts/setup/installer-pin.sh
	source "$PIN"
	[[ $WISPR_VERSION == '1.7.42' ]]
	[[ $WISPR_INSTALLER_SHA256 == "$FAKE_SHA" ]]
}

# =============================================================================
# download.sh: fetch_installer (pinned fetch + digest gate + cache)
# =============================================================================

# Point the copied pin at a fixture "installer" whose digest we control.
pin_to_fixture() {
	printf 'this is the pinned installer\n' > "$TEST_TMP/pinned.exe"
	local sha
	read -r sha _ < <(sha256sum "$TEST_TMP/pinned.exe")
	resolver_output 1.6.897 "$sha" | "$WRITE_SH" --pin "$PIN" 2>/dev/null
}

@test "fetch: downloads the pinned URL, verifies, and lands the .exe (no .part left)" {
	pin_to_fixture
	source_download
	FETCH_SRC="$TEST_TMP/pinned.exe"
	fetch_installer
	[[ $installer_exe_path == "$work_dir/downloads/wispr-flow-setup-1.6.897.exe" ]]
	cmp -s "$TEST_TMP/pinned.exe" "$installer_exe_path"
	[[ ! -e "$installer_exe_path.part" ]]
	grep -qF "$WISPR_INSTALLER_URL" "$TEST_TMP/fetch-calls"
}

@test "fetch: a download that fails the pinned digest is fatal and leaves nothing behind" {
	pin_to_fixture
	source_download
	printf 'tampered bytes\n' > "$TEST_TMP/other.exe"
	FETCH_SRC="$TEST_TMP/other.exe"
	run fetch_installer
	[[ $status -eq 1 ]]
	[[ $output == *'SHA-256 mismatch'* ]]
	[[ $output == *'does not match the pinned sha256'* ]]
	[[ ! -e "$work_dir/downloads/wispr-flow-setup-1.6.897.exe" ]]
	[[ ! -e "$work_dir/downloads/wispr-flow-setup-1.6.897.exe.part" ]]
}

@test "fetch: a verified cached installer is reused without a download" {
	pin_to_fixture
	source_download
	mkdir -p "$work_dir/downloads"
	cp "$TEST_TMP/pinned.exe" "$work_dir/downloads/wispr-flow-setup-1.6.897.exe"
	FETCH_SRC="$TEST_TMP/pinned.exe"
	run fetch_installer
	[[ $status -eq 0 ]]
	[[ $output == *'Reusing cached installer'* ]]
	[[ ! -e "$TEST_TMP/fetch-calls" ]]
}

@test "fetch: a cached file with the wrong digest (partial/stale) is re-downloaded" {
	pin_to_fixture
	source_download
	mkdir -p "$work_dir/downloads"
	printf 'half a download' > "$work_dir/downloads/wispr-flow-setup-1.6.897.exe"
	FETCH_SRC="$TEST_TMP/pinned.exe"
	run fetch_installer
	[[ $status -eq 0 ]]
	[[ $output == *'failed its digest; re-downloading'* ]]
	cmp -s "$TEST_TMP/pinned.exe" "$work_dir/downloads/wispr-flow-setup-1.6.897.exe"
	[[ -e "$TEST_TMP/fetch-calls" ]]
}

@test "fetch: an incomplete pin is fatal before any download" {
	pin_to_fixture
	source_download
	WISPR_INSTALLER_SHA256=''
	FETCH_SRC="$TEST_TMP/pinned.exe"
	run fetch_installer
	[[ $status -eq 1 ]]
	[[ $output == *'installer pin is incomplete'* ]]
	[[ ! -e "$TEST_TMP/fetch-calls" ]]
}

# =============================================================================
# download.sh: download_installer with --exe (the local override)
# =============================================================================

@test "exe: a local installer matching the pin is reported as such" {
	pin_to_fixture
	source_download
	local_exe_path="$TEST_TMP/pinned.exe"
	run download_installer
	[[ $status -eq 0 ]]
	[[ $output == *'matches the pinned 1.6.897 digest'* ]]
	[[ $output != *'[WARN]'* ]]
}

@test "exe: a local installer that is not the pin only WARNS (the override is allowed)" {
	pin_to_fixture
	source_download
	printf 'some other version\n' > "$TEST_TMP/other.exe"
	local_exe_path="$TEST_TMP/other.exe"
	run download_installer
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'*'not the pinned 1.6.897 installer'* ]]
}

@test "exe: WISPR_EXE_SHA256 is enforced on a local installer" {
	pin_to_fixture
	source_download
	local_exe_path="$TEST_TMP/pinned.exe"
	WISPR_EXE_SHA256="$FAKE_SHA"
	run download_installer
	[[ $status -eq 1 ]]
	[[ $output == *'Installer checksum verification failed'* ]]
}

@test "exe: a missing local installer path is fatal" {
	pin_to_fixture
	source_download
	local_exe_path="$TEST_TMP/missing.exe"
	run download_installer
	[[ $status -eq 1 ]]
	[[ $output == *'Local installer not found'* ]]
}

# =============================================================================
# download.sh: extract_installer reuse check
# =============================================================================

# fake_tree <version> -- an extract/ tree shaped like a real one.
fake_tree() {
	mkdir -p "$project_root/extract/nupkg/lib/net45/resources"
	: > "$project_root/extract/nupkg/lib/net45/resources/app.asar"
	: > "$project_root/extract/WisprFlow-$1-full.nupkg"
}

@test "extract: reuses a tree holding the pinned version" {
	source_download
	fake_tree "$WISPR_VERSION"
	run extract_installer
	[[ $status -eq 0 ]]
	[[ $output == *'Reusing existing extracted tree'*"($WISPR_VERSION)"* ]]
}

@test "extract: refuses a tree holding another version on the pinned path" {
	source_download
	fake_tree 1.5.789
	run extract_installer
	[[ $status -eq 1 ]]
	[[ $output == *"holds Wispr Flow 1.5.789 but this build wants $WISPR_VERSION"* ]]
}

@test "extract: --exe with a versioned filename is checked against the tree" {
	source_download
	fake_tree 1.6.897
	local_exe_path="$TEST_TMP/Wispr Flow Setup-v1.5.789.exe"
	run extract_installer
	[[ $status -eq 1 ]]
	[[ $output == *'holds Wispr Flow 1.6.897 but this build wants 1.5.789'* ]]
}

@test "extract: --exe with an unversioned filename reuses the tree (version unknown)" {
	source_download
	fake_tree 1.5.789
	local_exe_path="$TEST_TMP/wispr-flow-setup.exe"
	run extract_installer
	[[ $status -eq 0 ]]
	[[ $output == *'Reusing existing extracted tree'* ]]
}

@test "extract: a tree with no nupkg beside it is reused as before" {
	source_download
	fake_tree 1.5.789
	rm "$project_root/extract/WisprFlow-1.5.789-full.nupkg"
	run extract_installer
	[[ $status -eq 0 ]]
	[[ $output == *'Reusing existing extracted tree'* ]]
}

# =============================================================================
# fetch_electron: the dist survives between builds (build-linux.sh step 2
# keeps downloads/), so its version stamp decides whether it is reused.
# =============================================================================

# A minimal Electron dist zip: the launcher to rename, plus Electron's own
# resources/default_app.asar.
_electron_zip() {
	python3 - "$1" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as z:
    z.writestr('electron', '#!/bin/sh\n')
    z.writestr('resources/default_app.asar', 'x')
PY
}

# A previously staged dist: renamed launcher, a file only that build had.
_staged_dist() {
	mkdir -p "$1"
	printf 'old' > "$1/wispr-flow"
	chmod +x "$1/wispr-flow"
	printf 'stale' > "$1/stale.txt"
}

# source_download for the Electron path: only the zip URL is served; the
# best-effort SHASUMS256.txt fetch fails, which fetch_electron tolerates.
source_download_electron() {
	source_download
	electron_version='42.3.0'
	electron_arch='x64'
	_electron_zip "$TEST_TMP/electron.zip"
	_fetch() {
		printf '%s\n' "$1" >> "$TEST_TMP/fetch-calls"
		[[ $1 == *.zip ]] || return 1
		cp "$TEST_TMP/electron.zip" "$2"
	}
}

@test "fetch_electron: a stamped dist of the wanted version is reused, no fetch" {
	source_download_electron
	local dest="$work_dir/downloads/electron-dist"
	_staged_dist "$dest"
	printf '42.3.0\n' > "$dest.version"

	fetch_electron "$dest" >/dev/null 2>&1

	[[ ! -e $TEST_TMP/fetch-calls ]]
	[[ $(< "$dest/wispr-flow") == 'old' ]]
	[[ -f $dest/stale.txt ]]
}

@test "fetch_electron: a dist stamped with another version is re-staged" {
	source_download_electron
	local dest="$work_dir/downloads/electron-dist"
	_staged_dist "$dest"
	printf '41.0.0\n' > "$dest.version"

	fetch_electron "$dest" >/dev/null 2>&1

	grep -q 'electron-v42.3.0-linux-x64.zip' "$TEST_TMP/fetch-calls"
	[[ -x $dest/wispr-flow ]]
	[[ $(< "$dest/wispr-flow") == '#!/bin/sh' ]]
	[[ ! -e $dest/stale.txt ]]
	[[ ! -e $dest/electron ]]
	[[ $(< "$dest.version") == '42.3.0' ]]
}

@test "fetch_electron: an unstamped dist is re-staged once and stamped" {
	source_download_electron
	local dest="$work_dir/downloads/electron-dist"
	_staged_dist "$dest"

	fetch_electron "$dest" >/dev/null 2>&1

	grep -q 'electron-v42.3.0-linux-x64.zip' "$TEST_TMP/fetch-calls"
	[[ $(< "$dest.version") == '42.3.0' ]]
	[[ ! -e $dest/stale.txt ]]
}

@test "fetch_electron: a fresh fetch renames the launcher and writes the stamp" {
	source_download_electron
	local dest="$work_dir/downloads/electron-dist"

	fetch_electron "$dest" >/dev/null 2>&1

	[[ -x $dest/wispr-flow ]]
	[[ ! -e $dest/electron ]]
	[[ -f $dest/resources/default_app.asar ]]
	[[ $(< "$dest.version") == '42.3.0' ]]
	# The stamp is beside the dist, never inside the tree the makers copy.
	[[ ! -e $dest/.version ]]
}

