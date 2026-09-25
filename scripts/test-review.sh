#!/usr/bin/env bash
#===============================================================================
# test-review.sh -- advisory test-integrity review of a branch's diff: would
# the tests fail if the change were broken?
#
# Two layers. Exact checks answer what they can: a changed script no
# tests/*.bats file names, a script covered only by the tag-time or local
# tests, a patch change with no fixture change, and shellcheck's SC2314/
# SC2315 (a `!` assertion that cannot fail the test) in a changed test.
# TypeSafe's Jev answers the judgement calls, one call per changed @test, per
# changed function and per PR description, with the questions, thresholds
# and verdicts in scripts/test-review-checks.json (the mutation-check items
# from docs/learnings/test-methodology.md plus the test-integrity auditor
# checks). Item 6, "revert the fix, does a test fail?", needs an execution
# and is not asked.
#
# Usage:
#   scripts/test-review.sh [--base <ref>]  review HEAD against its merge
#                                           base with <ref> (origin/main)
#   scripts/test-review.sh --all            review every @test in tests/
#   scripts/test-review.sh --calibrate <dir>
#     run each case under <dir> (test.bats, optional code.txt, optional
#     `level` holding "function" to review the tests as one function's
#     suite, and expect listing the check ids that must fire) and fail on
#     any mismatch
#
# Environment:
#   TYPESAFE_API_KEY    Jev key; unset skips the Jev layer by name (the grep
#                       layer still runs)
#   TYPESAFE_BASE_URL   default https://api.typesafe.ai
#   TEST_REVIEW_MODEL   default jev-latest
#   TEST_REVIEW_PR_BODY the PR description, for the claimed-verification check
#   TEST_REVIEW_RETRY_DELAY  first retry delay in seconds (2)
#
# Writes a Markdown report to stdout and $GITHUB_STEP_SUMMARY, and workflow
# annotations under GitHub Actions.
#
# Exit: 0 no FAIL finding; 1 one or more FAIL (or a calibration mismatch);
# 2 usage, git or Jev error (the review is incomplete, never a PASS).
#===============================================================================

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checks_file="$repo_root/scripts/test-review-checks.json"
methodology='docs/learnings/test-methodology.md'

# Per-unit caps (characters) keep a state inside Jev's 32k-token limit for
# state plus the longest question.
readonly CAP_BODY=8000
readonly CAP_SETUP=4000
readonly CAP_CODE=40000

usage() {
	sed -n '2,/^#===.*===$/{ /^#===/d; s/^# \{0,1\}//p }' "${BASH_SOURCE[0]}"
}

mode='diff'
base_ref='origin/main'
calib_dir=''
while (($# > 0)); do
	case "$1" in
		--base) base_ref="${2:-}"; shift 2 ;;
		--all) mode='all'; shift ;;
		--calibrate) mode='calibrate'; calib_dir="${2:-}"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) usage >&2; exit 2 ;;
	esac
done
if [[ $mode == calibrate && ! -d $calib_dir ]]; then
	echo "ERROR: calibration dir not found: $calib_dir" >&2
	exit 2
fi
if [[ -z $base_ref ]]; then
	usage >&2
	exit 2
fi
for tool in git jq curl; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "ERROR: $tool is required" >&2
		exit 2
	fi
done
if ! jq -e . "$checks_file" >/dev/null 2>&1; then
	echo "ERROR: unreadable checks file: $checks_file" >&2
	exit 2
fi

cd "$repo_root" || exit 2

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
units="$work/units.jsonl"
findings="$work/findings.jsonl"
errors="$work/errors.txt"
: > "$units"
: > "$findings"
: > "$errors"
model_used=''

sc_skipped=''

#-------------------------------------------------------------------------------
# Source structure
#-------------------------------------------------------------------------------

