#!/usr/bin/env bats
#
# test-review.bats -- scripts/test-review.sh over a scratch git repo with a
# real git history, real jq and a `curl` PATH shim standing in for Jev. The
# shim answers every question the request asks with a clean default (noul 0,
# drives_change 1, level behaviour) and merges $FAKE_JEV_ANSWERS over it, so
# each test moves exactly the answer it is about. It logs each request so
# the tests can pin which units reached Jev and what state they carried.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	REPO="$TEST_TMP/repo"
	mkdir -p "$REPO/scripts" "$REPO/tests" "$TEST_TMP/bin" \
		"$TEST_TMP/requests"
	cp "$SCRIPT_DIR/../scripts/test-review.sh" \
		"$SCRIPT_DIR/../scripts/test-review-checks.json" "$REPO/scripts/"

	cat > "$TEST_TMP/bin/curl" <<'SHIM'
#!/usr/bin/env bash
out='' data=''
while (($# > 0)); do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		--data-binary) data="${2#@}"; shift 2 ;;
		*) shift ;;
	esac
done
n=$(find "$TEST_TMP/requests" -type f | wc -l)
cp "$data" "$TEST_TMP/requests/$((n + 1)).json"
status="${FAKE_JEV_STATUS:-200}"
if [[ $status == 200 ]]; then
	jq --argjson o "${FAKE_JEV_ANSWERS:-{\}}" '{
		model: "jev-test",
		answers: ((.questions | with_entries(.value = (
			if .value.type == "choice"
			then {type: "choice", choice: "behaviour", confidence: 0.9}
			else {type: "noul",
			      noul: (if .key == "drives_change" then 1 else 0 end)}
			end))) * $o),
		usage: {input_tokens: 1, output_tokens: 0}}' "$data" > "$out"
else
	echo '{"detail":"denied"}' > "$out"
fi
printf '%s' "$status"
SHIM
	chmod +x "$TEST_TMP/bin/curl"
	export PATH="$TEST_TMP/bin:$PATH"
	export TYPESAFE_API_KEY=test-key TEST_REVIEW_RETRY_DELAY=0
	unset FAKE_JEV_ANSWERS FAKE_JEV_STATUS TEST_REVIEW_PR_BODY \
		GITHUB_ACTIONS GITHUB_STEP_SUMMARY TYPESAFE_BASE_URL

	# Base: a script with two functions, a bats file that tests one of them
	# and names _count_all (the near miss for _count).
	cat > "$REPO/scripts/tool.sh" <<'SRC'
#!/usr/bin/env bash
_count() {
	echo one
}
_count_all() {
	echo all
}
SRC
	cat > "$REPO/tests/tool.bats" <<'SRC'
#!/usr/bin/env bats
setup() {
	source scripts/tool.sh
}
AT_TEST "count all prints all" {
	run _count_all
	[[ $output == all ]]
}
AT_TEST "untouched test" {
	true
}
SRC
	# bats rewrites any line starting with the test keyword, heredocs
	# included, so the fixture spells it AT_TEST until written.
	sed -i 's/^AT_TEST/@test/' "$REPO/tests/tool.bats"
	git -C "$REPO" init -q -b main
	git -C "$REPO" -c user.name=t -c user.email=t@t add -A
	git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm base
	git -C "$REPO" checkout -qb pr
}

teardown() {
	rm -rf "$TEST_TMP"
}

_commit() {
	git -C "$REPO" -c user.name=t -c user.email=t@t commit -qam change
}

_review() {
	run "$REPO/scripts/test-review.sh" --base main "$@"
}

_requests() {
	find "$TEST_TMP/requests" -type f | wc -l
}

@test "a changed script no test names is a FAIL with exit 1" {
	printf '#!/usr/bin/env bash\n_x() {\n\techo x\n}\n' \
		> "$REPO/scripts/orphan.sh"
	git -C "$REPO" add -A
	_commit
	_review
	[[ $status -eq 1 ]]
	[[ $output == *'Result: **FAIL**'* ]]
	[[ $output == *'`scripts/orphan.sh:1` `orphan.sh`: **Changed script no test names**'* ]]
	[[ $(_requests) -eq 0 ]]
}

