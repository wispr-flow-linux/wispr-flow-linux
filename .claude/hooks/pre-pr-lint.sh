#!/usr/bin/env bash
#
# Claude Code PreToolUse hook: run the CI lint gates before any `git push`.
#
# Reads the tool call as JSON on stdin. For a Bash call whose command
# contains `git push`, it runs what .github/workflows/ci.yml would run on
# the pushed tree: the shellcheck line from shellcheck.yml, codespell over
# the tracked files, and, when a shell or bats file changed against main,
# `bats tests/*.bats`. actionlint runs on changed workflows when it is
# installed (CI does not run it; CONTRIBUTING.md asks for it). Any failure
# exits 2, which blocks the push and shows the output to the agent. Every
# other tool call exits 0 at once.
#
# Wired by .claude/settings.json. Runs from the repository root.

set -o pipefail

input=$(</dev/stdin)

# jq when present; a grep fallback so a session without jq still gates.
_json_field() {
	local key="$1"
	if command -v jq >/dev/null 2>&1; then
		printf '%s' "$input" | jq -r "$key // empty"
	else
		printf '%s' "$input" \
			| grep -o "\"${key##*.}\":\"[^\"]*\"" | head -1 \
			| sed 's/^"[^"]*":"//; s/"$//'
	fi
}

tool_name=$(_json_field '.tool_name')
command=$(_json_field '.tool_input.command')

[[ $tool_name == 'Bash' ]] || exit 0
[[ $command == *'git push'* ]] || exit 0

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$root" || exit 0

errors=''
checked=''

# The exact line shellcheck.yml runs.
check_shellcheck() {
	local result
	if ! command -v shellcheck >/dev/null 2>&1; then
		echo 'Warning: shellcheck not installed, skipping' >&2
		return
	fi
	result=$(git grep -l \
		'^#\( *shellcheck \|!\(/bin/\|/usr/bin/env \)\(sh\|bash\|dash\|ksh\)\)' \
		-- '*.sh' | xargs shellcheck -x --severity=warning 2>&1)
	if [[ -n $result ]]; then
		errors+="shellcheck:"$'\n'"$result"$'\n\n'
	fi
	checked+=' shellcheck'
}

# Tracked files only, so local scratch (an old extract, build.log) never
# trips it; .codespellrc still applies.
check_codespell() {
	local result
	if ! command -v codespell >/dev/null 2>&1; then
		echo 'Warning: codespell not installed, skipping' >&2
		return
	fi
	result=$(git ls-files -z | xargs -0 codespell 2>&1)
	if [[ -n $result ]]; then
		errors+="codespell:"$'\n'"$result"$'\n\n'
	fi
	checked+=' codespell'
}

check_actionlint() {
	local workflows result
	command -v actionlint >/dev/null 2>&1 || return
	workflows=$(git diff --name-only main...HEAD 2>/dev/null \
		| grep -E '^\.github/workflows/.*\.ya?ml$') || true
	[[ -n $workflows ]] || return
	# shellcheck disable=SC2086  # one path per word; workflow names have no spaces
	result=$(actionlint $workflows 2>&1)
	if [[ -n $result ]]; then
		errors+="actionlint:"$'\n'"$result"$'\n\n'
	fi
	checked+=' actionlint'
}

# bats only when shell or bats files changed: it is the slow gate (~40 s).
check_bats() {
	local changed result
	command -v bats >/dev/null 2>&1 || return
	[[ -d tests ]] || return
	changed=$(git diff --name-only main...HEAD 2>/dev/null \
		| grep -E '\.(sh|bats)$') || true
	[[ -n $changed ]] || return
	if ! result=$(bats tests/*.bats 2>&1); then
		errors+="bats:"$'\n'"$(printf '%s\n' "$result" \
			| grep -E '^(not ok|#)' | head -60)"$'\n\n'
	fi
	checked+=' bats'
}

check_shellcheck
check_codespell
check_actionlint
check_bats

if [[ -n $errors ]]; then
	printf '%s\n\n%s' 'Lint gates failed. Fix these before pushing:' \
		"$errors" >&2
	exit 2
fi

printf 'Lint gates passed:%s\n' "${checked:- (none available)}"
exit 0
