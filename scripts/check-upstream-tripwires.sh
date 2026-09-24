#!/usr/bin/env bash
#===============================================================================
# check-upstream-tripwires.sh -- grep a PRISTINE .webpack/ tree for the
# upstream literals every Linux patch depends on (scripts/patches/
# tripwires.tsv) and fail by name when a count moved.
#
# A patch that misses its anchor says "expected exactly 1, found 0", which
# reads the same whether upstream removed the feature, moved the statement,
# or renamed a log line. Run before the patches: a CHANGED line here means
# upstream changed the behaviour (re-audit it, docs/learnings/
# platform-gates.md); an anchor miss with every line OK means the shape
# moved around literals that are still there (re-anchor it).
#
# Usage:
#   scripts/check-upstream-tripwires.sh <webpack-root> [tripwires.tsv]
#     <webpack-root> holds main/index.js and renderer/<name>/index.js, e.g.
#     build-linux/app.asar.contents/.webpack before step 3 has run.
#
# Exit: 0 every line matched; 1 one or more CHANGED (or a file a line names
# is missing); 2 usage.
#===============================================================================

root="${1:-}"
table="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patches/tripwires.tsv}"

usage() {
	sed -n '2,/^#===.*===$/{ /^#===/d; s/^# \{0,1\}//p }' "${BASH_SOURCE[0]}"
}

if [[ -z "$root" || ! -d "$root" ]]; then
	usage >&2
	exit 2
fi
if [[ ! -f "$table" ]]; then
	echo "ERROR: tripwire table not found: $table" >&2
	exit 2
fi

# The files a `file` column names under $root, one per line.
_resolve_files() {
	local spec="$1" f
	case "$spec" in
		main) echo "$root/main/index.js" ;;
		'renderer/*')
			for f in "$root"/renderer/*/index.js; do
				[[ -f "$f" ]] || continue
				if grep -qF 'platform?.isWindows' "$f"; then
					echo "$f"
				fi
			done
			;;
		renderer/*) echo "$root/renderer/${spec#renderer/}/index.js" ;;
		*) echo "ERROR: unknown file spec '$spec' in $table" >&2; return 1 ;;
	esac
}

# Occurrences of a fixed string (F) or Perl regex (P) in a file.
_count() {
	local kind="$1" pattern="$2" file="$3"
	if [[ $kind == F ]]; then
		{ grep -o -F -- "$pattern" "$file" || true; } | wc -l
	else
		{ grep -o -P -- "$pattern" "$file" || true; } | wc -l
	fi
}

changed=0
checked=0
while IFS=$'\t' read -r patch spec kind expected label pattern; do
	[[ -z $patch || $patch == \#* ]] && continue
	if [[ $kind != F && $kind != P ]]; then
		echo "ERROR: bad kind '$kind' for $patch: $label" >&2
		exit 2
	fi
	if [[ ! $expected =~ ^[0-9]+\+?$ ]]; then
		echo "ERROR: bad expected count '$expected' for $patch: $label" >&2
		exit 2
	fi
	files=$(_resolve_files "$spec") || exit 2
	if [[ -z $files ]]; then
		echo "CHANGED  $patch: $label: no file matches '$spec' under $root"
		changed=$((changed + 1))
		checked=$((checked + 1))
		continue
	fi
	while IFS= read -r file; do
		checked=$((checked + 1))
		if [[ ! -f $file ]]; then
			echo "CHANGED  $patch: $label: missing ${file#"$root"/}"
			changed=$((changed + 1))
			continue
		fi
		n=$(_count "$kind" "$pattern" "$file")
		if [[ $expected == *+ ]]; then
			want="${expected%+}"
			ok=$(( n >= want ))
		else
			want="$expected"
			ok=$(( n == want ))
		fi
		if [[ $ok -eq 1 ]]; then
			echo "OK       $patch: $label ($n in ${file#"$root"/})"
		else
			echo "CHANGED  $patch: $label: expected $expected, found $n in ${file#"$root"/}"
			changed=$((changed + 1))
		fi
	done <<< "$files"
done < "$table"

if [[ $checked -eq 0 ]]; then
	echo "ERROR: no tripwires in $table" >&2
	exit 2
fi
if [[ $changed -gt 0 ]]; then
	echo "TRIPWIRES: $changed of $checked changed. Upstream changed something a" \
		"patch depends on; re-audit before re-anchoring (docs/learnings/platform-gates.md)." >&2
	exit 1
fi
echo "TRIPWIRES: all $checked checks match upstream."