@test "a function no test names goes to Jev with its script's bats files" {
	sed -i 's/echo one/echo two/' "$REPO/scripts/tool.sh"
	_commit
	_review
	[[ $status -eq 0 ]]
	[[ $(_requests) -eq 1 ]]
	run jq -r '.state.function, .state.tests' "$TEST_TMP/requests/1.json"
	# _count_all names a near miss; a substring grep would have taken its
	# block as a test naming _count instead of sending the whole file.
	[[ ${lines[0]} == '_count' ]]
	[[ $output == *'untouched test'* ]]
}

@test "a changed function a test names goes to Jev with the naming tests" {
	sed -i 's/echo all/echo every/' "$REPO/scripts/tool.sh"
	_commit
	_review
	[[ $status -eq 0 ]]
	[[ $output == *'Result: **PASS**'* ]]
	[[ $(_requests) -eq 1 ]]
	run jq -r '.state.function, .state.tests,
		(.questions | keys | join(","))' "$TEST_TMP/requests/1.json"
	[[ $output == *'_count_all'*'count all prints all'*'drives_change'* ]]
	[[ $output != *'untouched test'* ]]
}

@test "Jev saying no test drives the change is a FAIL" {
	sed -i 's/echo all/echo every/' "$REPO/scripts/tool.sh"
	_commit
	FAKE_JEV_ANSWERS='{"drives_change":{"type":"noul","noul":0.1}}' _review
	[[ $status -eq 1 ]]
	[[ $output == *'**Changed branch not driven by any test** (drives_change 0.1)'* ]]
}

@test "only the changed @test block is sent, with setup() and its code" {
	sed -i 's/\[\[ \$output == all \]\]/[[ $output == "all" ]]/' \
		"$REPO/tests/tool.bats"
	_commit
	_review
	[[ $status -eq 0 ]]
	[[ $(_requests) -eq 1 ]]
	run jq -r '.state.test_name, .state.setup, .state.code_under_test' \
		"$TEST_TMP/requests/1.json"
	[[ ${lines[0]} == 'count all prints all' ]]
	[[ $output == *'source scripts/tool.sh'* ]]
	[[ $output == *'_count_all()'*'echo all'* ]]
	[[ $output != *'untouched test'* ]]
}

@test "applies high and complies low is FAIL; complies middling is CHECK" {
	echo '# touch' >> "$REPO/tests/tool.bats"
	sed -i 's/^\ttrue$/\ttrue # x/' "$REPO/tests/tool.bats"
	_commit
	FAKE_JEV_ANSWERS='{"side_effect_applies":{"type":"noul","noul":0.9},
		"side_effect_direct":{"type":"noul","noul":0.1},
		"anchor_applies":{"type":"noul","noul":0.9},
		"near_miss":{"type":"noul","noul":0.5}}' _review
	[[ $status -eq 1 ]]
	[[ $output == *'### FAIL'*'Side effect asserted through `run`'*'### Worth a look'*'Anchor without a near-miss fixture'* ]]
}

@test "a check that does not apply never fires, however low it complies" {
	sed -i 's/^\ttrue$/\ttrue # x/' "$REPO/tests/tool.bats"
	_commit
	FAKE_JEV_ANSWERS='{"side_effect_applies":{"type":"noul","noul":0.49},
		"side_effect_direct":{"type":"noul","noul":0.0}}' _review
	[[ $status -eq 0 ]]
	[[ $output != *'Side effect asserted'* ]]
}

@test "inverted checks and the choice check fire on the defect side" {
	sed -i 's/^\ttrue$/\ttrue # x/' "$REPO/tests/tool.bats"
	_commit
	FAKE_JEV_ANSWERS='{"restates_const":{"type":"noul","noul":0.9},
		"level":{"type":"choice","choice":"marker","confidence":0.85}}' _review
	[[ $status -eq 1 ]]
	[[ $output == *'Test restates a pinned constant** (restates_const 0.9)'* ]]
	[[ $output == *'Syntax or marker check offered as behaviour** (level=marker, confidence 0.85)'* ]]
}