# Top-level blocks of a file as "start<TAB>end<TAB>kind<TAB>name": bats
# @test blocks (kind test) and `name() {` functions (kind func), each closed
# by the first `}` in column 0.
_blocks() {
	awk '
		/^@test / {
			start = NR; kind = "test"; name = $0
			sub(/^@test +["\047]/, "", name)
			sub(/["\047] *\{ *$/, "", name)
			next
		}
		/^[A-Za-z_][A-Za-z0-9_:.-]*\(\) *\{/ && !start {
			start = NR; kind = "func"; name = $0
			sub(/\(\).*/, "", name)
			next
		}
		/^\}/ && start {
			printf "%d\t%d\t%s\t%s\n", start, NR, kind, name
			start = 0
		}
	' "$1"
}

# New-side line numbers the diff touches in one file. A pure deletion
# reports the line it happened at, so the enclosing block still counts.
_changed_lines() {
	git diff -U0 "$merge_base" HEAD -- "$1" \
		| sed -n 's/^@@ -[0-9,]* +\([0-9]*\)\(,\([0-9]*\)\)\{0,1\} @@.*/\1 \3/p' \
		| while read -r start count; do
			[[ -z $count ]] && count=1
			if ((count == 0)); then
				echo "$start"
				continue
			fi
			seq "$start" $((start + count - 1))
		done
}

# The blocks of kind $2 in file $1 that contain a line from stdin.
_touched_blocks() {
	local file="$1" kind="$2"
	awk -F '\t' -v kind="$kind" '
		NR == FNR { hit[$1] = 1; next }
		$3 == kind {
			for (l = $1; l <= $2; l++) if (l in hit) { print; break }
		}
	' - <(_blocks "$file")
}

# Lines $2..$3 of file $1, cut to $4 characters.
_slice() {
	sed -n "${2},${3}p" "$1" | head -c "$4"
}

# name<TAB>file<TAB>start<TAB>end for every function in the shell sources,
# so a test's calls can be resolved to the code it exercises.
_build_index() {
	local f
	git ls-files -- '*.sh' ':!tests/fixtures/**' | while read -r f; do
		[[ -f $f ]] || continue
		_blocks "$f" | awk -F '\t' -v f="$f" \
			'$3 == "func" { printf "%s\t%s\t%d\t%d\n", $4, f, $1, $2 }'
	done > "$work/index.tsv"
}

# The code a test exercises: the branch's script diff (diff mode), the
# bodies of indexed functions the test names, else the head of each script
# the bats file names.
_code_for_test() {
	local bats="$1" body="$2" out='' name file start end
	[[ -s $work/scripts.diff ]] && out+=$(head -c 20000 "$work/scripts.diff")
	while IFS=$'\t' read -r name file start end; do
		out+=$'\n'"# $file: $name()"$'\n'
		out+=$(_slice "$file" "$start" "$end" 6000)
	done < <(
		grep -oE '[A-Za-z_][A-Za-z0-9_]*' <<< "$body" | sort -u \
			| awk -F '\t' 'NR == FNR { want[$1] = 1; next } $1 in want' \
				- "$work/index.tsv"
	)
	if [[ -z $out ]]; then
		for file in $(grep -oE 'scripts/[A-Za-z0-9_./-]+\.sh' "$bats" \
			| sort -u); do
			[[ -f $file ]] || continue
			out+=$'\n'"# $file"$'\n'$(head -c 20000 "$file")
		done
	fi
	printf '%s' "${out:0:CAP_CODE}"
}

#-------------------------------------------------------------------------------
# Units and deterministic findings
#-------------------------------------------------------------------------------

# _finding <verdict> <id> <title> <file> <line> <name> <fix> <doc> <detail>
_finding() {
	jq -nc --arg verdict "$1" --arg id "$2" --arg title "$3" \
		--arg file "$4" --argjson line "$5" --arg name "$6" \
		--arg fix "$7" --arg doc "$8" --arg detail "$9" \
		'$ARGS.named' >> "$findings"
}

# One Jev unit per @test block in $1 given as start/end/name on stdin.
_test_units() {
	local bats="$1" code_override="${2:-}" start end kind name body setup code
	local setup_range
	setup_range=$(_blocks "$bats" | awk -F '\t' '$4 == "setup"' | head -1)
	setup=''
	if [[ -n $setup_range ]]; then
		setup=$(_slice "$bats" "$(cut -f1 <<< "$setup_range")" \
			"$(cut -f2 <<< "$setup_range")" "$CAP_SETUP")
	fi
	while IFS=$'\t' read -r start end kind name; do
		body=$(_slice "$bats" "$start" "$end" "$CAP_BODY")
		if [[ -n $code_override ]]; then
			code=$(head -c "$CAP_CODE" "$code_override")
		else
			code=$(_code_for_test "$bats" "$body")
		fi
		jq -nc --arg file "$bats" --argjson line "$start" --arg name "$name" \
			--arg body "$body" --arg setup "$setup" --arg code "$code" \
			'{level: "test", file: $file, line: $line, name: $name,
			  state: {test_file: $file, test_name: $name, test_body: $body,
			          setup: $setup, code_under_test: $code}}' >> "$units"
	done
}

# FAIL findings for shellcheck SC2314/SC2315 at error level (a `!` that is
# not the test's last command, so bats never sees it fail) inside the @test
# blocks given as start/end/kind/name on stdin. A `!` as the last command
# is only a note (fragile, still effective) and is not reported.
_sc_negative() {
	local file="$1" blocks line hit
	blocks=$(cat)
	[[ -n $blocks ]] || return 0
	if ! command -v shellcheck >/dev/null 2>&1; then
		sc_skipped=1
		return 0
	fi
	while IFS=: read -r _ line _; do
		hit=$(awk -F '\t' -v l="$line" \
			'$1 <= l && l <= $2 { print $4; exit }' <<< "$blocks")
		[[ -n $hit ]] || continue
		_finding FAIL negative-noop 'Negative assertion never reaches bats' \
			"$file" "$line" "$hit" \
			'Use `run grep ...` then `[[ $status -ne 0 ]]`, or make the negation the last command.' \
			'negative-assertions-that-dont-fail-sc2314' \
			'shellcheck SC2314/SC2315'
	done < <(shellcheck -s bats -S error -i SC2314,SC2315 -f gcc "$file" \
		2>/dev/null)
}

# The Jev units and the exact checks for the given @test blocks of one bats
# file; $3 overrides the code under test (calibration).
_review_bats() {
	local file="$1" blocks="$2" code="${3:-}"
	[[ -n $blocks ]] || return 0
	_test_units "$file" "$code" <<< "$blocks"
	_sc_negative "$file" <<< "$blocks"
}

# Grep-layer checks plus one function unit per changed function of a
# changed shell source that some bats file names.
_script_units() {
	local file="$1" base start end kind name tests_text t
	base=$(basename "$file")
	if ! grep -qF -- "$base" tests/*.bats; then
		if grep -qF -- "$base" tests/*.sh 2>/dev/null; then
			_finding FAIL not-gated 'Covered only outside the PR gate' \
				"$file" 1 "$base" \
				"PRs run only bats tests/*.bats. Add a bats test; the artifact and patch-stage tests run on tags or locally." \
				'overview' 'named only by tests/*.sh'
		else
			_finding FAIL untested-file 'Changed script no test names' \
				"$file" 1 "$base" \
				'Add a bats test that runs the changed code.' \
				'the-mutation-check' 'no tests/*.bats file names it'
		fi
		return
	fi
	while IFS=$'\t' read -r start end kind name; do
		# The @test blocks naming the function; a script tested by running
		# it whole names none, so fall back to the bats files naming the
		# script and let Jev judge whether they reach the changed branch.
		tests_text=''
		for t in $(grep -lw -- "$name" tests/*.bats); do
			while IFS=$'\t' read -r s e _ _; do
				tests_text+=$'\n'"# $t"$'\n'$(_slice "$t" "$s" "$e" 3000)
			done < <(_blocks "$t" | awk -F '\t' '$3 == "test"' \
				| while IFS=$'\t' read -r s e k n; do
					sed -n "${s},${e}p" "$t" | grep -qw -- "$name" \
						&& printf '%s\t%s\t%s\t%s\n' "$s" "$e" "$k" "$n"
				done)
		done
		if [[ -z $tests_text ]]; then
			for t in $(grep -lF -- "$base" tests/*.bats); do
				tests_text+=$'\n'"# $t"$'\n'$(head -c 10000 "$t")
			done
		fi
		jq -nc --arg file "$file" --argjson line "$start" --arg name "$name" \
			--arg body "$(_slice "$file" "$start" "$end" "$CAP_BODY")" \
			--arg diff "$(git diff "$merge_base" HEAD -- "$file" \
				| head -c 12000)" \
			--arg tests "${tests_text:0:20000}" \
			'{level: "function", file: $file, line: $line, name: $name,
			  state: {file: $file, function: $name, function_body: $body,
			          diff: $diff, tests: $tests}}' >> "$units"
	done < <(_changed_lines "$file" | _touched_blocks "$file" func)
}

_collect_diff() {
	local file changed patch_changed='' fixture_changed=''
	merge_base=$(git merge-base "$base_ref" HEAD 2>/dev/null) || {
		echo "ERROR: no merge base between $base_ref and HEAD" >&2
		exit 2
	}
	changed=$(git diff --name-only --diff-filter=d "$merge_base" HEAD)
	git diff "$merge_base" HEAD -- build.sh scripts > "$work/scripts.diff"
	while read -r file; do
		[[ -z $file ]] && continue
		case "$file" in
			tests/fixtures/*) ;;
			tests/*.bats)
				_review_bats "$file" "$(_changed_lines "$file" \
					| _touched_blocks "$file" test)"
				;;
			scripts/*.sh|build.sh)
				[[ $file == scripts/patches/*.sh ]] && patch_changed=1
				_script_units "$file"
				;;
		esac
		[[ $file == tests/linux-patches.bats ]] && fixture_changed=1
	done <<< "$changed"
	if [[ -n $patch_changed && -z $fixture_changed ]]; then
		_finding CHECK patch-fixture 'Patch changed, fixtures did not' \
			scripts/patches 1 '' \
			'Add or adjust the linux-patches.bats fixture the new anchor must match (and a near miss it must not).' \
			'anchor-tests-need-a-near-miss-fixture' \
			'tests/linux-patches.bats unchanged'
	fi
	if [[ -n ${TEST_REVIEW_PR_BODY:-} ]]; then
		jq -nc --arg body "${TEST_REVIEW_PR_BODY:0:12000}" \
			--arg files "$changed" \
			'{level: "pr", file: "", line: 0, name: "PR description",
			  state: {description: $body, changed_files: $files}}' >> "$units"
	fi
}

#-------------------------------------------------------------------------------
# Jev
#-------------------------------------------------------------------------------

# POST one request; retries 408/429/5xx and transport failures with
# doubling backoff. Sets jev_status.
_jev() {
	local request="$1" response="$2" url attempt
	local delay="${TEST_REVIEW_RETRY_DELAY:-2}"
	url="${TYPESAFE_BASE_URL:-https://api.typesafe.ai}/v1/systemone"
	for attempt in 1 2 3 4; do
		jev_status=$(curl -sS -o "$response" -w '%{http_code}' \
			--max-time 30 -H "@$work/auth.hdr" \
			-H 'Content-Type: application/json' \
			--data-binary "@$request" "$url" 2>> "$work/curl.err") \
			|| jev_status=000
		case "$jev_status" in
			200) return 0 ;;
			408|429|5??|000) ((attempt < 4)) && sleep "$delay" ;;
			*) return 1 ;;
		esac
		delay=$((delay * 2))
	done
	return 1
}

# Findings for one unit's answers. Every asked question must come back with
# the right shape first: a missing answer is an error, never a pass.
_evaluate() {
	local unit="$1" response="$2" level="$3" meta
	if ! jq -e --argjson q "$(jq -c ".$level.questions" "$checks_file")" '
		.answers as $a
		| [$q | to_entries[]
		   | ($a[.key]) as $x
		   | if .value.type == "choice"
		     then ($x.choice | type) == "string"
		          and ($x.confidence | type) == "number"
		     else ($x.noul | type) == "number" end]
		| all' "$response" >/dev/null 2>&1; then
		return 1
	fi
	meta=$(jq -c '{file, line, name}' <<< "$unit")
	jq -c --argjson checks "$(jq -c ".$level.checks" "$checks_file")" \
		--argjson meta "$meta" '
		.answers as $a
		| $checks[] as $c
		| if ($c.kind // "noul") == "choice" then
			$a[$c.question] as $x
			| select(($c.bad | index($x.choice))
			         and $x.confidence >= $c.confidence_min)
			| {detail: "\($c.question)=\($x.choice), confidence \($x.confidence)"}
		  else
			(if $c.applies then $a[$c.applies].noul else 1 end) as $ap
			| select($ap >= ($c.applies_min // 0.5))
			| $a[$c.ok].noul as $raw
			# An inverted check compares p against 1 - below: 1 - p
			# rounds (1 - 0.8 < 0.2 in floating point).
			| select(if $c.invert then $raw > 1 - $c.below
			         else $raw < $c.below end)
			| {detail: ((if $c.applies
			             then "\($c.applies) \($ap), " else "" end)
			            + "\($c.ok) \($raw)")}
		  end
		| {verdict: $c.verdict, id: $c.id, title: $c.title, fix: $c.fix,
		   doc: $c.doc, detail} + $meta' "$response" >> "$findings"
}

_run_units() {
	local unit level n=0 request response
	[[ -s $units ]] || return 0
	if [[ -z ${TYPESAFE_API_KEY:-} ]]; then
		jev_skipped=$(wc -l < "$units")
		return 0
	fi
	umask 077
	printf 'Authorization: Bearer %s\n' "$TYPESAFE_API_KEY" > "$work/auth.hdr"
	while IFS= read -r unit; do
		n=$((n + 1))
		level=$(jq -r .level <<< "$unit")
		request="$work/req.$n.json"
		response="$work/resp.$n.json"
		jq -c --argjson q "$(jq -c ".$level.questions" "$checks_file")" \
			--arg model "${TEST_REVIEW_MODEL:-jev-latest}" \
			'{state, model: $model, questions: $q}' <<< "$unit" > "$request"
		if ! _jev "$request" "$response"; then
			printf '%s:%s %s: HTTP %s %s\n' \
				"$(jq -r .file <<< "$unit")" "$(jq -r .line <<< "$unit")" \
				"$(jq -r .name <<< "$unit")" "$jev_status" \
				"$(head -c 200 "$response" 2>/dev/null)" >> "$errors"
			continue
		fi
		[[ -z $model_used ]] && model_used=$(jq -r '.model // empty' "$response")
		if ! _evaluate "$unit" "$response" "$level"; then
			printf '%s:%s %s: answer missing or malformed\n' \
				"$(jq -r .file <<< "$unit")" "$(jq -r .line <<< "$unit")" \
				"$(jq -r .name <<< "$unit")" >> "$errors"
			continue
		fi
		if [[ $mode == calibrate ]]; then
			jq -c --arg file "$(jq -r .file <<< "$unit")" \
				'{file: $file, answers}' "$response" >> "$work/calib.jsonl"
		fi
	done < "$units"
}

#-------------------------------------------------------------------------------
# Report
#-------------------------------------------------------------------------------

_section() {
	local verdict="$1" heading="$2" n=0 f
	[[ $(jq -s --arg v "$verdict" 'map(select(.verdict == $v)) | length' \
		"$findings") -gt 0 ]] || return 0
	printf '\n### %s\n\n' "$heading"
	while IFS= read -r f; do
		n=$((n + 1))
		jq -r --argjson n "$n" --arg doc "$methodology" '
			"\($n). `\(.file)\(if .line > 0 then ":\(.line)" else "" end)`"
			+ (if .name != "" then " `\(.name)`" else "" end)
			+ ": **\(.title)** (\(.detail)). \(.fix)"
			+ " [Why](\($doc)#\(.doc))"' <<< "$f"
	done < <(jq -c --arg v "$verdict" 'select(.verdict == $v)' "$findings")
}

_annotate() {
	[[ ${GITHUB_ACTIONS:-} == true ]] || return 0
	jq -r '
		(if .verdict == "FAIL" then "error"
		 elif .verdict == "CHECK" then "warning" else "notice" end) as $lvl
		| select(.file != "")
		| "::\($lvl) file=\(.file),line=\([.line, 1] | max),"
		  + "title=\(.title)::\(.fix) (\(.detail))"' "$findings"
}

_report() {
	local fails result
	fails=$(jq -s 'map(select(.verdict == "FAIL")) | length' "$findings")
	if [[ -s $errors ]]; then
		result='INCOMPLETE'
	elif ((fails > 0)); then
		result='FAIL'
	elif [[ -n ${jev_skipped:-} ]]; then
		result='PASS (grep checks only)'
	else
		result='PASS'
	fi
	{
		echo '## Test integrity review (advisory)'
		echo
		printf 'Result: **%s**. Reviewed %s unit(s)' \
			"$result" "$(wc -l < "$units")"
		[[ $mode == diff ]] && printf ' against `%s`' "$base_ref"
		[[ -n $model_used ]] && printf ' with `%s`' "$model_used"
		echo '.'
		if [[ -n ${jev_skipped:-} ]]; then
			echo
			echo "SKIPPED the Jev layer for $jev_skipped unit(s):" \
				'TYPESAFE_API_KEY is not set. Only the grep checks ran.'
		fi
		if [[ -n $sc_skipped ]]; then
			echo
			echo 'SKIPPED the SC2314 negative-assertion check:' \
				'shellcheck is not installed.'
		fi
		_section FAIL 'FAIL'
		_section CHECK 'Worth a look'
		_section ENV 'Environment (not a test failure)'
		if [[ -s $errors ]]; then
			printf '\n### Errors (these units were not reviewed)\n\n'
			sed 's/^/- /' "$errors"
		fi
	} > "$work/report.md"
	cat "$work/report.md"
	if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
		cat "$work/report.md" >> "$GITHUB_STEP_SUMMARY"
	fi
	_annotate
	[[ -s $errors ]] && return 2
	((fails > 0)) && return 1
	return 0
}

# Calibration: each case's fired check ids must equal its expect file.
_calibrate() {
	local case_dir file code want got bad=0
	for case_dir in "$calib_dir"/*/; do
		case_dir="${case_dir%/}"
		[[ -f $case_dir/test.bats ]] || continue
		file="$case_dir/test.bats"
		code=''
		[[ -f $case_dir/code.txt ]] && code="$case_dir/code.txt"
		if [[ $(cat "$case_dir/level" 2>/dev/null) == function ]]; then
			# The whole file is one function's suite.
			jq -nc --arg file "$file" \
				--arg body "$(head -c "$CAP_CODE" "${code:-/dev/null}")" \
				--arg tests "$(head -c 20000 "$file")" \
				'{level: "function", file: $file, line: 1, name: "suite",
				  state: {file: $file, function_body: $body, diff: "",
				          tests: $tests}}' >> "$units"
			continue
		fi
		_review_bats "$file" \
			"$(_blocks "$file" | awk -F '\t' '$3 == "test"')" "$code"
	done
	if [[ -z ${TYPESAFE_API_KEY:-} ]]; then
		echo 'ERROR: calibration needs TYPESAFE_API_KEY' >&2
		return 2
	fi
	_run_units
	if [[ -s $errors ]]; then
		cat "$errors" >&2
		return 2
	fi
	for case_dir in "$calib_dir"/*/; do
		case_dir="${case_dir%/}"
		[[ -f $case_dir/test.bats ]] || continue
		file="$case_dir/test.bats"
		want=$(grep -v -e '^#' -e '^$' "$case_dir/expect" 2>/dev/null \
			| sort -u | paste -sd ' ')
		got=$(jq -r --arg f "$file" 'select(.file == $f) | .id' "$findings" \
			| sort -u | paste -sd ' ')
		if [[ $want == "$got" ]]; then
			printf '[OK]   %s: %s\n' "$(basename "$case_dir")" "${got:-none}"
		else
			printf '[MISS] %s: want %s got %s\n' "$(basename "$case_dir")" \
				"${want:-none}" "${got:-none}"
			jq -c --arg f "$file" 'select(.file == $f) | .answers' \
				"$work/calib.jsonl"
			bad=1
		fi
	done
	return "$bad"
}

_build_index
case "$mode" in
	diff)
		_collect_diff
		_run_units
		_report
		exit $?
		;;
	all)
		for f in tests/*.bats; do
			_review_bats "$f" "$(_blocks "$f" | awk -F '\t' '$3 == "test"')"
		done
		_run_units
		_report
		exit $?
		;;
	calibrate)
		_calibrate
		exit $?
		;;
esac
