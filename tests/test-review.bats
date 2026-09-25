#!/usr/bin/env bats
#
# test-review.bats -- scripts/test-review.sh over a scratch git repo with a
# real git history, real jq and a `curl` PATH shim standing in for Jev. The
# shim answers every question the request asks with a clean default (noul 0,
# reaches_change 1, level all behaviour), echoes the requested model, and
# merges $FAKE_JEV_ANSWERS (or $TEST_TMP/answers.<n> for the n-th call) over
# it, so each test moves exactly the answer it is about. It logs each
# request so the tests can pin which units reached Jev and what state they
# carried. One sample per unit unless a test asks for more.
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
out='' data='' hdr=''
while (($# > 0)); do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-D) hdr="$2"; shift 2 ;;
		--data-binary) data="${2#@}"; shift 2 ;;
		*) shift ;;
	esac
done
n=$(find "$TEST_TMP/requests" -type f | wc -l)
n=$((n + 1))
cp "$data" "$TEST_TMP/requests/$n.json"
status="${FAKE_JEV_STATUS:-200}"
[[ -f $TEST_TMP/status.$n ]] && status=$(cat "$TEST_TMP/status.$n")
answers="${FAKE_JEV_ANSWERS:-{\}}"
[[ -f $TEST_TMP/answers.$n ]] && answers=$(cat "$TEST_TMP/answers.$n")
[[ -n $hdr && -f $TEST_TMP/headers.$n ]] && cp "$TEST_TMP/headers.$n" "$hdr"
if [[ $status == 200 ]]; then
	jq --argjson o "$answers" --arg m "${FAKE_JEV_MODEL:-}" '{
		model: (if $m == "" then .model else $m end),
		answers: ((.questions | with_entries(.value = (
			if .value.type == "choice"
			then {type: "choice", choice: "behaviour", confidence: 1,
			      probabilities: (.value.criteria
			        | with_entries(.value = (if .key == "behaviour"
			                                 then 1 else 0 end)))}
			else {type: "noul",
			      noul: (if .key == "reaches_change" then 1 else 0 end)}
			end))) * $o),
		usage: {input_tokens: 1, output_tokens: 0}}' "$data" > "$out"
else
	echo '{"detail":"denied"}' > "$out"
fi
printf '%s' "$status"
SHIM
	chmod +x "$TEST_TMP/bin/curl"
	export PATH="$TEST_TMP/bin:$PATH"
	export TYPESAFE_API_KEY=test-key TEST_REVIEW_RETRY_DELAY=0 \
		TEST_REVIEW_SAMPLES=1
	unset FAKE_JEV_ANSWERS FAKE_JEV_STATUS FAKE_JEV_MODEL \
		TEST_REVIEW_PR_BODY TEST_REVIEW_MODEL GITHUB_ACTIONS \
		GITHUB_STEP_SUMMARY TYPESAFE_BASE_URL

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
	[[ $output == *'_count_all'*'count all prints all'*'reaches_change'* ]]
	[[ $output != *'untouched test'* ]]
}

@test "Jev saying no test reaches the change is a FAIL" {
	sed -i 's/echo all/echo every/' "$REPO/scripts/tool.sh"
	_commit
	FAKE_JEV_ANSWERS='{"reaches_change":{"type":"noul","noul":0.1}}' _review
	[[ $status -eq 1 ]]
	[[ $output == *'**Changed branch not driven by any test** (reaches_change 0.1; margin 0.4)'* ]]
	run jq -r .model "$TEST_TMP/requests/1.json"
	# The version the conditions were calibrated on, never an alias.
	[[ $output == 'jev-1.13.0' ]]
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

@test "each check reports at its own verdict: FAIL and worth a look" {
	sed -i 's/^\ttrue$/\ttrue # x/' "$REPO/tests/tool.bats"
	_commit
	FAKE_JEV_ANSWERS='{"mutation_via_run":{"type":"noul","noul":0.85},
		"reads_source":{"type":"noul","noul":0.81}}' _review
	[[ $status -eq 1 ]]
	[[ $output == *'### FAIL'*'Side effect asserted through `run`'*'### Worth a look'*'Test greps the source instead of running it'* ]]
}