@test "a host-dependent test lands under Environment, not FAIL" {
	sed -i 's/^\ttrue$/\ttrue # x/' "$REPO/tests/tool.bats"
	_commit
	FAKE_JEV_ANSWERS='{"host_dependent":{"type":"noul","noul":0.95}}' _review
	[[ $status -eq 0 ]]
	[[ $output == *'### Environment (not a test failure)'*'Depends on the host'* ]]
	[[ $output != *'### FAIL'* ]]
}

@test "a Jev error reports INCOMPLETE and exit 2, never PASS" {
	sed -i 's/^\ttrue$/\ttrue # x/' "$REPO/tests/tool.bats"
	_commit
	FAKE_JEV_STATUS=401 _review
	[[ $status -eq 2 ]]
	[[ $output == *'Result: **INCOMPLETE**'* ]]
	[[ $output == *'untouched test: HTTP 401'* ]]
	[[ $output != *'PASS'* ]]
}

@test "a missing answer is an error, not a pass" {
	sed -i 's/^\ttrue$/\ttrue # x/' "$REPO/tests/tool.bats"
	_commit
	FAKE_JEV_ANSWERS='{"near_miss":null}' _review
	[[ $status -eq 2 ]]
	[[ $output == *'untouched test: answer missing or malformed'* ]]
}

@test "a 503 is retried and the retry's answer is used" {
	sed -i 's/^\ttrue$/\ttrue # x/' "$REPO/tests/tool.bats"
	_commit
	# First call 503, then 200: swap the status after the first request.
	cat > "$TEST_TMP/bin/curl.wrap" <<'SHIM'
#!/usr/bin/env bash
if [[ ! -e $TEST_TMP/seen ]]; then
	: > "$TEST_TMP/seen"
	FAKE_JEV_STATUS=503 exec "$TEST_TMP/bin/curl.real" "$@"
fi
exec "$TEST_TMP/bin/curl.real" "$@"
SHIM
	mv "$TEST_TMP/bin/curl" "$TEST_TMP/bin/curl.real"
	mv "$TEST_TMP/bin/curl.wrap" "$TEST_TMP/bin/curl"
	chmod +x "$TEST_TMP/bin/curl"
	_review
	[[ $status -eq 0 ]]
	[[ $(_requests) -eq 2 ]]
	[[ $output == *'Result: **PASS**'* ]]
}

@test "no key: grep checks still run, the Jev layer is SKIPPED by name" {
	printf '#!/usr/bin/env bash\necho x\n' > "$REPO/scripts/orphan.sh"
	git -C "$REPO" add -A
	sed -i 's/^\ttrue$/\ttrue # x/' "$REPO/tests/tool.bats"
	_commit
	unset TYPESAFE_API_KEY
	_review
	[[ $status -eq 1 ]]
	[[ $output == *'SKIPPED the Jev layer for 1 unit(s)'* ]]
	[[ $output == *'Changed script no test names'* ]]
	[[ $(_requests) -eq 0 ]]
}

@test "no key and nothing failing says the grep checks alone passed" {
	sed -i 's/^\ttrue$/\ttrue # x/' "$REPO/tests/tool.bats"
	_commit
	unset TYPESAFE_API_KEY
	_review
	[[ $status -eq 0 ]]
	[[ $output == *'Result: **PASS (grep checks only)**'* ]]
}

@test "a script named only by tests/*.sh is not gated on PRs" {
	printf '#!/usr/bin/env bash\necho hi\n' > "$REPO/scripts/tagonly.sh"
	printf '#!/usr/bin/env bash\nbash scripts/tagonly.sh\n' \
		> "$REPO/tests/test-artifact-x.sh"
	git -C "$REPO" add -A
	_commit
	_review
	[[ $status -eq 1 ]]
	[[ $output == *'`scripts/tagonly.sh:1` `tagonly.sh`: **Covered only outside the PR gate**'* ]]
}

