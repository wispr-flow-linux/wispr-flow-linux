#!/usr/bin/env bats
#
# hooks.bats
# The Claude Code pre-push hook in .claude/hooks/pre-pr-lint.sh: it reads a
# tool call as JSON, ignores everything but a Bash `git push`, and on a push
# runs the CI lint gates on the repository it is invoked from. Each test
# builds a small git repo under $TEST_TMP so the gates see that tree, never
# this one.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
HOOK="$SCRIPT_DIR/../.claude/hooks/pre-pr-lint.sh"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	REPO="$TEST_TMP/repo"
	mkdir -p "$REPO"
	git -C "$REPO" init -q -b main
	git -C "$REPO" config user.email 'bats@example.invalid'
	git -C "$REPO" config user.name 'bats'
	cp "$SCRIPT_DIR/../.codespellrc" "$REPO/"
	printf '#!/usr/bin/env bash\necho ok\n' > "$REPO/good.sh"
	git -C "$REPO" add -A
	git -C "$REPO" commit -q -m 'clean tree'
	cd "$REPO" || exit 1
}

teardown() {
	rm -rf "$TEST_TMP"
}

_call() {  # _call <tool_name> <command>
	printf '{"tool_name":"%s","tool_input":{"command":"%s"}}' "$1" "$2" \
		| "$HOOK"
}

@test "hook: a non-Bash tool call is ignored" {
	run _call Read 'git push'
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "hook: a Bash call that is not a push is ignored" {
	run _call Bash 'git status && git log'
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "hook: a push over a clean tree passes and names the gates it ran" {
	command -v shellcheck >/dev/null || skip 'shellcheck not installed'
	command -v codespell >/dev/null || skip 'codespell not installed'
	run _call Bash 'git push -u origin main'
	[[ $status -eq 0 ]]
	[[ $output == 'Lint gates passed:'*' shellcheck'* ]]
	[[ $output == *' codespell'* ]]
}

@test "hook: a push is blocked when the CI shellcheck line fails" {
	command -v shellcheck >/dev/null || skip 'shellcheck not installed'
	# SC2034 is warning-level, which is what --severity=warning gates on
	# (an unquoted expansion, SC2086, is only info and would pass).
	printf '#!/usr/bin/env bash\nunused_here=1\necho done\n' > bad.sh
	git add bad.sh && git commit -q -m 'bad script'
	run _call Bash 'git push'
	[[ $status -eq 2 ]]
	[[ $output == *'Lint gates failed'* ]]
	[[ $output == *'shellcheck:'* ]]
	[[ $output == *'bad.sh'* ]]
}

@test "hook: a push is blocked when codespell flags a tracked file" {
	command -v codespell >/dev/null || skip 'codespell not installed'
	printf 'This is definately a typo.\n' > notes.md  # codespell:ignore definately
	git add notes.md && git commit -q -m 'typo'
	run _call Bash 'git push'
	[[ $status -eq 2 ]]
	[[ $output == *'codespell:'* ]]
	[[ $output == *'definately'* ]]
}

@test "hook: an untracked scratch file is not scanned" {
	command -v codespell >/dev/null || skip 'codespell not installed'
	# Near miss for the tracked-files-only rule: the same typo, untracked.
	printf 'This is definately a typo.\n' > scratch.md  # codespell:ignore definately
	run _call Bash 'git push'
	[[ $status -eq 0 ]]
}

@test "hook: a shell change against main runs bats and reports a red test" {
	command -v bats >/dev/null || skip 'bats not installed'
	command -v shellcheck >/dev/null || skip 'shellcheck not installed'
	git checkout -q -b topic
	mkdir -p tests
	printf '#!/usr/bin/env bats\n@test "always red" { false; }\n' \
		> tests/red.bats
	printf '#!/usr/bin/env bash\necho changed\n' > good.sh
	git add -A && git commit -q -m 'shell change with a red test'
	run _call Bash 'git push'
	[[ $status -eq 2 ]]
	[[ $output == *'bats:'* ]]
	[[ $output == *'not ok 1 always red'* ]]
}

@test "hook: no shell change against main skips bats" {
	command -v bats >/dev/null || skip 'bats not installed'
	git checkout -q -b topic
	mkdir -p tests
	printf '#!/usr/bin/env bats\n@test "always red" { false; }\n' \
		> tests/red.bats
	git add -A && git commit -q -m 'a bats file, but no .sh change'
	# The .bats change itself counts as a shell change; make a docs-only
	# branch on top of main instead to pin the skip.
	git checkout -q main
	git checkout -q -b docs
	printf 'docs\n' > README.md
	git add -A && git commit -q -m 'docs only'
	run _call Bash 'git push'
	[[ $status -eq 0 ]]
	[[ $output != *'bats'* ]]
}