@test "a margin under the band is Uncertain, never the check's verdict" {
	sed -i 's/^\ttrue$/\ttrue # x/' "$REPO/tests/tool.bats"
	_commit
	# run-subshell holds by 0.29 (0.79 - 0.5), inside the 0.3 band: it
	# would be a FAIL at 0.8. The choice sums syntax and marker to 0.6.
	FAKE_JEV_ANSWERS='{"mutation_via_run":{"type":"noul","noul":0.79},
		"level":{"type":"choice","choice":"marker",
			"probabilities":{"syntax":0.2,"marker":0.4,"behaviour":0.4,
				"other":0}}}' _review
	[[ $status -eq 0 ]]
	[[ $output != *'### FAIL'* ]]
	[[ $output != *'### Worth a look'* ]]
	[[ $output == *'### Uncertain (Jev within 0.3 of the line; never a FAIL)'* ]]
	[[ $output == *'Side effect asserted through `run`** (mutation_via_run 0.79; margin 0.29)'* ]]
	[[ $output == *'Syntax or marker check offered as behaviour** (level=syntax|marker 0.6; margin 0.1)'* ]]
}

@test "an answer on the clean side of the line is not reported, however near" {
	sed -i 's/^\ttrue$/\ttrue # x/' "$REPO/tests/tool.bats"
	_commit
	# Margin 0: at the line, not over it. Calibration holds the clean
	# side to the band; the review only lists what fires.
	FAKE_JEV_ANSWERS='{"mutation_via_run":{"type":"noul","noul":0.5}}' _review
	[[ $status -eq 0 ]]
	[[ $output != *'Side effect asserted'* ]]
}

@test "a check fires only when all its conditions hold" {
	sed -i 's/^\ttrue$/\ttrue # x/' "$REPO/tests/tool.bats"
	_commit
	FAKE_JEV_ANSWERS='{"compares_literal":{"type":"noul","noul":1.0},
		"feeds_wrong_value":{"type":"noul","noul":0.9}}' _review
	[[ $status -eq 0 ]]
	[[ $output != *'restates a pinned constant'* ]]
}

@test "a max condition and the choice check fire on the defect side" {
	sed -i 's/^\ttrue$/\ttrue # x/' "$REPO/tests/tool.bats"
	_commit
	FAKE_JEV_ANSWERS='{"compares_literal":{"type":"noul","noul":0.9},
		"feeds_wrong_value":{"type":"noul","noul":0.1},
		"level":{"type":"choice","choice":"marker",
			"probabilities":{"syntax":0.05,"marker":0.85,"behaviour":0.1,
				"other":0}}}' _review
	# Both are worth a look, not FAIL: they flag deliberate structure tests.
	[[ $status -eq 0 ]]
	[[ $output == *'### Worth a look'* ]]
	[[ $output == *'Test restates a pinned constant** (compares_literal 0.9, feeds_wrong_value 0.1; margin 0.4)'* ]]
	[[ $output == *'Syntax or marker check offered as behaviour** (level=syntax|marker 0.9; margin 0.4)'* ]]
}

@test "a host-dependent test lands under Environment, not FAIL" {
	sed -i 's/^\ttrue$/\ttrue # x/' "$REPO/tests/tool.bats"
	_commit
	# Any one of the four host questions is enough.
	FAKE_JEV_ANSWERS='{"needs_root":{"type":"noul","noul":0.95}}' _review
	[[ $status -eq 0 ]]
	[[ $output == *'### Environment (not a test failure)'*'Depends on the host** (needs_network 0, needs_device 0, needs_root 0.95, reads_real_home 0; margin 0.45)'* ]]
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
	FAKE_JEV_ANSWERS='{"mutation_via_run":null}' _review
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
	echo notes > "$REPO/NOTES.md"
	git -C "$REPO" add -A
	_commit
	_review
	[[ $(_requests) -eq 0 ]]
	TEST_REVIEW_PR_BODY='Ran shellcheck by hand.' \
		FAKE_JEV_ANSWERS='{"claims_verification":{"type":"noul","noul":0.9}}' \
		_review
	[[ $(_requests) -eq 1 ]]
	[[ $output == *'`PR description`: **Claimed verification not committed as a test** (claims_verification 0.9; margin 0.4)'* ]]
	run jq -r .state.description "$TEST_TMP/requests/1.json"
	[[ $output == 'Ran shellcheck by hand.' ]]
}