@test "a patch change without a linux-patches.bats change is worth a look" {
	mkdir -p "$REPO/scripts/patches"
	printf '#!/usr/bin/env bash\n_p() {\n\techo p\n}\n' \
		> "$REPO/scripts/patches/p.sh"
	printf '@test "p" {\n\tsource scripts/patches/p.sh\n\t_p\n}\n' \
		> "$REPO/tests/linux-patches.bats"
	git -C "$REPO" add -A
	_commit
	git -C "$REPO" checkout -qb pr2
	sed -i 's/echo p/echo q/' "$REPO/scripts/patches/p.sh"
	_commit
	run "$REPO/scripts/test-review.sh" --base pr
	[[ $output == *'### Worth a look'*'Patch changed, fixtures did not'* ]]
}

@test "the PR description is asked about only when given" {
	sed -i 's/^\ttrue$/\ttrue # x/' "$REPO/tests/tool.bats"
	_commit
	TEST_REVIEW_PR_BODY='Ran shellcheck by hand.' \
		FAKE_JEV_ANSWERS='{"claims_uncommitted":{"type":"noul","noul":0.8}}' \
		_review
	[[ $(_requests) -eq 2 ]]
	[[ $output == *'`PR description`: **Claimed verification not committed as a test**'* ]]
	run jq -r .state.description "$TEST_TMP/requests/2.json"
	[[ $output == 'Ran shellcheck by hand.' ]]
}

@test "under Actions: annotations and the step summary are written" {
	printf '#!/usr/bin/env bash\necho x\n' > "$REPO/scripts/orphan.sh"
	git -C "$REPO" add -A
	_commit
	GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$TEST_TMP/summary.md" _review
	[[ $output == *'::error file=scripts/orphan.sh,line=1,title=Changed script no test names::'* ]]
	run cat "$TEST_TMP/summary.md"
	[[ $output == *'## Test integrity review (advisory)'* ]]
}

@test "the API key never reaches curl's argv" {
	sed -i 's/^\ttrue$/\ttrue # x/' "$REPO/tests/tool.bats"
	_commit
	cat > "$TEST_TMP/bin/curl.wrap" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_TMP/argv"
exec "$TEST_TMP/bin/curl.real" "$@"
SHIM
	mv "$TEST_TMP/bin/curl" "$TEST_TMP/bin/curl.real"
	mv "$TEST_TMP/bin/curl.wrap" "$TEST_TMP/bin/curl"
	chmod +x "$TEST_TMP/bin/curl"
	_review
	[[ $status -eq 0 ]]
	run grep -qF 'test-key' "$TEST_TMP/argv"
	[[ $status -ne 0 ]]
}

@test "calibrate: a case passes when exactly its expected ids fire" {
	local c="$TEST_TMP/calib"
	mkdir -p "$c/bad" "$c/clean"
	printf 'AT_TEST "t" {\n\ttrue\n}\n' | sed 's/^AT_TEST/@test/' \
		| tee "$c/bad/test.bats" > "$c/clean/test.bats"
	echo 'code' | tee "$c/bad/code.txt" > "$c/clean/code.txt"
	echo 'restates-constant' > "$c/bad/expect"
	echo '' > "$c/clean/expect"
	# Both cases get the same answers: the bad case's expectation holds and
	# the clean case's does not.
	FAKE_JEV_ANSWERS='{"restates_const":{"type":"noul","noul":0.9}}' \
		run "$REPO/scripts/test-review.sh" --calibrate "$c"
	[[ $status -eq 1 ]]
	[[ $output == *'[OK]   bad: restates-constant'* ]]
	[[ $output == *'[MISS] clean: want none got restates-constant'* ]]
	run "$REPO/scripts/test-review.sh" --calibrate "$c"
	[[ $output == *'[OK]   clean: none'* ]]
	[[ $output == *'[MISS] bad: want restates-constant got none'* ]]
	run jq -r .state.code_under_test "$TEST_TMP/requests/1.json"
	[[ $output == 'code' ]]
}

@test "an unknown flag is a usage error" {
	_review --bogus
	[[ $status -eq 2 ]]
}