@test "a claimed verification with a changed bats file is not flagged" {
	sed -i 's/^\ttrue$/\ttrue # x/' "$REPO/tests/tool.bats"
	_commit
	TEST_REVIEW_PR_BODY='Ran shellcheck by hand.' \
		FAKE_JEV_ANSWERS='{"claims_verification":{"type":"noul","noul":0.99}}' \
		_review
	[[ $(_requests) -eq 2 ]]
	[[ $output != *'Claimed verification'* ]]
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
	FAKE_JEV_ANSWERS='{"compares_literal":{"type":"noul","noul":0.9}}' \
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

@test "a mid-test negation is a FAIL; one as the last command is not" {
	cat >> "$REPO/tests/tool.bats" <<'SRC'
AT_TEST "mid-test negation" {
	! grep -q x /dev/null
	true
}
AT_TEST "last-command negation" {
	true
	! grep -q x /dev/null
}
SRC
	sed -i 's/^AT_TEST/@test/' "$REPO/tests/tool.bats"
	_commit
	_review
	[[ $status -eq 1 ]]
	[[ $output == *'`tests/tool.bats:13` `mid-test negation`: **Negative assertion never reaches bats**'* ]]
	[[ $output != *'`last-command negation`: **Negative'* ]]
}

@test "a negation in an unchanged test is not reported on this diff" {
	cat >> "$REPO/tests/tool.bats" <<'SRC'
AT_TEST "old mid-test negation" {
	! grep -q x /dev/null
	true
}
SRC
	sed -i 's/^AT_TEST/@test/' "$REPO/tests/tool.bats"
	git -C "$REPO" -c user.name=t -c user.email=t@t commit -qam old
	git -C "$REPO" branch -f main
	# Only the first `true` (the untouched test), not the old negation's.
	sed -i '0,/^\ttrue$/s//\ttrue # x/' "$REPO/tests/tool.bats"
	_commit
	_review
	[[ $output != *'Negative assertion'* ]]
}

@test "calibrate: a function-level case is one unit with the whole suite" {
	local c="$TEST_TMP/calib"
	mkdir -p "$c/suite"
	printf 'AT_TEST "a" {\n\ttrue\n}\nAT_TEST "b" {\n\tfalse\n}\n' \
		| sed 's/^AT_TEST/@test/' > "$c/suite/test.bats"
	printf 'fn() {\n\t:\n}\n' > "$c/suite/code.txt"
	printf '+\t:\n' > "$c/suite/diff.txt"
	echo function > "$c/suite/level"
	echo near-miss > "$c/suite/expect"
	FAKE_JEV_ANSWERS='{"matches_anchor":{"type":"noul","noul":0.9},
		"near_miss_tested":{"type":"noul","noul":0.1}}' \
		run "$REPO/scripts/test-review.sh" --calibrate "$c"
	[[ $status -eq 0 ]]
	[[ $output == *'[OK]   suite: near-miss'* ]]
	# The answers print for a passing case too.
	[[ $output == *'"near_miss_tested":"0.1"'* ]]
	[[ $(_requests) -eq 1 ]]
	run jq -r '.state.function, .state.function_body, .state.diff,
		.state.tests, (.questions | keys[])' "$TEST_TMP/requests/1.json"
	[[ ${lines[0]} == fn ]]
	[[ $output == *'fn() {'*'+'*'@test "a"'*'@test "b"'*'reaches_change'* ]]
}

@test "calibrate: the right answer inside the band is THIN, not OK" {
	local c="$TEST_TMP/calib"
	mkdir -p "$c/bad"
	printf 'AT_TEST "t" {\n\ttrue\n}\n' | sed 's/^AT_TEST/@test/' \
		> "$c/bad/test.bats"
	echo 'reads-source' > "$c/bad/expect"
	# Fires (0.75 > 0.5) but clears the line by 0.25, under the 0.3 band.
	FAKE_JEV_ANSWERS='{"reads_source":{"type":"noul","noul":0.75}}' \
		run "$REPO/scripts/test-review.sh" --calibrate "$c"
	[[ $status -eq 1 ]]
	[[ $output == *'[THIN] bad: reads-source, but inside the band: reads-source 0.25..0.25'* ]]
	FAKE_JEV_ANSWERS='{"reads_source":{"type":"noul","noul":0.8}}' \
		run "$REPO/scripts/test-review.sh" --calibrate "$c"
	[[ $status -eq 0 ]]
	[[ $output == *'[OK]   bad: reads-source'* ]]
}

@test "calibrate: one drifting sample fails the case, though the mean is clear" {
	local c="$TEST_TMP/calib"
	mkdir -p "$c/clean"
	printf 'AT_TEST "t" {\n\ttrue\n}\n' | sed 's/^AT_TEST/@test/' \
		> "$c/clean/test.bats"
	: > "$c/clean/expect"
	# Samples 0, 0, 0.3: mean 0.1 clears the band, the third sample
	# (margin -0.2) does not.
	echo '{"reads_source":{"type":"noul","noul":0.3}}' > "$TEST_TMP/answers.3"
	TEST_REVIEW_SAMPLES=3 run "$REPO/scripts/test-review.sh" --calibrate "$c"
	[[ $status -eq 1 ]]
	[[ $(_requests) -eq 3 ]]
	[[ $output == *'[THIN] clean: none, but inside the band: reads-source -0.5..-0.2'* ]]
	[[ $output == *'"reads_source":"0.1 (0-0.3)"'* ]]
}

@test "the review averages its samples before judging" {
	sed -i 's/^\ttrue$/\ttrue # x/' "$REPO/tests/tool.bats"
	_commit
	# 0.9, 0.9, 0.0: mean 0.6 is inside the band, so Uncertain.
	echo '{"reads_source":{"type":"noul","noul":0.9}}' \
		| tee "$TEST_TMP/answers.1" > "$TEST_TMP/answers.2"
	TEST_REVIEW_SAMPLES=3 _review
	[[ $status -eq 0 ]]
	[[ $(_requests) -eq 3 ]]
	[[ $output == *'with `jev-1.13.0`, 3 sample(s) each'* ]]
	[[ $output == *'### Uncertain'*'greps the source instead of running it** (reads_source 0.6; margin 0.1)'* ]]
	[[ $output != *'### Worth a look'* ]]
}

@test "an answer from another model than asked is an error, not a pass" {
	sed -i 's/^\ttrue$/\ttrue # x/' "$REPO/tests/tool.bats"
	_commit
	FAKE_JEV_MODEL=jev-1.14.0 _review
	[[ $status -eq 2 ]]
	[[ $output == *'untouched test: answered by jev-1.14.0, asked for jev-1.13.0'* ]]
}

@test "a model override is asked for and the report says it is uncalibrated" {
	sed -i 's/^\ttrue$/\ttrue # x/' "$REPO/tests/tool.bats"
	_commit
	TEST_REVIEW_MODEL=jev-preview _review
	[[ $status -eq 0 ]]
	[[ $output == *'calibrated on `jev-1.13.0`, not `jev-preview`'* ]]
	run jq -r .model "$TEST_TMP/requests/1.json"
	[[ $output == 'jev-preview' ]]
}

@test "a 529 is retried after the server's Retry-After, not the backoff" {
	sed -i 's/^\ttrue$/\ttrue # x/' "$REPO/tests/tool.bats"
	_commit
	echo 529 > "$TEST_TMP/status.1"
	printf 'HTTP/2 529\r\nretry-after: 0\r\n\r\n' > "$TEST_TMP/headers.1"
	# A backoff this long would outlast the test; Retry-After 0 must win.
	SECONDS=0
	TEST_REVIEW_RETRY_DELAY=120 _review
	[[ $status -eq 0 ]]
	[[ $(_requests) -eq 2 ]]
	((SECONDS < 60))
}

@test "a field condition is exact: no [PASS] line, no pass-unparsed" {
	sed -i 's/echo all/echo every/' "$REPO/scripts/tool.sh"
	_commit
	FAKE_JEV_ANSWERS='{"pass_on_unchecked":{"type":"noul","noul":0.99}}' \
		_review
	[[ $status -eq 0 ]]
	[[ $output != *'[PASS] on data never read'* ]]
	sed -i 's/echo every/_pass "all: $x"/' "$REPO/scripts/tool.sh"
	_commit
	FAKE_JEV_ANSWERS='{"pass_on_unchecked":{"type":"noul","noul":0.99}}' \
		_review
	[[ $output == *'[PASS] on data never read** (pass_on_unchecked 0.99; margin 0.49)'* ]]
}

@test "--all sweeps the functions tests name, where no change can be undriven" {
	FAKE_JEV_ANSWERS='{"reaches_change":{"type":"noul","noul":0}}' \
		run "$REPO/scripts/test-review.sh" --all
	[[ $status -eq 0 ]]
	# Two @test units plus _count_all, the one function a test names.
	[[ $(_requests) -eq 3 ]]
	run jq -r 'select(.state.function) | .state.function, .state.diff' \
		"$TEST_TMP"/requests/*.json
	[[ $output == '_count_all' ]]
}

@test "an unknown flag is a usage error" {
	_review --bogus
	[[ $status -eq 2 ]]
}

@test "a check that cannot be evaluated is an error, not a pass" {
	jq '.test.checks[0].when[0] = {"field": "test_body", "regex": "("}' \
		"$REPO/scripts/test-review-checks.json" > "$TEST_TMP/checks.json"
	cp "$TEST_TMP/checks.json" "$REPO/scripts/test-review-checks.json"
	sed -i 's/^\ttrue$/\ttrue # x/' "$REPO/tests/tool.bats"
	_commit
	_review
	[[ $status -eq 2 ]]
	[[ $output == *'untouched test: checks could not be evaluated'* ]]
}

@test "calibrate: an exact check counts toward the case with no margin" {
	local c="$TEST_TMP/calib"
	mkdir -p "$c/neg"
	printf 'AT_TEST "t" {\n\t! grep -q x /dev/null\n\ttrue\n}\n' \
		| sed 's/^AT_TEST/@test/' > "$c/neg/test.bats"
	echo negative-noop > "$c/neg/expect"
	run "$REPO/scripts/test-review.sh" --calibrate "$c"
	[[ $status -eq 0 ]]
	[[ $output == *'[OK]   neg: negative-noop'* ]]
}

@test "a bats helper the test calls rides along; setup and unused ones do not" {
	cat >> "$REPO/tests/tool.bats" <<'SRC'
_sandbox_home() {
	export HOME="$TEST_TMP/home"
}
_unused_helper() {
	echo nope
}
AT_TEST "uses a helper" {
	_sandbox_home
	true
}
SRC
	sed -i 's/^AT_TEST/@test/' "$REPO/tests/tool.bats"
	_commit
	_review
	[[ $(_requests) -eq 1 ]]
	run jq -r .state.helpers "$TEST_TMP/requests/1.json"
	[[ $output == *'_sandbox_home() {'*'HOME="$TEST_TMP/home"'* ]]
	[[ $output != *'_unused_helper'* ]]
	[[ $output != *'source scripts/tool.sh'* ]]
}
